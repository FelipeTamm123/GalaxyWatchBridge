import CoreBluetooth

/// `CBUUID` is an immutable wrapper around a 128-bit value, but Apple has not annotated it
/// `Sendable`. Without this, every `@Sendable` closure that touches a UUID constant — and
/// every `static let` below — is a concurrency error under the Swift 6 language mode.
///
/// Declared retroactively in one place rather than worked around at each use site. Sound
/// because `CBUUID` exposes no mutating API. If a future SDK annotates it, delete this.
extension CBUUID: @unchecked @retroactive Sendable {}

/// GATT identifiers for the bridge.
///
/// The `bridge*` UUIDs are arbitrary 128-bit values that **must match byte-for-byte** the
/// UUIDs registered by the Wear OS `BluetoothGattServer` (see `WearOS-Peripheral/`).
/// Change them here and you must change them there; a mismatch presents as a watch that
/// advertises but exposes no services.
///
/// The `standard*` UUIDs are Bluetooth SIG assigned numbers, given as 16-bit shorthand.
/// CoreBluetooth expands those to the full base UUID automatically. They are here because
/// some wearables expose Battery Service or Heart Rate Service without any custom app —
/// worth probing before assuming you need a custom peripheral.
enum BLEConstants {

    // MARK: - Custom bridge profile

    /// Primary service the iOS central scans for.
    static let bridgeService = CBUUID(string: "8E7C0001-4B2A-4E1F-9C3D-5A6B7C8D9E0F")

    /// Watch → phone. Notify-only. Carries framed `TelemetryPacket` payloads.
    static let telemetryCharacteristic = CBUUID(string: "8E7C0002-4B2A-4E1F-9C3D-5A6B7C8D9E0F")

    /// Phone → watch. Write-with-response. Carries framed `WatchCommand` payloads.
    static let commandCharacteristic = CBUUID(string: "8E7C0003-4B2A-4E1F-9C3D-5A6B7C8D9E0F")

    /// Watch → phone. Read-only. UTF-8 JSON describing model, firmware and protocol version.
    static let deviceInfoCharacteristic = CBUUID(string: "8E7C0004-4B2A-4E1F-9C3D-5A6B7C8D9E0F")

    /// Characteristics the manager subscribes to once the profile is discovered.
    static let subscribeOnConnect: Set<CBUUID> = [telemetryCharacteristic]

    // MARK: - Standard SIG services

    static let standardBatteryService = CBUUID(string: "180F")
    static let standardBatteryLevel = CBUUID(string: "2A19")
    static let standardHeartRateService = CBUUID(string: "180D")
    static let standardHeartRateMeasurement = CBUUID(string: "2A37")
    static let standardDeviceInformationService = CBUUID(string: "180A")

    /// Services requested during discovery. Passing an explicit list rather than `nil`
    /// keeps discovery fast — `nil` walks the peripheral's entire attribute table.
    static let servicesOfInterest: [CBUUID] = [
        bridgeService,
        standardBatteryService,
        standardHeartRateService,
    ]

    // MARK: - Tuning

    /// Key used for `CBCentralManagerOptionRestoreIdentifierKey`. Required for the system
    /// to relaunch the app into `willRestoreState` after a background termination.
    static let restoreIdentifier = "com.felipetamm.galaxywatchbridge.central"

    static let connectTimeout: TimeInterval = 15
    static let discoveryTimeout: TimeInterval = 20
    static let requestTimeout: TimeInterval = 10

    /// A discovered device is dropped from the list if it has not been seen for this long.
    static let staleDeviceInterval: TimeInterval = 12
}
