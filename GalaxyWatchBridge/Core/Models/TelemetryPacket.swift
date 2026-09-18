import Foundation

/// One telemetry sample from the watch.
///
/// Wire payload is a fixed 28 bytes:
///
/// ```text
///  offset  size  field
///  0       8     timestamp, Unix epoch milliseconds (little-endian)
///  8       2     heart rate, BPM            (0 = no reading)
///  10      4     steps today                (0xFFFFFFFF = no reading)
///  14      4     calories today, kcal × 10  (0xFFFFFFFF = no reading)
///  18      4     distance today, metres     (0xFFFFFFFF = no reading)
///  22      1     battery percent, 0–100     (0xFF = no reading)
///  23      1     flags — see below
///  24      4     reserved, must be zero
/// ```
///
/// Flags: bit0 charging · bit1 on-wrist · bit2 on-wrist *known* · bit3 HR sensor available
///
/// ## Why sentinels instead of zero
///
/// Every optional field needs a value meaning "no reading", because zero is legitimate for
/// most of them — a step count of 0 at 6am is real data, and a heart rate of 0 would be a
/// medical emergency rather than a missing sample. Only heart rate can use 0 as its
/// sentinel, since a live 0 BPM is not a thing this device would report.
///
/// ## This no longer fits an unnegotiated MTU
///
/// At 28 bytes plus the 4-byte frame header, a sample exceeds the 20-byte payload of the
/// default 23-byte ATT MTU. In practice iOS negotiates ~185 bytes immediately on connect,
/// so a sample arrives in one notification. If negotiation has not happened yet, the frame
/// arrives split and `FrameReassembler` joins it — which is exactly what the length prefix
/// exists for. The previous 16-byte layout fit in one packet unconditionally; that
/// property is gone, and the reassembler is now load-bearing rather than defensive.
struct TelemetryPacket: Sendable, Equatable, Identifiable {
    static let payloadSize = 28

    /// Sentinel for absent 32-bit values.
    private static let absent32: UInt32 = .max
    /// Sentinel for an absent battery reading.
    private static let absentBattery: UInt8 = 0xFF

    let timestamp: Date

    /// `nil` when the optical sensor has no reading — normal while it settles, off-wrist,
    /// or when measurement is not running.
    let heartRate: Int?
    let steps: Int?
    /// Kilocalories, one decimal place of precision.
    let calories: Double?
    let distanceMeters: Double?
    let batteryPercent: Int?

    let isCharging: Bool
    /// `nil` when the watch has no off-body sensor, so "off wrist" and "cannot tell" stay
    /// distinguishable.
    let isOnWrist: Bool?
    let hasHeartRateSensor: Bool

    /// Stable per-sample identity for SwiftUI lists. Two samples from the same millisecond
    /// would collide, but the watch cannot produce them that fast.
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
        let rawSteps = try reader.u32()
        let rawCalories = try reader.u32()
        let rawDistance = try reader.u32()
        let rawBattery = try reader.u8()
        let flags = try reader.u8()

        self.timestamp = Date(timeIntervalSince1970: Double(epochMillis) / 1000)
        self.heartRate = bpm == 0 ? nil : Int(bpm)
        self.steps = rawSteps == Self.absent32 ? nil : Int(rawSteps)
        self.calories = rawCalories == Self.absent32 ? nil : Double(rawCalories) / 10
        self.distanceMeters = rawDistance == Self.absent32 ? nil : Double(rawDistance)

        // Clamp rather than throw: firmware reporting 120% should degrade the display,
        // not kill the stream.
        self.batteryPercent = rawBattery == Self.absentBattery ? nil : min(Int(rawBattery), 100)

        self.isCharging = flags & 0b0000_0001 != 0
        let onWristKnown = flags & 0b0000_0100 != 0
        self.isOnWrist = onWristKnown ? (flags & 0b0000_0010 != 0) : nil
        self.hasHeartRateSensor = flags & 0b0000_1000 != 0
    }

    // MARK: - Encoding (tests, previews, and the Wear OS reference implementation)

    init(
        timestamp: Date,
        heartRate: Int? = nil,
        steps: Int? = nil,
        calories: Double? = nil,
        distanceMeters: Double? = nil,
        batteryPercent: Int? = nil,
        isCharging: Bool = false,
        isOnWrist: Bool? = true,
        hasHeartRateSensor: Bool = true
    ) {
        self.timestamp = timestamp
        self.heartRate = heartRate
        self.steps = steps
        self.calories = calories
        self.distanceMeters = distanceMeters
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.isOnWrist = isOnWrist
        self.hasHeartRateSensor = hasHeartRateSensor
    }

    func encodedPayload() -> Data {
        var w = ByteWriter()
        w.u64(UInt64(max(0, timestamp.timeIntervalSince1970 * 1000)))
        w.u16(UInt16(clamping: heartRate ?? 0))
        w.u32(steps.map { UInt32(clamping: $0) } ?? Self.absent32)
        w.u32(calories.map { UInt32(clamping: Int(($0 * 10).rounded())) } ?? Self.absent32)
        w.u32(distanceMeters.map { UInt32(clamping: Int($0.rounded())) } ?? Self.absent32)
        w.u8(batteryPercent.map { UInt8(clamping: $0) } ?? Self.absentBattery)

        var flags: UInt8 = 0
        if isCharging { flags |= 0b0000_0001 }
        if let isOnWrist {
            flags |= 0b0000_0100
            if isOnWrist { flags |= 0b0000_0010 }
        }
        if hasHeartRateSensor { flags |= 0b0000_1000 }
        w.u8(flags)

        w.u32(0) // reserved
        return w.data
    }

    // MARK: - Display

    var heartRateText: String { heartRate.map(String.init) ?? "—" }

    var stepsText: String {
        steps.map { $0.formatted(.number.grouping(.automatic)) } ?? "—"
    }

    var batteryText: String { batteryPercent.map { "\($0)%" } ?? "—" }

    var caloriesText: String {
        guard let calories else { return "—" }
        return calories.formatted(.number.precision(.fractionLength(0)))
    }

    /// Metres below a kilometre, kilometres above — a raw metre count reads poorly once
    /// it passes a few thousand.
    var distanceText: String {
        guard let distanceMeters else { return "—" }
        if distanceMeters < 1000 {
            return "\(Int(distanceMeters))"
        }
        return (distanceMeters / 1000).formatted(.number.precision(.fractionLength(2)))
    }

    var distanceUnit: String {
        guard let distanceMeters else { return "—" }
        return distanceMeters < 1000 ? "metres" : "km"
    }

    static let preview = TelemetryPacket(
        timestamp: .now,
        heartRate: 72,
        steps: 8_432,
        calories: 412.5,
        distanceMeters: 6_240,
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
