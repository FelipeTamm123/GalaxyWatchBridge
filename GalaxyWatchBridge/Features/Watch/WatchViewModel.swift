import Foundation
import Observation

/// Single source of truth for the watch screen.
///
/// Isolated to `@MainActor`, so every property SwiftUI observes is mutated on the main
/// thread by construction — there is no `DispatchQueue.main.async` anywhere in this type
/// because there is no way to reach it off the main actor. `BLEManager` does its work on a
/// background queue and hands results over as `Sendable` values through `AsyncStream`;
/// `consumeEvents()` is the single crossing point.
@MainActor
@Observable
final class WatchViewModel {

    /// Coarse lifecycle for the UI to switch on. Finer detail (which characteristic, which
    /// error) lives in the log, not here.
    enum Phase: Equatable {
        case idle
        case scanning
        case connecting
        /// Link established, profile discovery in flight. Commands are not yet legal.
        case connected
        /// Discovery finished and notifications enabled. Commands are legal.
        case ready

        var isBusy: Bool { self == .connecting || self == .connected }
        var isLinked: Bool { self == .connected || self == .ready }
    }

    /// Telemetry cadences offered in the control panel.
    enum StreamRate: String, CaseIterable, Identifiable {
        case fast = "4 Hz"
        case normal = "1 Hz"
        case slow = "0.2 Hz"

        var id: String { rawValue }

        var interval: Duration {
            switch self {
            case .fast: .milliseconds(250)
            case .normal: .seconds(1)
            case .slow: .seconds(5)
            }
        }
    }

    // MARK: - Observed state

    private(set) var bluetoothState: BluetoothState = .unknown
    private(set) var phase: Phase = .idle
    private(set) var devices: [DiscoveredPeripheral] = []

    private(set) var connectedDeviceID: UUID?
    private(set) var connectedDeviceName: String?
    private(set) var negotiatedMTU: Int?

    private(set) var latestTelemetry: TelemetryPacket?
    /// Bounded ring of recent samples, for the sparkline.
    private(set) var telemetryHistory: [TelemetryPacket] = []
    private(set) var receivedPacketCount = 0

    private(set) var logs: [LogEntry] = []
    private(set) var lastError: BLEError?

    /// Reflects what we last asked the watch for, not confirmed watch state — the watch
    /// may refuse or stop on its own. Treat as intent.
    private(set) var isStreaming = false

    /// Unfiltered scans reveal every nearby device. Useful for discovering what a watch
    /// exposes; unavailable in the background and heavier on the battery.
    var scanUnfiltered = false
    var streamRate: StreamRate = .normal

    // MARK: - Limits

    private static let historyLimit = 120
    private static let logLimit = 500

    // MARK: - Dependencies

    private let manager: BLEManager
    private var eventTask: Task<Void, Never>?
    private var pruneTask: Task<Void, Never>?

    init(manager: BLEManager = BLEManager()) {
        self.manager = manager
    }

    // MARK: - Lifecycle

