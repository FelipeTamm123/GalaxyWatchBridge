import Foundation

// MARK: - Byte-level helpers

/// Bounds-checked sequential reader over a `Data`.
///
/// Works in offsets relative to `startIndex` so it behaves correctly on slices —
/// `Data` slices keep the parent's indices, and indexing a slice from `0` is a
/// classic source of crashes when reassembling BLE frames.
struct ByteReader {
    private let data: Data
    private var offset: Int = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - offset }
    var isExhausted: Bool { remaining == 0 }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw BLEError.malformedFrame("negative read length") }
        guard remaining >= count else {
            throw BLEError.malformedFrame("need \(count) bytes, \(remaining) remain")
        }
        let start = data.startIndex + offset
        defer { offset += count }
        return [UInt8](data[start..<(start + count)])
    }

    mutating func u8() throws -> UInt8 { try bytes(1)[0] }

    mutating func u16() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    mutating func u64() throws -> UInt64 {
        let lo = try u32()
        let hi = try u32()
        return UInt64(lo) | UInt64(hi) << 32
    }
}

/// Little-endian byte accumulator.
struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }

    mutating func u16(_ value: UInt16) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value),
                                 UInt8(truncatingIfNeeded: value >> 8)])
    }

    mutating func u32(_ value: UInt32) {
        data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }

    mutating func u64(_ value: UInt64) {
        data.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }

    mutating func raw(_ bytes: Data) { data.append(bytes) }
}

// MARK: - Framing

/// Opcodes shared with the Wear OS peer. Values are part of the wire contract — append
/// only, never renumber.
enum Opcode: UInt8, Sendable, CaseIterable {
    /// Watch → phone: a `TelemetryPacket`.
    case telemetry = 0x01
    /// Phone → watch: begin streaming telemetry at the requested cadence.
    case startStream = 0x10
    /// Phone → watch: stop streaming.
    case stopStream = 0x11
    /// Phone → watch: request one telemetry sample immediately.
    case requestSample = 0x12
    /// Phone → watch: trigger a short haptic buzz, to confirm the link end-to-end.
    case vibrate = 0x13
    /// Either direction: application-level acknowledgement.
    case ack = 0x7E
    /// Either direction: application-level error, payload is a UTF-8 message.
    case error = 0x7F
}

/// A length-prefixed frame.
///
/// ```text
///  offset  size  field
///  0       1     opcode
///  1       1     sequence          (wraps at 256; for loss detection only)
///  2       2     payloadLength     (little-endian)
///  4       n     payload
/// ```
///
/// The explicit length prefix is what makes reassembly possible: BLE notifications are
/// capped at `ATT_MTU - 3`, so a payload larger than that arrives as several packets with
/// no delivery framing of its own.
struct Frame: Sendable, Equatable {
    static let headerSize = 4
    /// Guards against a corrupt length prefix causing unbounded buffering.
    static let maxPayloadSize = 4096

    let opcode: Opcode
    let sequence: UInt8
    let payload: Data

    init(opcode: Opcode, sequence: UInt8 = 0, payload: Data = Data()) {
        self.opcode = opcode
        self.sequence = sequence
        self.payload = payload
    }

    func encoded() -> Data {
        var w = ByteWriter()
        w.u8(opcode.rawValue)
        w.u8(sequence)
        w.u16(UInt16(payload.count))
        w.raw(payload)
        return w.data
    }

    /// A successfully decoded frame and how many bytes it occupied.
    ///
    /// A named type rather than a tuple: tuples get no automatic `Equatable` conformance,
    /// which makes them awkward to assert against in tests.
    struct Decoded: Sendable, Equatable {
        let frame: Frame
        let consumed: Int
    }

    /// Decodes exactly one frame from the front of `data`.
    /// - Returns: the frame and the number of bytes consumed, or `nil` if `data` does not
    ///   yet hold a complete frame. `nil` means *incomplete*, which is a normal mid-stream
    ///   state — distinct from a throw, which means the stream is corrupt.
    static func decode(from data: Data) throws -> Decoded? {
        guard data.count >= headerSize else { return nil }

        var reader = ByteReader(data)
        let rawOpcode = try reader.u8()
        let sequence = try reader.u8()
        let length = Int(try reader.u16())

        guard let opcode = Opcode(rawValue: rawOpcode) else {
            throw BLEError.malformedFrame(String(format: "unknown opcode 0x%02X", rawOpcode))
        }
        guard length <= maxPayloadSize else {
            throw BLEError.malformedFrame("payload length \(length) exceeds \(maxPayloadSize)")
        }

        let total = headerSize + length
        guard data.count >= total else { return nil }  // incomplete; wait for more

        let start = data.startIndex + headerSize
        let payload = Data(data[start..<(start + length)])
        return Decoded(
            frame: Frame(opcode: opcode, sequence: sequence, payload: payload),
            consumed: total
        )
    }
}

/// Accumulates incoming notification packets and yields whole frames.
///
/// Not thread-safe by design — `BLEManager` confines it to its serial queue.
struct FrameReassembler {
    private var buffer = Data()

    /// Appends received bytes and drains every complete frame now available.
    /// - Throws: `BLEError.malformedFrame` if the stream desynchronises. The buffer is
    ///   cleared first, so the caller may keep using the reassembler afterwards.
    mutating func ingest(_ chunk: Data) throws -> [Frame] {
        buffer.append(chunk)
        var frames: [Frame] = []

        while true {
            do {
                guard let decoded = try Frame.decode(from: buffer) else { break }
                frames.append(decoded.frame)
                buffer.removeFirst(decoded.consumed)
            } catch {
                buffer.removeAll(keepingCapacity: true)
                throw error
            }
        }
        return frames
    }

    mutating func reset() { buffer.removeAll(keepingCapacity: true) }

    var bufferedByteCount: Int { buffer.count }
}
