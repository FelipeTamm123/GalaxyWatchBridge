import Foundation
import Testing

@testable import GalaxyWatchBridge

// MARK: - Telemetry payload

@Suite("Telemetry payload")
struct TelemetryPacketTests {

    @Test("Round-trips every field through the binary encoding")
    func roundTrip() throws {
        let original = TelemetryPacket(
            timestamp: Date(timeIntervalSince1970: 1_767_225_600),
            heartRate: 142,
            steps: 12_345,
            calories: 412.5,
            distanceMeters: 6_240,
            batteryPercent: 87,
            isCharging: true,
            isOnWrist: true,
            hasHeartRateSensor: false
        )

        let decoded = try TelemetryPacket(payload: original.encodedPayload())

        #expect(decoded.heartRate == 142)
        #expect(decoded.steps == 12_345)
        #expect(decoded.calories == 412.5)
        #expect(decoded.distanceMeters == 6_240)
        #expect(decoded.batteryPercent == 87)
        #expect(decoded.isCharging)
        #expect(decoded.isOnWrist == true)
        #expect(!decoded.hasHeartRateSensor)
        // Millisecond resolution on the wire, so compare within one.
        #expect(abs(decoded.timestamp.timeIntervalSince(original.timestamp)) < 0.001)
    }

    @Test("A sample no longer fits one unnegotiated notification")
    func payloadExceedsDefaultMTU() {
        let payload = TelemetryPacket.preview.encodedPayload()
        #expect(payload.count == TelemetryPacket.payloadSize)

        // 28 + 4 header. The default 23-byte ATT MTU allows only 20 bytes per
        // notification, so delivery now depends on either MTU negotiation (iOS requests
        // ~185 on connect) or FrameReassembler joining the fragments. Asserted rather
        // than merely documented, because a future field pushing this past a negotiated
        // MTU would be a real regression.
        let frame = Frame(opcode: .telemetry, payload: payload)
        #expect(frame.encoded().count == 32)
        #expect(frame.encoded().count > 20)
        #expect(frame.encoded().count < 185)
    }

    @Test("Wire value 0 for heart rate decodes as no reading, not zero BPM")
    func zeroHeartRateIsAbsent() throws {
        let packet = TelemetryPacket(timestamp: .now, heartRate: nil, steps: 0)
        let decoded = try TelemetryPacket(payload: packet.encodedPayload())
        #expect(decoded.heartRate == nil)
        #expect(decoded.heartRateText == "—")
        // Zero steps must survive as zero — it is a real reading, unlike a zero BPM.
        #expect(decoded.steps == 0)
    }

    @Test("Absent numeric fields use sentinels, not zero")
    func sentinelsDecodeAsNil() throws {
        let packet = TelemetryPacket(
            timestamp: .now,
            heartRate: nil,
            steps: nil,
            calories: nil,
            distanceMeters: nil,
            batteryPercent: nil,
            isOnWrist: nil
        )
        let decoded = try TelemetryPacket(payload: packet.encodedPayload())

        #expect(decoded.heartRate == nil)
        #expect(decoded.steps == nil)
        #expect(decoded.calories == nil)
        #expect(decoded.distanceMeters == nil)
        #expect(decoded.batteryPercent == nil)
        // nil means "no off-body sensor", which must stay distinct from false.
        #expect(decoded.isOnWrist == nil)
        #expect(decoded.stepsText == "—")
        #expect(decoded.batteryText == "—")
    }

    @Test("Zero battery is a reading, not an absent value")
    func zeroBatteryIsReal() throws {
        let packet = TelemetryPacket(timestamp: .now, batteryPercent: 0)
        let decoded = try TelemetryPacket(payload: packet.encodedPayload())
        #expect(decoded.batteryPercent == 0)
        #expect(decoded.batteryText == "0%")
    }

    @Test("Calories keep one decimal place")
    func caloriePrecision() throws {
        let packet = TelemetryPacket(timestamp: .now, calories: 1234.7)
        let decoded = try TelemetryPacket(payload: packet.encodedPayload())
        #expect(decoded.calories == 1234.7)
    }

