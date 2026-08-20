import Foundation

/// Control channel — `docs/PROTOCOL.md` section 5.
///
/// The envelope is deliberately tiny. The payload is a typed struct per message
/// type; nothing on this channel is a free-form string command.
struct ControlEnvelope: Codable, Sendable {
    var t: String
    var id: UInt32
    var r: UInt32?
    var p: JSONValue?

    init(t: String, id: UInt32, r: UInt32? = nil, p: JSONValue? = nil) {
        self.t = t
        self.id = id
        self.r = r
        self.p = p
    }
}

enum ControlType {
    static let deviceInfo          = "device.info"
    static let capabilities        = "camera.capabilities"
    static let cameraState         = "camera.state"
    static let cameraCommand       = "camera.command"
    static let cameraCommandResult = "camera.command.result"

    static let streamStart  = "stream.start"
    static let streamStop   = "stream.stop"
    static let streamConfig = "stream.config"
    static let streamStatus = "stream.status"
    /// PC → phone: the decoder lost its place; send an IDR now.
    static let streamKeyframe = "stream.keyframe"

    static let recordStart  = "record.start"
    static let recordStop   = "record.stop"
    static let recordState  = "record.state"
    static let photoCapture = "photo.capture"
    static let photoResult  = "photo.result"

    static let telemetry = "telemetry"
    static let timePing  = "time.ping"
    static let timePong  = "time.pong"
    static let error     = "error"
}

// MARK: - Payloads

struct DeviceInfo: Codable, Equatable, Sendable {
    var name: String
    var model: String
    var os: String
    var app: String
    /// Fingerprint of the identity key: first 16 bytes of SHA-256, lowercase hex.
    var id: String = ""
}

struct CameraCommandPayload: Codable, Sendable {
    var base: UInt64
    var set: CameraMutation
}

struct CameraCommandResult: Codable, Sendable {
    var ok: Bool
    var appliedVersion: UInt64
    var error: ProtocolError?
}

struct StreamStartPayload: Codable, Sendable {
    var profile: StreamProfile
}

struct StreamStatusPayload: Codable, Sendable {
    var active: Bool
    var actual: StreamProfile
    var reason: String?
}

struct RecordStartPayload: Codable, Sendable {
    var target: CaptureTarget
    var sessionId: String
    var startedAtUs: UInt64
}

struct RecordStopPayload: Codable, Sendable {
    var sessionId: String
}

struct RecordStatePayload: Codable, Sendable {
    var recording: Bool
    var sessionId: String?
    var target: CaptureTarget
    var elapsedUs: UInt64
    var phoneOk: Bool
    var pcOk: Bool
}

struct PhotoCapturePayload: Codable, Sendable {
    var target: CaptureTarget
    var requestId: UInt32
}

struct PhotoResultPayload: Codable, Sendable {
    var requestId: UInt32
    var ok: Bool
    var assetId: String?
    var transferId: UInt32?
    var error: ProtocolError?
}

struct TelemetryPayload: Codable, Equatable, Sendable {
    var thermal: String
    var pressure: String
    var battery: Double
    var power: String
    var storageFreeBytes: UInt64
    var capture: CaptureStats
    var encoder: EncoderStats

    struct CaptureStats: Codable, Equatable, Sendable {
        var fps: Double
        var dropped: UInt64
    }

    struct EncoderStats: Codable, Equatable, Sendable {
        var fps: Double
        var bitrate: Int
        var latencyUs: UInt64
    }
}

struct TimePingPayload: Codable, Sendable {
    var t1: UInt64
}

struct TimePongPayload: Codable, Sendable {
    var t1: UInt64
    var t2: UInt64
    var t3: UInt64
}

struct ProtocolError: Codable, Equatable, Sendable {
    var code: String
    var message: String
    var detail: String?
}

// MARK: - Codec

/// Encodes and decodes control messages. Uses sorted keys so that two peers
/// always produce byte-identical JSON — which the handshake transcript depends
/// on, and which makes the conformance vectors meaningful.
enum ControlCodec {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder = JSONDecoder()

    static func encode<T: Encodable>(type: String, id: UInt32, replyTo: UInt32? = nil,
                                     payload: T) throws -> Data {
        let payloadData = try encoder.encode(payload)
        let value = try decoder.decode(JSONValue.self, from: payloadData)
        return try encoder.encode(ControlEnvelope(t: type, id: id, r: replyTo, p: value))
    }

    static func encodeEmpty(type: String, id: UInt32, replyTo: UInt32? = nil) throws -> Data {
        try encoder.encode(ControlEnvelope(t: type, id: id, r: replyTo, p: .object([:])))
    }

    static func envelope(from data: Data) throws -> ControlEnvelope {
        try decoder.decode(ControlEnvelope.self, from: data)
    }

    static func payload<T: Decodable>(_ type: T.Type, from envelope: ControlEnvelope) throws -> T {
        guard let p = envelope.p else {
            throw ICamError(code: "protocol.malformed",
                            title: String(localized: "Connection problem"),
                            message: String(localized: "The other device sent something iCam could not read."),
                            detail: "missing payload for \(envelope.t)")
        }
        return try decoder.decode(T.self, from: try encoder.encode(p))
    }
}

/// A minimal JSON tree, so the envelope can carry any payload without the
/// control loop having to know every payload type up front.
indirect enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:            try c.encodeNil()
        case .bool(let v):     try c.encode(v)
        case .number(let v):   try c.encode(v)
        case .string(let v):   try c.encode(v)
        case .array(let v):    try c.encode(v)
        case .object(let v):   try c.encode(v)
        }
    }
}
