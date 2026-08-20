import Foundation

/// Wire framing — `docs/PROTOCOL.md` section 3.
///
/// ```
/// 0  u32be length   (bytes following this field)
/// 4  u8   channel
/// 5  u8   flags
/// 6  u16be reserved (0)
/// 8  payload[length - 4]
/// ```
enum Wire {
    static let protocolVersion = 1
    static let defaultPort: UInt16 = 48213
    static let bonjourType = "_icam._tcp"

    static let headerSize = 8
    static let maxFrameLength = 16 * 1024 * 1024
}

enum Channel: UInt8, Sendable, CaseIterable {
    case handshake = 0
    case control   = 1
    case video     = 2
    case audio     = 3
    case bulk      = 4
}

struct FrameFlags: OptionSet, Sendable {
    let rawValue: UInt8
    static let endOfMessage = FrameFlags(rawValue: 1 << 0)
}

struct Frame: Sendable, Equatable {
    var channel: Channel
    var flags: FrameFlags
    var payload: Data

    init(channel: Channel, flags: FrameFlags = .endOfMessage, payload: Data) {
        self.channel = channel
        self.flags = flags
        self.payload = payload
    }

    /// The 8-byte header exactly as it goes on the wire. Also the AEAD
    /// associated data, which is why it is built in one place only.
    static func header(channel: Channel, flags: FrameFlags, payloadCount: Int) -> Data {
        var header = Data(capacity: Wire.headerSize)
        header.appendUInt32BE(UInt32(payloadCount + 4))
        header.append(channel.rawValue)
        header.append(flags.rawValue)
        header.appendUInt16BE(0)
        return header
    }

    var encoded: Data {
        var out = Frame.header(channel: channel, flags: flags, payloadCount: payload.count)
        out.append(payload)
        return out
    }

    static func == (a: Frame, b: Frame) -> Bool {
        a.channel == b.channel && a.flags.rawValue == b.flags.rawValue && a.payload == b.payload
    }
}

enum FrameError: Error, Equatable {
    case oversizedFrame(Int)
    case unknownChannel(UInt8)
    case reservedNotZero
    case truncated
}

/// Incremental frame parser. Sockets hand it whatever arrived; it hands back
/// whole frames. It never copies the buffer more than once per frame and it
/// drops consumed bytes eagerly so a long session does not grow a backlog.
struct FrameParser {
    private var buffer = Data()

    mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// Returns the next complete frame, along with its raw header for AEAD use,
    /// or `nil` when more bytes are needed.
    mutating func next() throws -> (frame: Frame, header: Data)? {
        guard buffer.count >= Wire.headerSize else { return nil }

        let length = Int(buffer.readUInt32BE(at: 0))
        guard length >= 4 else { throw FrameError.truncated }
        guard length <= Wire.maxFrameLength else { throw FrameError.oversizedFrame(length) }

        let total = 4 + length
        guard buffer.count >= total else { return nil }

        let rawChannel = buffer[buffer.startIndex + 4]
        let rawFlags = buffer[buffer.startIndex + 5]
        guard buffer.readUInt16BE(at: 6) == 0 else { throw FrameError.reservedNotZero }
        guard let channel = Channel(rawValue: rawChannel) else {
            // Unknown channels are skipped, not fatal: a newer peer may use one
            // we do not implement yet. Consume the bytes and keep going.
            buffer.removeFirst(total)
            throw FrameError.unknownChannel(rawChannel)
        }

        let header = buffer.subdata(in: buffer.startIndex ..< buffer.startIndex + Wire.headerSize)
        let payload = buffer.subdata(in: buffer.startIndex + Wire.headerSize ..< buffer.startIndex + total)
        buffer.removeFirst(total)

        return (Frame(channel: channel, flags: FrameFlags(rawValue: rawFlags), payload: payload), header)
    }

    var pendingByteCount: Int { buffer.count }

    mutating func reset() { buffer.removeAll(keepingCapacity: false) }
}

// MARK: - Big-endian helpers

extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16
             | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        let i = startIndex + offset
        for k in 0 ..< 8 { value = value << 8 | UInt64(self[i + k]) }
        return value
    }
}