    @Test("Out-of-range battery is clamped rather than rejected")
    func batteryClamps() throws {
        // A firmware bug reporting 120% should degrade the display, not kill the stream.
        var writer = ByteWriter()
        writer.u64(UInt64(Date.now.timeIntervalSince1970 * 1000))
        writer.u16(70)
        writer.u32(100)
        writer.u32(0)
        writer.u32(0)
        writer.u8(120)
        writer.u8(0)
        writer.u32(0)

        let decoded = try TelemetryPacket(payload: writer.data)
        #expect(decoded.batteryPercent == 100)
    }

    @Test("Short payload throws instead of reading out of bounds")
    func shortPayloadThrows() {
        #expect(throws: BLEError.self) {
            try TelemetryPacket(payload: Data([0x01, 0x02, 0x03]))
        }
    }

    @Test("Flag bits are independent, including the on-wrist tri-state")
    func flagsAreIndependent() throws {
        for charging in [true, false] {
            for onWrist in [true, false, nil] {
                for hasSensor in [true, false] {
                    let packet = TelemetryPacket(
                        timestamp: .now,
                        heartRate: 60,
                        steps: 1,
                        batteryPercent: 1,
                        isCharging: charging,
                        isOnWrist: onWrist,
                        hasHeartRateSensor: hasSensor
                    )
                    let decoded = try TelemetryPacket(payload: packet.encodedPayload())
                    #expect(decoded.isCharging == charging)
                    #expect(decoded.isOnWrist == onWrist)
                    #expect(decoded.hasHeartRateSensor == hasSensor)
                }
            }
        }
    }
}

// MARK: - Framing

@Suite("Frame codec")
struct FrameTests {

    @Test("Round-trips opcode, sequence and payload")
    func roundTrip() throws {
        let frame = Frame(opcode: .startStream, sequence: 42, payload: Data([0xE8, 0x03]))
        let result = try Frame.decode(from: frame.encoded())

        let decoded = try #require(result)
        #expect(decoded.frame == frame)
        #expect(decoded.consumed == 6)
    }

    @Test("Header shorter than 4 bytes yields nil, not an error")
    func partialHeaderIsIncomplete() throws {
        // Incomplete is a normal state mid-stream, distinct from malformed.
        #expect(try Frame.decode(from: Data([0x01, 0x00])) == nil)
    }

    @Test("Declared payload longer than the buffer yields nil")
    func partialPayloadIsIncomplete() throws {
        // Header claims 16 bytes of payload; only 2 are present.
        let partial = Data([0x01, 0x00, 0x10, 0x00, 0xAA, 0xBB])
        #expect(try Frame.decode(from: partial) == nil)
    }

    @Test("Unknown opcode is rejected")
    func unknownOpcodeThrows() {
        #expect(throws: BLEError.self) {
            try Frame.decode(from: Data([0xCC, 0x00, 0x00, 0x00]))
        }
    }

    @Test("Absurd length prefix is rejected before it can be buffered")
    func oversizedLengthThrows() {
        // 0xFFFF payload length — guards against a corrupt prefix driving unbounded growth.
        #expect(throws: BLEError.self) {
            try Frame.decode(from: Data([0x01, 0x00, 0xFF, 0xFF]))
        }
    }

    @Test("Decodes correctly from a non-zero-based Data slice")
    func worksOnSlices() throws {
        let frame = Frame(opcode: .ack, sequence: 7, payload: Data([0x01]))
        // Data slices retain the parent's indices. Indexing one from 0 is the classic
        // reassembly crash; this asserts the reader uses startIndex-relative offsets.
        let padded = Data([0xFF, 0xFF, 0xFF]) + frame.encoded()
        let slice = padded.dropFirst(3)

        let decoded = try #require(try Frame.decode(from: slice))
        #expect(decoded.frame == frame)
    }
}

// MARK: - Reassembly

@Suite("Frame reassembly")
struct FrameReassemblerTests {

