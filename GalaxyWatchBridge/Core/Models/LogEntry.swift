import Foundation

/// One line in the in-app BLE console.
///
/// A visible log is not a luxury for BLE work — most failures are silent (wrong UUID, no
/// advertisement, notification never enabled) and produce no error at all. Surfacing the
/// event sequence is usually the only way to tell which of those happened.
struct LogEntry: Identifiable, Sendable, Equatable {
    enum Level: Sendable, Equatable {
        case debug, info, success, warning, error

        var symbolName: String {
            switch self {
            case .debug: "ladybug"
            case .info: "info.circle"
            case .success: "checkmark.circle"
            case .warning: "exclamationmark.triangle"
            case .error: "xmark.octagon"
            }
        }
    }

    let id = UUID()
    let timestamp: Date
    let level: Level
    let message: String
    /// Optional hex dump, attached for raw traffic so payloads can be diffed against the
    /// watch-side logs.
    let payloadHex: String?

    init(level: Level, message: String, payload: Data? = nil, timestamp: Date = .now) {
        self.level = level
        self.message = message
        self.payloadHex = payload.map(Self.hex)
        self.timestamp = timestamp
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var timeText: String {
        Self.formatter.string(from: timestamp)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
