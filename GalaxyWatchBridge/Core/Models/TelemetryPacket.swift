import Foundation

/// One telemetry sample from the watch.
///
/// Wire payload is a fixed 16 bytes, chosen to fit inside the default 20-byte ATT payload
/// so a sample never needs fragmenting even before MTU negotiation completes:
///
/// ```text
///  offset  size  field
///  0       8     timestamp, Unix epoch milliseconds (little-endian)
///  8       2     heart rate, BPM (0 = no reading)
///  10      4     step count since midnight
///  14      1     battery percent, 0–100
///  15      1     flags — bit0 charging, bit1 on-wrist, bit2 HR sensor contact
/// ```
struct TelemetryPacket: Sendable, Equatable, Identifiable {
    static let payloadSize = 16

    let timestamp: Date
    /// `nil` when the watch reported no reading (wire value 0), which is normal while the
    /// optical sensor is settling or off-wrist.
    let heartRate: Int?
    let steps: Int
    let batteryPercent: Int
    let isCharging: Bool
    let isOnWrist: Bool
    let hasSensorContact: Bool

    /// Stable per-sample identity for SwiftUI lists. Two samples from the same millisecond
    /// would collide, but the watch cannot produce them faster than that.
    var id: Date { timestamp }

    // MARK: - Decoding

    init(payload: Data) throws {
        guard payload.count >= Self.payloadSize else {
            throw BLEError.malformedFrame(
                "telemetry needs \(Self.payloadSize) bytes, got \(payload.count)"
            )
        }

        var reader = ByteReader(payload)
        let epochMillis = try reader.u64()
        let bpm = try reader.u16()
        let steps = try reader.u32()
        let battery = try reader.u8()
        let flags = try reader.u8()

        self.timestamp = Date(timeIntervalSince1970: Double(epochMillis) / 1000)
        self.heartRate = bpm == 0 ? nil : Int(bpm)
        self.steps = Int(steps)
        // Clamp rather than throw: a firmware bug reporting 255% should degrade the
        // display, not kill the stream.
        self.batteryPercent = min(Int(battery), 100)
        self.isCharging = flags & 0b0000_0001 != 0
        self.isOnWrist = flags & 0b0000_0010 != 0
        self.hasSensorContact = flags & 0b0000_0100 != 0
    }

    // MARK: - Encoding (tests, simulator, and the Wear OS reference implementation)

    init(
        timestamp: Date,
        heartRate: Int?,
        steps: Int,
        batteryPercent: Int,
        isCharging: Bool = false,
        isOnWrist: Bool = true,
        hasSensorContact: Bool = true
    ) {
        self.timestamp = timestamp
        self.heartRate = heartRate
        self.steps = steps
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.isOnWrist = isOnWrist
        self.hasSensorContact = hasSensorContact
    }

    func encodedPayload() -> Data {
        var w = ByteWriter()
        w.u64(UInt64(max(0, timestamp.timeIntervalSince1970 * 1000)))
        w.u16(UInt16(clamping: heartRate ?? 0))
        w.u32(UInt32(clamping: steps))
        w.u8(UInt8(clamping: batteryPercent))
        var flags: UInt8 = 0
        if isCharging { flags |= 0b0000_0001 }
        if isOnWrist { flags |= 0b0000_0010 }
        if hasSensorContact { flags |= 0b0000_0100 }
        w.u8(flags)
        return w.data
    }

    // MARK: - Display

    var heartRateText: String { heartRate.map(String.init) ?? "—" }
    var stepsText: String { steps.formatted(.number.grouping(.automatic)) }
    var batteryText: String { "\(batteryPercent)%" }

    static let preview = TelemetryPacket(
        timestamp: .now,
        heartRate: 72,
        steps: 8_432,
        batteryPercent: 64,
        isCharging: false
    )
}

// MARK: - Outbound commands

/// Phone → watch commands, each with its own payload encoding.
enum WatchCommand: Sendable, Equatable {
    /// Stream telemetry every `interval`. The watch clamps to its own supported range.
    case startStream(interval: Duration)
    case stopStream
    case requestSample
    /// Buzz the watch for `duration` — the cheapest end-to-end link check there is.
    case vibrate(duration: Duration)

    var opcode: Opcode {
        switch self {
        case .startStream: .startStream
        case .stopStream: .stopStream
        case .requestSample: .requestSample
        case .vibrate: .vibrate
        }
    }

    var payload: Data {
        var w = ByteWriter()
        switch self {
        case .startStream(let interval):
            w.u16(UInt16(clamping: interval.milliseconds))
        case .vibrate(let duration):
            w.u16(UInt16(clamping: duration.milliseconds))
        case .stopStream, .requestSample:
            break
        }
        return w.data
    }

    func frame(sequence: UInt8) -> Frame {
        Frame(opcode: opcode, sequence: sequence, payload: payload)
    }

    var displayName: String {
        switch self {
        case .startStream(let interval): "Start stream (\(interval.milliseconds) ms)"
        case .stopStream: "Stop stream"
        case .requestSample: "Request sample"
        case .vibrate(let duration): "Vibrate (\(duration.milliseconds) ms)"
        }
    }
}

extension Duration {
    /// Whole milliseconds, discarding sub-millisecond precision.
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
