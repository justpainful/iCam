import Foundation
import CryptoKit

/// Handshake messages — `docs/PROTOCOL.md` section 4.
///
/// These are the only plaintext bytes on the connection. Both peers must
/// produce byte-identical JSON for the transcript to match, so everything here
/// goes through `HandshakeCodec`, which sorts keys and escapes nothing extra.
enum HandshakeCodec {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder = JSONDecoder()

    static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    /// Peeks at `t` without committing to a concrete message type.
    static func messageType(of data: Data) -> String? {
        struct Peek: Decodable { let t: String }
        return try? decoder.decode(Peek.self, from: data).t
    }
}

struct ClientHello: Codable, Sendable {
    var t = "hello"
    var v = Wire.protocolVersion
    var eph: Data          // ephemeral P-256 public key, X9.63
    var idk: Data          // identity P-256 public key, X9.63
    var rnd: Data          // 32 random bytes
    var dev: DeviceInfo
}

struct ServerHello: Codable, Sendable {
    var t = "hello_ack"
    var v = Wire.protocolVersion
    var eph: Data
    var idk: Data
    var rnd: Data
    var dev: DeviceInfo
    var sig: Data?

    /// The exact bytes the transcript covers: this message with `sig` omitted.
    func transcriptBytes() throws -> Data {
        var copy = self
        copy.sig = nil
        return try HandshakeCodec.encode(copy)
    }
}

struct ClientAuth: Codable, Sendable {
    var t = "auth"
    var sig: Data
}

struct HandshakeReady: Codable, Sendable {
    var t = "ready"
    var trusted: Bool
}

enum HandshakeError: Error, Equatable {
    case versionMismatch(Int)
    case malformed(String)
    case badSignature
    case untrusted
    case wrongMessage(expected: String, got: String)
}

/// Drives the initiator half of the handshake. The iPhone is always the
/// initiator: it browses, it connects, it proves itself first.
final class InitiatorHandshake {
    private let identity: DeviceIdentity
    private let deviceInfo: DeviceInfo
    private let ephemeral = P256.KeyAgreement.PrivateKey()
    private let clientRandom = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })

    private var helloBytes = Data()

    private(set) var peerIdentityKey = Data()
    private(set) var peerDevice: DeviceInfo?
    private(set) var keys: SessionKeys?

    init(identity: DeviceIdentity, deviceInfo: DeviceInfo) {
        self.identity = identity
        self.deviceInfo = deviceInfo
    }

    /// Step 1 — the bytes to send.
    func clientHello() throws -> Data {
        var info = deviceInfo
        info.id = identity.fingerprint
        let hello = ClientHello(eph: ephemeral.publicKey.x963Representation,
                                idk: identity.publicKeyData,
                                rnd: clientRandom,
                                dev: info)
        helloBytes = try HandshakeCodec.encode(hello)
        return helloBytes
    }

    /// Step 2 and 3 — consume the server hello, produce the client auth.
    func handle(serverHello data: Data) throws -> Data {
        let hello = try HandshakeCodec.decode(ServerHello.self, from: data)
        guard hello.t == "hello_ack" else {
            throw HandshakeError.wrongMessage(expected: "hello_ack", got: hello.t)
        }
        guard hello.v == Wire.protocolVersion else {
            throw HandshakeError.versionMismatch(hello.v)
        }
        guard let signature = hello.sig else { throw HandshakeError.malformed("missing sig") }

        var transcript = helloBytes
        transcript.append(try hello.transcriptBytes())

        var serverMessage = Data("iCam/v1/server".utf8)
        serverMessage.append(transcript)
        guard DeviceIdentity.verify(signature: signature,
                                    message: serverMessage,
                                    publicKey: hello.idk) else {
            throw HandshakeError.badSignature
        }

        guard let peerEphemeral = try? P256.KeyAgreement.PublicKey(x963Representation: hello.eph) else {
            throw HandshakeError.malformed("bad ephemeral key")
        }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peerEphemeral)

        keys = SessionKeys.derive(sharedSecret: shared,
                                  clientRandom: clientRandom,
                                  serverRandom: hello.rnd)
        peerIdentityKey = hello.idk
        peerDevice = hello.dev

        var clientMessage = Data("iCam/v1/client".utf8)
        clientMessage.append(transcript)
        return try HandshakeCodec.encode(ClientAuth(sig: try identity.sign(clientMessage)))
    }

    /// Step 4 — the server tells us whether it already trusts this iPhone.
    func handle(ready data: Data) throws -> Bool {
        let ready = try HandshakeCodec.decode(HandshakeReady.self, from: data)
        guard ready.t == "ready" else {
            throw HandshakeError.wrongMessage(expected: "ready", got: ready.t)
        }
        return ready.trusted
    }
}
