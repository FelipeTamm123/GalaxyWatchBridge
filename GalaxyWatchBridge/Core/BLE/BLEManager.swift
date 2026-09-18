import CoreBluetooth
import Foundation
import os

/// CoreBluetooth central role, wrapped in an `async`/`await` surface.
///
/// ## Threading contract
///
/// Every stored property below is **confined to `queue`**, a private serial dispatch
/// queue. CoreBluetooth delivers all delegate callbacks there (it is the queue handed to
/// `CBCentralManager(delegate:queue:)`), and every public method funnels its work onto it
/// with `queue.async`. Because the queue is serial, that confinement alone provides mutual
/// exclusion — no locks are needed, and `PendingOperation`'s unsynchronised single-shot
/// flag is safe.
///
/// Nothing is published from here. State leaves through `events`, an `AsyncStream` of
/// `Sendable` value types, and `WatchViewModel` consumes it on `@MainActor`. This is what
/// guarantees UI mutation happens on the main thread: there is no code path from a
/// CoreBluetooth callback to a SwiftUI property that does not pass through that hop.
///
/// The `@unchecked Sendable` conformance is the deliberate assertion of that contract —
/// the compiler cannot verify queue confinement, so `dispatchPrecondition` checks assert it
/// at runtime in debug builds instead.
final class BLEManager: NSObject, @unchecked Sendable {

    // MARK: - Outbound stream

    let events: AsyncStream<BLEEvent>
    private let continuation: AsyncStream<BLEEvent>.Continuation

    // MARK: - Queue-confined state

    private let queue = DispatchQueue(label: "com.felipetamm.galaxywatchbridge.ble", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.felipetamm.galaxywatchbridge", category: "BLE")

    private var central: CBCentralManager!
    private var state: BluetoothState = .unknown

    /// Every peripheral handed to us by a scan or a restore, kept alive because
    /// CoreBluetooth will not reconnect to a `CBPeripheral` we have released.
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var advertisements: [UUID: DiscoveredPeripheral] = [:]

    private var activePeripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]

    private var pendingConnects: [UUID: PendingOperation<Void>] = [:]
    private var discovery: DiscoverySession?
    /// FIFO per characteristic. CoreBluetooth confirms writes in submission order, so the
    /// head of the queue always corresponds to the next `didWriteValueFor`.
    private var pendingWrites: [CBUUID: [PendingOperation<Void>]] = [:]
    private var pendingReads: [CBUUID: [PendingOperation<Data>]] = [:]
    private var pendingSubscribes: [CBUUID: PendingOperation<Void>] = [:]

    private var reassembler = FrameReassembler()
    private var sequence: UInt8 = 0

    /// Distinguishes a user-initiated teardown from a dropped link, so auto-reconnect
    /// does not fight an explicit disconnect.
    private var isIntentionalDisconnect = false
    private var reconnectTask: Task<Void, Never>?

    // MARK: - Init

