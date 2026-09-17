import Foundation

/// Everything the BLE layer pushes upward, as a single `Sendable` stream.
///
/// Why a stream instead of `@Published` properties on the manager: the manager's delegate
/// callbacks arrive on a private serial queue, so `@Published` there would publish off the
/// main actor. Funnelling through `AsyncStream` makes the actor hop explicit and puts all
/// UI state on `@MainActor` in `WatchViewModel`, where it belongs. Every payload here is a
/// value type, so nothing crosses the boundary that could be mutated concurrently.
enum BLEEvent: Sendable {
    /// Radio state changed. Always the first event delivered.
    case stateChanged(BluetoothState)

    /// A peripheral was seen, or re-seen with a new RSSI.
    case discovered(DiscoveredPeripheral)

    case scanStarted
    case scanStopped

    case connecting(id: UUID)

    /// Link established. Services are not yet discovered — do not send anything.
    case connected(id: UUID, name: String?)

    /// Profile discovered and notifications enabled. Safe to send commands from here on.
    case ready(id: UUID, negotiatedMTU: Int)

    case disconnected(id: UUID, error: BLEError?)

    /// A decoded telemetry sample.
    case telemetry(TelemetryPacket)

    /// A frame that is not telemetry (ack, error, or an opcode this build doesn't model).
    case frameReceived(Frame)

    /// Diagnostics destined for the on-screen console.
    case log(LogEntry)
}
