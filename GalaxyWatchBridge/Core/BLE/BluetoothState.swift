import CoreBluetooth

/// A `Sendable` mirror of `CBManagerState`.
///
/// `CBManagerState` is itself trivially sendable, but keeping a domain-owned enum means
/// nothing above `BLEManager` has to import CoreBluetooth, and the UI layer can switch
/// exhaustively over states that actually matter to it.
enum BluetoothState: Sendable, Equatable {
    /// The manager has not yet reported in. Never act on this — just wait.
    case unknown
    /// The system Bluetooth stack is restarting. Transient; a real state follows shortly.
    case resetting
    /// This device has no BLE radio (only the Simulator, in practice).
    case unsupported
    /// The user denied Bluetooth permission, or it was never requested.
    case unauthorized
    /// The radio is off at the OS level.
    case poweredOff
    /// Ready. This is the only state in which scanning or connecting is legal.
    case poweredOn

    init(_ state: CBManagerState) {
        switch state {
        case .unknown: self = .unknown
        case .resetting: self = .resetting
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .poweredOff: self = .poweredOff
        case .poweredOn: self = .poweredOn
        @unknown default: self = .unknown
        }
    }

    /// Whether BLE operations may be issued right now.
    var isReady: Bool { self == .poweredOn }

    /// Whether this state can still change on its own. `.unsupported` and `.unauthorized`
    /// are terminal from the app's point of view — retrying accomplishes nothing.
    var isTransient: Bool {
        switch self {
        case .unknown, .resetting: true
        case .unsupported, .unauthorized, .poweredOff, .poweredOn: false
        }
    }

    var displayName: String {
        switch self {
        case .unknown: "Checking Bluetooth…"
        case .resetting: "Bluetooth is restarting…"
        case .unsupported: "Bluetooth LE not supported"
        case .unauthorized: "Bluetooth permission denied"
        case .poweredOff: "Bluetooth is off"
        case .poweredOn: "Bluetooth ready"
        }
    }

    /// Actionable next step for the user, or `nil` when there is nothing for them to do.
    var recoverySuggestion: String? {
        switch self {
        case .unauthorized:
            "Enable Bluetooth for this app in Settings › Privacy & Security › Bluetooth."
        case .poweredOff:
            "Turn Bluetooth on in Settings or Control Center."
        case .unsupported:
            "This device has no Bluetooth LE radio. Run on a physical iPhone."
        case .unknown, .resetting, .poweredOn:
            nil
        }
    }
}