    /// - Parameter enableStateRestoration: pass `true` only if the target declares the
    ///   `bluetooth-central` background mode. Without it iOS logs a warning and ignores
    ///   restoration.
    init(enableStateRestoration: Bool = false) {
        var captured: AsyncStream<BLEEvent>.Continuation!
        // Buffer rather than drop: telemetry bursts should survive a momentarily busy
        // consumer. `bufferingNewest` bounds memory if the consumer stalls entirely.
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { captured = $0 }
        self.continuation = captured

        super.init()

        var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: true]
        if enableStateRestoration {
            options[CBCentralManagerOptionRestoreIdentifierKey] = BLEConstants.restoreIdentifier
        }
        // Passing `queue` (not nil) keeps delegate work off the main thread.
        self.central = CBCentralManager(delegate: self, queue: queue, options: options)
    }

    deinit {
        reconnectTask?.cancel()
        continuation.finish()
    }

    // MARK: - Scanning

    /// Begins scanning.
    ///
    /// - Parameter filtered: when `true`, scans only for `BLEConstants.bridgeService`.
    ///   Filtered scanning is the only form that works while backgrounded, and is far
    ///   kinder to the battery. Unfiltered (`false`) reveals every nearby device, which is
    ///   what you want when first probing what the watch actually exposes.
    func startScan(filtered: Bool = true) {
        queue.async { [self] in
            guard state.isReady else {
                log(.warning, "Scan refused — \(state.displayName)")
                emit(.stateChanged(state))
                return
            }
            guard !central.isScanning else { return }

            advertisements.removeAll()
            let services = filtered ? [BLEConstants.bridgeService] : nil
            central.scanForPeripherals(
                withServices: services,
                // Repeated packets give live RSSI. Ignored in the background, and costly —
                // scanning is stopped as soon as the user picks a device.
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
            log(.info, filtered ? "Scanning for bridge service…" : "Scanning for all devices…")
            emit(.scanStarted)
        }
    }

    func stopScan() {
        queue.async { [self] in
            guard central.isScanning else { return }
            central.stopScan()
            log(.info, "Scan stopped")
            emit(.scanStopped)
        }
    }

    // MARK: - Connection

    /// Connects, discovers the profile, and enables notifications.
    ///
    /// Resolves only once the peripheral is genuinely usable — a bare `didConnect` is not
    /// enough, since no characteristic handles exist until discovery completes. Callers can
    /// therefore treat a successful return as "safe to `send`".
    func connect(to id: UUID) async throws {
        stopScan()
        // `cancelReconnect` touches queue-confined state, so it cannot be called directly
        // from this non-queue context.
        await onQueue { [self] in cancelReconnect() }

        try await withTimeout(
            seconds: BLEConstants.connectTimeout + BLEConstants.discoveryTimeout,
            operation: "Connect"
        ) { [self] in
            try await establishLink(to: id)
            try await discoverProfile()
            try await subscribeToTelemetry()

            // Emitted via `onQueue` rather than `queue.async` so `.ready` is guaranteed to
            // reach the stream before this method returns.
            await onQueue { [self] in
                guard let peripheral = activePeripheral else { return }
                let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
                log(.success, "Ready — negotiated write MTU \(mtu) bytes")
                emit(.ready(id: id, negotiatedMTU: mtu))
            }
        }
    }

    private func establishLink(to id: UUID) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    let operation = PendingOperation(cont)

                    // The cancellation handler may have run before this block was
                    // scheduled; without this check the continuation would be stored and
                    // never resumed.
                    guard !Task.isCancelled else {
                        operation.fail(BLEError.cancelled)
                        return
                    }
                    guard state.isReady else {
                        operation.fail(BLEError.bluetoothUnavailable(state))
                        return
                    }

                    // `retrievePeripherals` recovers a device across app launches, so a
                    // known watch can be reconnected without scanning first.
                    guard let peripheral = knownPeripherals[id]
                            ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
                        operation.fail(BLEError.connectionFailed("Unknown peripheral \(id)"))
                        return
                    }

                    knownPeripherals[id] = peripheral
                    peripheral.delegate = self
                    isIntentionalDisconnect = false

                    if peripheral.state == .connected {
                        activePeripheral = peripheral
                        operation.succeed()
                        return
                    }

                    pendingConnects[id] = operation
                    log(.info, "Connecting to \(peripheral.name ?? id.uuidString)…")
                    emit(.connecting(id: id))
                    central.connect(peripheral, options: [
                        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
                    ])
                }
            }
        } onCancel: {
            queue.async { [self] in
                guard let operation = pendingConnects.removeValue(forKey: id) else { return }
                if let peripheral = knownPeripherals[id] {
                    central.cancelPeripheralConnection(peripheral)
                }
                operation.fail(BLEError.cancelled)
            }
        }
    }

    /// Tears down the active link. Idempotent.
    func disconnect() {
        queue.async { [self] in
            cancelReconnect()
            isIntentionalDisconnect = true
            guard let peripheral = activePeripheral else { return }
            log(.info, "Disconnecting…")
            central.cancelPeripheralConnection(peripheral)
        }
    }

    // MARK: - Profile discovery

    /// Tracks a multi-callback discovery as one awaitable operation.
    ///
    /// CoreBluetooth reports characteristics with one `didDiscoverCharacteristicsFor` call
    /// *per service*, so completion means "every service has reported back", not "a
    /// callback arrived".
    private final class DiscoverySession {
        let operation: PendingOperation<Void>
        var outstandingServices: Set<CBUUID> = []
        var didReceiveServiceList = false

        init(_ operation: PendingOperation<Void>) { self.operation = operation }
    }

    private func discoverProfile() async throws {
        try await withTimeout(seconds: BLEConstants.discoveryTimeout, operation: "Service discovery") {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.queue.async { [self] in
                    let operation = PendingOperation(cont)
                    guard let peripheral = activePeripheral, peripheral.state == .connected else {
                        operation.fail(BLEError.notConnected)
                        return
                    }
                    characteristics.removeAll()
                    discovery = DiscoverySession(operation)
                    log(.info, "Discovering services…")
                    peripheral.discoverServices(BLEConstants.servicesOfInterest)
                }
            }
        }
    }

    private func subscribeToTelemetry() async throws {
        let uuid = BLEConstants.telemetryCharacteristic

        let isPresent = await onQueue { [self] in characteristics[uuid] != nil }
        guard isPresent else {
            // Not fatal: the watch may expose only standard services. `send` will report
            // the specific missing characteristic if the user tries to use the channel.
            await onQueue { [self] in
                log(.warning, "Telemetry characteristic absent — no stream available")
            }
            return
        }

        try await withTimeout(seconds: BLEConstants.requestTimeout, operation: "Enable notifications") {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.queue.async { [self] in
                    let operation = PendingOperation(cont)
                    guard let peripheral = activePeripheral,
                          let characteristic = characteristics[uuid] else {
                        operation.fail(BLEError.notConnected)
                        return
                    }
                    pendingSubscribes[uuid] = operation
                    reassembler.reset()
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }

    // MARK: - Data exchange

    /// Sends a command and waits for the link-layer write confirmation.
    ///
    /// Confirmation means the peripheral's controller accepted the bytes — not that the
    /// watch app processed them. Application-level acknowledgement is a separate `.ack`
    /// frame on the telemetry channel.
    func send(_ command: WatchCommand) async throws {
        let frame = await onQueue { [self] in
            sequence &+= 1
            return command.frame(sequence: sequence)
        }
        let payload = frame.encoded()

        try await write(payload, to: BLEConstants.commandCharacteristic)

        await onQueue { [self] in
            log(.info, "→ \(command.displayName)", payload: payload)
        }
    }

    private func write(_ data: Data, to uuid: CBUUID) async throws {
        try await withTimeout(seconds: BLEConstants.requestTimeout, operation: "Write") {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.queue.async { [self] in
                    let operation = PendingOperation(cont)
                    guard let peripheral = activePeripheral, peripheral.state == .connected else {
                        operation.fail(BLEError.notConnected)
                        return
                    }
                    guard let characteristic = characteristics[uuid] else {
                        operation.fail(BLEError.characteristicNotFound(uuid: uuid.uuidString))
                        return
                    }

                    let acknowledged = characteristic.properties.contains(.write)
                    let unacknowledged = characteristic.properties.contains(.writeWithoutResponse)
                    guard acknowledged || unacknowledged else {
                        operation.fail(BLEError.characteristicNotWritable(uuid: uuid.uuidString))
                        return
                    }

                    let type: CBCharacteristicWriteType = acknowledged ? .withResponse : .withoutResponse
                    let maximum = peripheral.maximumWriteValueLength(for: type)
                    guard data.count <= maximum else {
                        operation.fail(BLEError.payloadTooLarge(bytes: data.count, maximum: maximum))
                        return
                    }

                    if acknowledged {
                        pendingWrites[uuid, default: []].append(operation)
                        peripheral.writeValue(data, for: characteristic, type: .withResponse)
                    } else {
                        // `.withoutResponse` produces no callback, so resolve immediately.
                        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                        operation.succeed()
                    }
                }
            }
        }
    }

    /// Reads the device-info characteristic, if the peripheral exposes one.
    func readDeviceInfo() async throws -> String {
        let raw = try await read(from: BLEConstants.deviceInfoCharacteristic)
        guard let text = String(data: raw, encoding: .utf8) else {
            throw BLEError.malformedFrame("device info is not valid UTF-8")
        }
        return text
    }

    private func read(from uuid: CBUUID) async throws -> Data {
        try await withTimeout(seconds: BLEConstants.requestTimeout, operation: "Read") {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.queue.async { [self] in
                    let operation = PendingOperation(cont)
                    guard let peripheral = activePeripheral, peripheral.state == .connected else {
                        operation.fail(BLEError.notConnected)
                        return
                    }
                    guard let characteristic = characteristics[uuid] else {
                        operation.fail(BLEError.characteristicNotFound(uuid: uuid.uuidString))
                        return
                    }
                    guard characteristic.properties.contains(.read) else {
                        operation.fail(BLEError.readFailed("characteristic is not readable"))
                        return
                    }
                    pendingReads[uuid, default: []].append(operation)
                    peripheral.readValue(for: characteristic)
                }
            }
        }
    }

    // MARK: - Reconnection

    /// Retries with exponential backoff after an unexpected drop.
    private func scheduleReconnect(to id: UUID, attempt: Int = 1) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isIntentionalDisconnect, attempt <= 5 else { return }

        let delay = min(pow(2.0, Double(attempt - 1)), 16)
        log(.info, "Reconnecting in \(Int(delay))s (attempt \(attempt)/5)…")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }

            // Detach from `reconnectTask` before connecting. `connect` cancels any pending
            // reconnect, and this *is* that reconnect — leaving the reference in place
            // means `connect` cancels the very task awaiting it, so `establishLink` throws
            // `.cancelled` and the link can never recover.
            // `self.` is spelled out throughout this Task: a `[self]` capture list does not
            // re-enable implicit self once `self` has been rebound by `guard let self`.
            await self.onQueue { self.reconnectTask = nil }

            do {
                try await self.connect(to: id)
            } catch {
                self.queue.async {
                    guard !self.isIntentionalDisconnect else { return }
                    self.scheduleReconnect(to: id, attempt: attempt + 1)
                }
            }
        }
    }

    private func cancelReconnect() {
        dispatchPrecondition(condition: .onQueue(queue))
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - Teardown helpers

    /// Fails every in-flight operation. Called on disconnect so nothing awaits forever.
    private func failAllPending(with error: BLEError) {
        dispatchPrecondition(condition: .onQueue(queue))

        pendingConnects.values.forEach { $0.fail(error) }
        pendingConnects.removeAll()

        discovery?.operation.fail(error)
        discovery = nil

        pendingWrites.values.flatMap { $0 }.forEach { $0.fail(error) }
        pendingWrites.removeAll()

        pendingReads.values.flatMap { $0 }.forEach { $0.fail(error) }
        pendingReads.removeAll()

        pendingSubscribes.values.forEach { $0.fail(error) }
        pendingSubscribes.removeAll()
    }

    // MARK: - Emission

    /// Hops onto `queue`, runs `body` there, and returns its result.
    ///
    /// Used instead of `queue.sync` because blocking a Swift concurrency cooperative
    /// thread risks starving the pool — the runtime sizes it to the core count and assumes
    /// tasks never block.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            queue.async { cont.resume(returning: body()) }
        }
    }

    private func emit(_ event: BLEEvent) {
        continuation.yield(event)
    }

    private func log(_ level: LogEntry.Level, _ message: String, payload: Data? = nil) {
        switch level {
        case .error: logger.error("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        default: logger.debug("\(message, privacy: .public)")
        }
        emit(.log(LogEntry(level: level, message: message, payload: payload)))
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let new = BluetoothState(central.state)
        state = new
        log(new.isReady ? .success : .warning, new.displayName)
        emit(.stateChanged(new))

        if !new.isReady {
            // The link is gone implicitly; nothing will arrive to resolve pending work.
            failAllPending(with: .bluetoothUnavailable(new))
            activePeripheral = nil
            characteristics.removeAll()
            reassembler.reset()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        knownPeripherals[id] = peripheral

        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map { $0.uuidString.uppercased() }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true

        // RSSI of 127 is CoreBluetooth's "unavailable" sentinel, not a real reading.
        let rssi = RSSI.intValue == 127 ? (advertisements[id]?.rssi ?? -127) : RSSI.intValue

        let now = Date.now
        let record: DiscoveredPeripheral
        if let existing = advertisements[id] {
            // Advertisement packets alternate between AD and scan-response payloads, so a
            // repeat sighting often carries no name or service list. Keep the richer of
            // the two rather than letting a sparse packet blank the row.
            record = DiscoveredPeripheral(
                id: id,
                name: name ?? existing.name,
                rssi: rssi,
                isConnectable: connectable,
                advertisedServices: services.isEmpty ? existing.advertisedServices : services,
                firstSeen: existing.firstSeen,
                lastSeen: now
            )
        } else {
            record = DiscoveredPeripheral(
                id: id, name: name, rssi: rssi, isConnectable: connectable,
                advertisedServices: services, firstSeen: now, lastSeen: now
            )
            log(.debug, "Found \(record.displayName) @ \(rssi) dBm")
        }

        advertisements[id] = record
        emit(.discovered(record))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        activePeripheral = peripheral
        peripheral.delegate = self
        log(.success, "Connected to \(peripheral.name ?? peripheral.identifier.uuidString)")
        emit(.connected(id: peripheral.identifier, name: peripheral.name))
        pendingConnects.removeValue(forKey: peripheral.identifier)?.succeed()
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let failure = BLEError.connectionFailed(error?.localizedDescription)
        log(.error, failure.errorDescription ?? "Connection failed")
        pendingConnects.removeValue(forKey: peripheral.identifier)?.fail(failure)
        emit(.disconnected(id: peripheral.identifier, error: failure))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let id = peripheral.identifier
        let failure: BLEError? = error.map { .disconnected(reason: $0.localizedDescription) }

        log(failure == nil ? .info : .warning,
            failure?.errorDescription ?? "Disconnected cleanly")

        failAllPending(with: failure ?? .disconnected(reason: nil))

        if activePeripheral?.identifier == id {
            activePeripheral = nil
            characteristics.removeAll()
            reassembler.reset()
        }

        emit(.disconnected(id: id, error: failure))

        // Only chase the link back if it dropped on its own.
        if error != nil, !isIntentionalDisconnect {
            scheduleReconnect(to: id)
        }
    }

    /// Called when iOS relaunches the app into the background to hand back its central.
    /// The restored peripherals are already connected — do not reconnect, just re-adopt.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        log(.info, "State restored with \(restored.count) peripheral(s)")

        for peripheral in restored {
            knownPeripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected {
                activePeripheral = peripheral
                emit(.connected(id: peripheral.identifier, name: peripheral.name))
                // Handles are not restored with the peripheral; rebuild the cache.
                peripheral.discoverServices(BLEConstants.servicesOfInterest)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let session = discovery else { return }

        if let error {
            let failure = BLEError.connectionFailed(error.localizedDescription)
            log(.error, "Service discovery failed: \(error.localizedDescription)")
            session.operation.fail(failure)
            discovery = nil
            return
        }

        let services = peripheral.services ?? []
        session.didReceiveServiceList = true

        guard !services.isEmpty else {
            let failure = BLEError.serviceNotFound(uuid: BLEConstants.bridgeService.uuidString)
            log(.error, "Peripheral exposes no matching services")
            session.operation.fail(failure)
            discovery = nil
            return
        }

        let found = services.map { $0.uuid.uuidString }.joined(separator: ", ")
        log(.info, "Services: \(found)")

        if !services.contains(where: { $0.uuid == BLEConstants.bridgeService }) {
            // Deliberately non-fatal — connecting anyway lets the user inspect whatever
            // standard services the watch does expose, which is the usual first step.
            log(.warning, "Bridge service not present. Is the Wear OS GATT server running?")
        }

        session.outstandingServices = Set(services.map(\.uuid))
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let session = discovery else { return }

        if let error {
            log(.warning, "Characteristic discovery failed for \(service.uuid): \(error.localizedDescription)")
        } else {
            for characteristic in service.characteristics ?? [] {
                characteristics[characteristic.uuid] = characteristic
                log(.debug, "  \(characteristic.uuid) [\(Self.describe(characteristic.properties))]")
            }
        }

        session.outstandingServices.remove(service.uuid)
        guard session.outstandingServices.isEmpty else { return }

        log(.success, "Discovered \(characteristics.count) characteristic(s)")
        session.operation.succeed()
        discovery = nil
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let operation = pendingSubscribes.removeValue(forKey: characteristic.uuid) else { return }

        if let error {
            log(.error, "Notify enable failed: \(error.localizedDescription)")
            // Spelled out because `fail` takes `any Error`, so a leading dot has no base
            // type to resolve against.
            operation.fail(BLEError.subscribeFailed(error.localizedDescription))
        } else {
            log(.success, "Notifications \(characteristic.isNotifying ? "enabled" : "disabled") for \(characteristic.uuid)")
            operation.succeed()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // One callback serves both reads and notifications. A queued read for this
        // characteristic claims the value first; anything else is stream data.
        if var waiting = pendingReads[characteristic.uuid], !waiting.isEmpty {
            let operation = waiting.removeFirst()
            pendingReads[characteristic.uuid] = waiting.isEmpty ? nil : waiting

            if let error {
                operation.fail(BLEError.readFailed(error.localizedDescription))
            } else {
                operation.succeed(characteristic.value ?? Data())
            }
            return
        }

        if let error {
            log(.error, "Notification error: \(error.localizedDescription)")
            return
        }
        guard let chunk = characteristic.value, !chunk.isEmpty else { return }

        handleInbound(chunk)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard var waiting = pendingWrites[characteristic.uuid], !waiting.isEmpty else { return }
        let operation = waiting.removeFirst()
        pendingWrites[characteristic.uuid] = waiting.isEmpty ? nil : waiting

        if let error {
            log(.error, "Write failed: \(error.localizedDescription)")
            operation.fail(BLEError.writeFailed(error.localizedDescription))
        } else {
            operation.succeed()
        }
    }

    /// iOS tells us the peripheral changed its service table. Cached handles are now
    /// invalid and must be rediscovered.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        log(.warning, "Peripheral modified \(invalidatedServices.count) service(s); rediscovering")
        for service in invalidatedServices {
            for characteristic in service.characteristics ?? [] {
                characteristics.removeValue(forKey: characteristic.uuid)
            }
        }
        peripheral.discoverServices(BLEConstants.servicesOfInterest)
    }

    // MARK: - Inbound frame handling

    /// Feeds notification bytes through the reassembler and dispatches whole frames.
    ///
    /// Single-channel: only the telemetry characteristic is subscribed, so there is one
    /// reassembly buffer. Subscribing to a second notify characteristic would need one
    /// buffer per characteristic — their packets interleave on the wire.
    private func handleInbound(_ chunk: Data) {
        dispatchPrecondition(condition: .onQueue(queue))

        let frames: [Frame]
        do {
            frames = try reassembler.ingest(chunk)
        } catch {
            let message = (error as? BLEError)?.errorDescription ?? error.localizedDescription
            log(.error, "Frame stream desynchronised: \(message)", payload: chunk)
            return
        }

        for frame in frames {
            switch frame.opcode {
            case .telemetry:
                do {
                    let packet = try TelemetryPacket(payload: frame.payload)
                    emit(.telemetry(packet))
                } catch {
                    let message = (error as? BLEError)?.errorDescription ?? error.localizedDescription
                    log(.error, "Bad telemetry payload: \(message)", payload: frame.payload)
                }

            case .error:
                let text = String(data: frame.payload, encoding: .utf8) ?? "(unreadable)"
                log(.error, "Watch reported: \(text)")
                emit(.frameReceived(frame))

            case .ack:
                log(.debug, "← ack seq \(frame.sequence)")
                emit(.frameReceived(frame))

            default:
                log(.debug, "← \(frame.opcode) seq \(frame.sequence)", payload: frame.payload)
                emit(.frameReceived(frame))
            }
        }
    }

    private static func describe(_ properties: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if properties.contains(.read) { parts.append("read") }
        if properties.contains(.write) { parts.append("write") }
        if properties.contains(.writeWithoutResponse) { parts.append("writeNR") }
        if properties.contains(.notify) { parts.append("notify") }
        if properties.contains(.indicate) { parts.append("indicate") }
        return parts.isEmpty ? "none" : parts.joined(separator: "|")
    }
}
