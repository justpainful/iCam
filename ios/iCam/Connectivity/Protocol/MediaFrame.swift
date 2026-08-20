import Foundation

/// Video channel header — `docs/PROTOCOL.md` section 6.
struct VideoFrameHeader: Equatable, Sendable {
    static let size = 24

    enum Flags: UInt8 {
        case keyframe       = 0x01
        case parameterSets  = 0x02
        case endOfStream    = 0x04
    }

    var codec: VideoCodec
    var isKeyframe: Bool
    var isParameterSets: Bool
    var isEndOfStream: Bool = false
    var sequence: UInt32
    var ptsUs: UInt64
    var dtsUs: UInt64

    var encoded: Data {
        var d = Data(capacity: Self.size)
        d.append(codec == .h264 ? 1 : 2)
        var flags: UInt8 = 0
        if isKeyframe { flags |= Flags.keyframe.rawValue }
        if isParameterSets { flags |= Flags.parameterSets.rawValue }
        if isEndOfStream { flags |= Flags.endOfStream.rawValue }
        d.append(flags)
        d.appendUInt16BE(0)
        d.appendUInt32BE(sequence)
        d.appendUInt64BE(ptsUs)
        d.appendUInt64BE(dtsUs)
        return d
    }

    static func decode(_ data: Data) -> (header: VideoFrameHeader, body: Data)? {
        guard data.count >= size else { return nil }
        let rawCodec = data[data.startIndex]
        guard let codec: VideoCodec = rawCodec == 1 ? .h264 : (rawCodec == 2 ? .hevc : nil) else {
            return nil
        }
        let flags = data[data.startIndex + 1]
        let header = VideoFrameHeader(
            codec: codec,
            isKeyframe: flags & Flags.keyframe.rawValue != 0,
            isParameterSets: flags & Flags.parameterSets.rawValue != 0,
            isEndOfStream: flags & Flags.endOfStream.rawValue != 0,
            sequence: data.readUInt32BE(at: 4),
            ptsUs: data.readUInt64BE(at: 8),
            dtsUs: data.readUInt64BE(at: 16))
        let body = data.subdata(in: data.startIndex + size ..< data.endIndex)
        return (header, body)
    }
}

enum AudioCodec: UInt8, Sendable {
    case aacLC = 1
    case pcmS16LE = 2
}

/// Audio channel header — `docs/PROTOCOL.md` section 7.
struct AudioFrameHeader: Equatable, Sendable {
    static let size = 20

    var codec: AudioCodec
    var channels: UInt8
    var isParameterSets: Bool
    var sampleRate: UInt32
    var sequence: UInt32
    var ptsUs: UInt64

    var encoded: Data {
        var d = Data(capacity: Self.size)
        d.append(codec.rawValue)
        d.append(channels)
        d.append(isParameterSets ? 0x02 : 0x00)
        d.append(0)
        d.appendUInt32BE(sampleRate)
        d.appendUInt32BE(sequence)
        d.appendUInt64BE(ptsUs)
        return d
    }

    static func decode(_ data: Data) -> (header: AudioFrameHeader, body: Data)? {
        guard data.count >= size,
              let codec = AudioCodec(rawValue: data[data.startIndex]) else { return nil }
        let header = AudioFrameHeader(
            codec: codec,
            channels: data[data.startIndex + 1],
            isParameterSets: data[data.startIndex + 2] & 0x02 != 0,
            sampleRate: data.readUInt32BE(at: 4),
            sequence: data.readUInt32BE(at: 8),
            ptsUs: data.readUInt64BE(at: 12))
        let body = data.subdata(in: data.startIndex + size ..< data.endIndex)
        return (header, body)
    }
}

/// Bulk channel header — `docs/PROTOCOL.md` section 8.
struct BulkFrameHeader: Equatable, Sendable {
    static let size = 16
    static let maxChunkBytes = 256 * 1024
    static let ackIntervalBytes: UInt64 = 4 * 1024 * 1024

    enum Kind: UInt8 {
        case offer = 1, chunk = 2, ack = 3, done = 4, cancel = 5
    }

    var kind: Kind
    var transferId: UInt32
    var offset: UInt64

    var encoded: Data {
        var d = Data(capacity: Self.size)
        d.append(kind.rawValue)
        d.append(contentsOf: [0, 0, 0])
        d.appendUInt32BE(transferId)
        d.appendUInt64BE(offset)
        return d
    }

    static func decode(_ data: Data) -> (header: BulkFrameHeader, body: Data)? {
        guard data.count >= size, let kind = Kind(rawValue: data[data.startIndex]) else { return nil }
        let header = BulkFrameHeader(kind: kind,
                                     transferId: data.readUInt32BE(at: 4),
                                     offset: data.readUInt64BE(at: 8))
        return (header, data.subdata(in: data.startIndex + size ..< data.endIndex))
    }
}

struct BulkOffer: Codable, Sendable {
    var name: String
    var bytes: UInt64
    var sha256: String
    var kind: String            // "photo" | "segment"
    var sessionId: String?
    var rangeUs: [UInt64]?
}