    @Test("Emits a frame delivered in one chunk")
    func singleChunk() throws {
        var reassembler = FrameReassembler()
        let frame = Frame(opcode: .telemetry, payload: TelemetryPacket.preview.encodedPayload())

        let frames = try reassembler.ingest(frame.encoded())

        #expect(frames == [frame])
        #expect(reassembler.bufferedByteCount == 0)
    }

    @Test("Reassembles a frame split across several notifications")
    func splitAcrossChunks() throws {
        var reassembler = FrameReassembler()
        let frame = Frame(opcode: .telemetry, payload: TelemetryPacket.preview.encodedPayload())
        let encoded = frame.encoded()

        // Deliver a byte at a time — the pathological case for a length-prefixed protocol.
        var collected: [Frame] = []
        for byte in encoded {
            collected += try reassembler.ingest(Data([byte]))
        }

        #expect(collected == [frame])
        #expect(reassembler.bufferedByteCount == 0)
    }

    @Test("Drains several frames arriving in one chunk")
    func coalescedFrames() throws {
        var reassembler = FrameReassembler()
        let first = Frame(opcode: .ack, sequence: 1, payload: Data([0x01]))
        let second = Frame(opcode: .telemetry, sequence: 2, payload: TelemetryPacket.preview.encodedPayload())

        let frames = try reassembler.ingest(first.encoded() + second.encoded())

        #expect(frames == [first, second])
    }

    @Test("Keeps a trailing partial frame buffered for the next chunk")
    func retainsRemainder() throws {
        var reassembler = FrameReassembler()
        let complete = Frame(opcode: .ack, sequence: 1, payload: Data([0x01]))
        let next = Frame(opcode: .ack, sequence: 2, payload: Data([0x02]))
        let nextEncoded = next.encoded()

        let firstBatch = try reassembler.ingest(complete.encoded() + nextEncoded.prefix(3))
        #expect(firstBatch == [complete])
        #expect(reassembler.bufferedByteCount == 3)

        let secondBatch = try reassembler.ingest(nextEncoded.dropFirst(3))
        #expect(secondBatch == [next])
        #expect(reassembler.bufferedByteCount == 0)
    }

    @Test("Clears the buffer on desync so the reassembler stays usable")
    func recoversAfterDesync() throws {
        var reassembler = FrameReassembler()

        #expect(throws: BLEError.self) {
            try reassembler.ingest(Data([0xCC, 0x00, 0x00, 0x00]))
        }
        // Buffer must be cleared, or the bad bytes poison every later ingest.
        #expect(reassembler.bufferedByteCount == 0)

        let good = Frame(opcode: .ack, sequence: 9, payload: Data())
        #expect(try reassembler.ingest(good.encoded()) == [good])
    }
}

// MARK: - Commands

@Suite("Outbound commands")
struct WatchCommandTests {

    @Test("Stream interval is encoded little-endian")
    func streamIntervalEncoding() {
        let command = WatchCommand.startStream(interval: .seconds(1))
        // 1000 ms = 0x03E8, low byte first.
        #expect(Array(command.payload) == [0xE8, 0x03])
    }

    @Test("Commands without arguments carry an empty payload")
    func emptyPayloads() {
        #expect(WatchCommand.stopStream.payload.isEmpty)
        #expect(WatchCommand.requestSample.payload.isEmpty)
    }

    @Test("Duration converts to whole milliseconds")
    func durationConversion() {
        #expect(Duration.seconds(1).milliseconds == 1000)
        #expect(Duration.milliseconds(250).milliseconds == 250)
        #expect(Duration.seconds(5).milliseconds == 5000)
    }

    @Test("Every command maps to its wire opcode")
    func opcodeMapping() {
        #expect(WatchCommand.startStream(interval: .seconds(1)).opcode == .startStream)
        #expect(WatchCommand.stopStream.opcode == .stopStream)
        #expect(WatchCommand.requestSample.opcode == .requestSample)
        #expect(WatchCommand.vibrate(duration: .milliseconds(400)).opcode == .vibrate)
    }
}