    /// Starts consuming BLE events. Safe to call repeatedly; only the first call takes
    /// effect. Driven from the view's `.task`, so the stream lives exactly as long as the
    /// screen does.
    func activate() {
        guard eventTask == nil else { return }

        eventTask = Task { [weak self] in
            guard let self else { return }
            // Task created inside a @MainActor method inherits the main actor, so every
            // `apply` below lands on the main thread without an explicit hop.
            for await event in self.manager.events {
                self.apply(event)
            }
        }

        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.pruneStaleDevices()
            }
        }
    }

    func deactivate() {
        eventTask?.cancel()
        eventTask = nil
        pruneTask?.cancel()
        pruneTask = nil
    }

    // MARK: - Intents

    func toggleScan() {
        if phase == .scanning {
            manager.stopScan()
        } else {
            devices.removeAll()
            lastError = nil
            manager.startScan(filtered: !scanUnfiltered)
        }
    }

    func connect(to device: DiscoveredPeripheral) {
        lastError = nil
        phase = .connecting
        Task {
            do {
                try await manager.connect(to: device.id)
            } catch {
                // `connect` already logged the specifics; this drives the alert.
                present(error)
                phase = .idle
            }
        }
    }

    func disconnect() {
        isStreaming = false
        manager.disconnect()
    }

    func send(_ command: WatchCommand) {
        guard phase == .ready else {
            lastError = .notConnected
            return
        }
        Task {
            do {
                try await manager.send(command)
            } catch {
                present(error)
            }
        }
    }

    func toggleStream() {
        if isStreaming {
            send(.stopStream)
            isStreaming = false
        } else {
            send(.startStream(interval: streamRate.interval))
            isStreaming = true
        }
    }

    func requestSingleSample() { send(.requestSample) }

    func buzzWatch() { send(.vibrate(duration: .milliseconds(400))) }

    func clearLogs() { logs.removeAll() }

    func clearTelemetry() {
        telemetryHistory.removeAll()
        latestTelemetry = nil
        receivedPacketCount = 0
    }

    func dismissError() { lastError = nil }

    /// Settable projection of `lastError` for `.alert(isPresented:)`.
    ///
    /// Exists so the view can use `$viewModel.isShowingError` instead of a manual
    /// `Binding(get:set:)`, whose closures are non-isolated and therefore cannot touch
    /// this `@MainActor` type under strict concurrency checking.
    var isShowingError: Bool {
        get { lastError != nil }
        set { if !newValue { lastError = nil } }
    }

    // MARK: - Event application

    private func apply(_ event: BLEEvent) {
        switch event {
        case .stateChanged(let state):
            bluetoothState = state
            if !state.isReady { resetLink() }

        case .discovered(let device):
            upsert(device)

        case .scanStarted:
            phase = .scanning

        case .scanStopped:
            if phase == .scanning { phase = .idle }

        case .connecting:
            phase = .connecting

        case .connected(let id, let name):
            phase = .connected
            connectedDeviceID = id
            connectedDeviceName = name

        case .ready(let id, let mtu):
            phase = .ready
            connectedDeviceID = id
            negotiatedMTU = mtu

        case .disconnected(let id, let error):
            // Ignore a stale disconnect for a peripheral we already moved on from.
            guard connectedDeviceID == nil || connectedDeviceID == id else { return }
            resetLink()
            if let error { lastError = error }

        case .telemetry(let packet):
            latestTelemetry = packet
            receivedPacketCount += 1
            telemetryHistory.append(packet)
            if telemetryHistory.count > Self.historyLimit {
                telemetryHistory.removeFirst(telemetryHistory.count - Self.historyLimit)
            }

        case .frameReceived:
            // Already logged by the manager; nothing further for the UI.
            break

        case .log(let entry):
            logs.append(entry)
            if logs.count > Self.logLimit {
                logs.removeFirst(logs.count - Self.logLimit)
            }
        }
    }

    private func resetLink() {
        phase = .idle
        connectedDeviceID = nil
        connectedDeviceName = nil
        negotiatedMTU = nil
        isStreaming = false
    }

    private func upsert(_ device: DiscoveredPeripheral) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
            sortDevices()
        }
        // Note: no re-sort on update. With `allowDuplicates` on, RSSI changes every few
        // hundred milliseconds; re-sorting each time makes rows jump under the user's
        // finger. Position is fixed at first sighting instead.
    }

    private func sortDevices() {
        devices.sort { lhs, rhs in
            // Devices running the bridge service float to the top — they are the only ones
            // that can actually do anything.
            if lhs.advertisesBridgeService != rhs.advertisesBridgeService {
                return lhs.advertisesBridgeService
            }
            if (lhs.name == nil) != (rhs.name == nil) {
                return lhs.name != nil
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func pruneStaleDevices() {
        guard phase == .scanning else { return }
        let now = Date.now
        devices.removeAll { $0.isStale(asOf: now) }
    }

    private func present(_ error: Error) {
        lastError = (error as? BLEError) ?? .connectionFailed(error.localizedDescription)
    }

    // MARK: - Derived display values

    var statusText: String {
        switch phase {
        case .idle: bluetoothState.isReady ? "Idle" : bluetoothState.displayName
        case .scanning: "Scanning…"
        case .connecting: "Connecting…"
        case .connected: "Discovering services…"
        case .ready: connectedDeviceName ?? "Connected"
        }
    }

    var canScan: Bool {
        bluetoothState.isReady && !phase.isLinked
    }

    /// Heart-rate series for the sparkline, oldest first. Samples with no reading are
    /// dropped rather than plotted as zero.
    var heartRateSeries: [Double] {
        telemetryHistory.compactMap { $0.heartRate.map(Double.init) }
    }
}
