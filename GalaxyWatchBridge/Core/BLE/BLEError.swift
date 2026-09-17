import Foundation

/// Every failure the BLE layer can surface, as a value type.
///
/// Deliberately not wrapping `CBError` / `NSError`: those carry non-`Sendable` userInfo
/// dictionaries and leak CoreBluetooth into the UI. Descriptions are flattened to
/// `String` at the boundary in `BLEManager`.
enum BLEError: LocalizedError, Equatable, Sendable {

    /// The radio is not in a usable state. Carries the state so the UI can explain why.
    case bluetoothUnavailable(BluetoothState)

    /// No `didConnect` / `didFailToConnect` arrived within the timeout. Common when the
    /// peripheral stopped advertising between discovery and the connect attempt.
    case timedOut(operation: String)

    /// The central reported an outright connection failure.
    case connectionFailed(String?)

    /// The link dropped. `nil` reason means a clean, locally-initiated teardown.
    case disconnected(reason: String?)

    /// Operation attempted with no live connection.
    case notConnected

    /// The peripheral does not expose the expected service — almost always means the
    /// Wear OS GATT server is not running, or its UUIDs disagree with `BLEConstants`.
    case serviceNotFound(uuid: String)

    case characteristicNotFound(uuid: String)

    /// The characteristic exists but lacks the property the operation needs
    /// (e.g. writing to a notify-only characteristic).
    case characteristicNotWritable(uuid: String)

    case writeFailed(String?)
    case readFailed(String?)
    case subscribeFailed(String?)

    /// Payload exceeds the negotiated ATT MTU for this link.
    case payloadTooLarge(bytes: Int, maximum: Int)

    /// A received frame could not be parsed. Carries a human-readable reason.
    case malformedFrame(String)

    /// The awaiting `Task` was cancelled.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let state):
            state.displayName
        case .timedOut(let operation):
            "\(operation) timed out."
        case .connectionFailed(let reason):
            reason.map { "Connection failed: \($0)" } ?? "Connection failed."
        case .disconnected(let reason):
            reason.map { "Disconnected: \($0)" } ?? "Disconnected."
        case .notConnected:
            "Not connected to a peripheral."
        case .serviceNotFound(let uuid):
            "Service \(uuid) not found on this peripheral."
        case .characteristicNotFound(let uuid):
            "Characteristic \(uuid) not found."
        case .characteristicNotWritable(let uuid):
            "Characteristic \(uuid) does not support writing."
        case .writeFailed(let reason):
            reason.map { "Write failed: \($0)" } ?? "Write failed."
        case .readFailed(let reason):
            reason.map { "Read failed: \($0)" } ?? "Read failed."
        case .subscribeFailed(let reason):
            reason.map { "Could not enable notifications: \($0)" } ?? "Could not enable notifications."
        case .payloadTooLarge(let bytes, let maximum):
            "Payload is \(bytes) bytes; this link allows \(maximum)."
        case .malformedFrame(let reason):
            "Malformed frame: \(reason)"
        case .cancelled:
            "Operation cancelled."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .bluetoothUnavailable(let state):
            state.recoverySuggestion
        case .timedOut, .connectionFailed:
            "Make sure the watch app is in the foreground and advertising, then try again."
        case .serviceNotFound:
            "Confirm the Wear OS GATT server is running and its service UUID matches BLEConstants.bridgeService."
        case .payloadTooLarge:
            "Split the payload across multiple frames."
        default:
            nil
        }
    }

    /// Whether retrying the same operation could plausibly succeed.
    var isRetryable: Bool {
        switch self {
        case .timedOut, .connectionFailed, .disconnected, .notConnected, .writeFailed, .readFailed:
            true
        case .bluetoothUnavailable(let state):
            state.isTransient
        case .serviceNotFound, .characteristicNotFound, .characteristicNotWritable,
             .payloadTooLarge, .malformedFrame, .subscribeFailed, .cancelled:
            false
        }
    }
}
