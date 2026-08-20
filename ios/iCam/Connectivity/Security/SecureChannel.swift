import Foundation
import CryptoKit

/// The derived key material for one connection.
struct SessionKeys: Sendable, Equatable {
    var c2sKey: Data
    var s2cKey: Data
    var c2sSalt: Data      // 4 bytes
    var s2cSalt: Data      // 4 bytes
    /// Six digits shown on both devices during first pairing.
    var pairingDigits: String

    static func derive(sharedSecret: SharedSecret, clientRandom: Data, serverRandom: Data) -> SessionKeys {
        // CryptoKit's `SharedSecret` hashes nothing on its own, and .NET's
        // `DeriveRawSecretAgreement` returns the same raw X coordinate — which
        // is why both sides can reach an identical key schedule.
        let raw = sharedSecret.withUnsafeBytes { Data($0) }
        return derive(sharedSecretBytes: raw, clientRandom: clientRandom, serverRandom: serverRandom)
    }

    /// The same schedule, from raw bytes. Separated so the conformance vectors
    /// can pin it down without performing a key agreement.
    static func derive(sharedSecretBytes: Data, clientRandom: Data, serverRandom: Data) -> SessionKeys {
        var salt = Data()
        salt.append(clientRandom)
        salt.append(serverRandom)

        let ikm = SymmetricKey(data: sharedSecretBytes)
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: ikm, salt: salt)

        func expand(_ info: String, _ count: Int) -> Data {
            let key = HKDF<SHA256>.expand(pseudoRandomKey: prk,
                                          info: Data(info.utf8),
                                          outputByteCount: count)
            return key.withUnsafeBytes { Data($0) }
        }

        let sasSeed = expand("iCam/v1 sas", 8)
        let value = sasSeed.readUInt64BE(at: 0) % 1_000_000

        return SessionKeys(c2sKey: expand("iCam/v1 c2s key", 32),
                           s2cKey: expand("iCam/v1 s2c key", 32),
                           c2sSalt: expand("iCam/v1 c2s salt", 4),
                           s2cSalt: expand("iCam/v1 s2c salt", 4),
                           pairingDigits: String(format: "%06d", value))
    }
}

enum SecureChannelError: Error, Equatable {
    case counterOutOfOrder(expected: UInt64, got: UInt64)
    case decryptionFailed
    case notEstablished
}

/// AES-256-GCM record layer — `docs/PROTOCOL.md` section 4.4.
///
/// One instance per direction. The frame counter is shared across all channels
/// in that direction, so a reordered or replayed frame is detected immediately.
final class SecureChannel {
    private let sealKey: SymmetricKey
    private let openKey: SymmetricKey
    private let sealSalt: Data
    private let openSalt: Data

    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    /// `role` decides which derived key seals and which opens.
    init(keys: SessionKeys, role: Role) {
        switch role {
        case .initiator:
            sealKey = SymmetricKey(data: keys.c2sKey)
            openKey = SymmetricKey(data: keys.s2cKey)
            sealSalt = keys.c2sSalt
            openSalt = keys.s2cSalt
        case .responder:
            sealKey = SymmetricKey(data: keys.s2cKey)
            openKey = SymmetricKey(data: keys.c2sKey)
            sealSalt = keys.s2cSalt
            openSalt = keys.c2sSalt
        }
    }

    enum Role: Sendable { case initiator, responder }

    /// 4-byte direction salt followed by the big-endian frame counter.
    /// Throws rather than force-unwrapping: this sits on the media path, and a
    /// crash there would take a live recording with it.
    private static func nonce(salt: Data, counter: UInt64) throws -> AES.GCM.Nonce {
        var raw = salt
        raw.appendUInt64BE(counter)
        do {
            return try AES.GCM.Nonce(data: raw)
        } catch {
            throw SecureChannelError.notEstablished
        }
    }

    /// Seals a payload and returns the complete frame, header included.
    func seal(channel: Channel, flags: FrameFlags = .endOfMessage, plaintext: Data) throws -> Data {
        // The header must be known before sealing because it is the associated
        // data, and its length field already accounts for the 16-byte tag.
        let header = Frame.header(channel: channel, flags: flags,
                                  payloadCount: plaintext.count + 16)
        let box = try AES.GCM.seal(plaintext,
                                   using: sealKey,
                                   nonce: try Self.nonce(salt: sealSalt, counter: sendCounter),
                                   authenticating: header)
        sendCounter &+= 1
        var out = header
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    /// Opens a received frame. `header` is the raw 8 bytes as they arrived.
    func open(header: Data, payload: Data) throws -> Data {
        guard payload.count >= 16 else { throw SecureChannelError.decryptionFailed }
        let ciphertext = payload.prefix(payload.count - 16)
        let tag = payload.suffix(16)
        let box = try AES.GCM.SealedBox(nonce: try Self.nonce(salt: openSalt, counter: receiveCounter),
                                        ciphertext: ciphertext,
                                        tag: tag)
        do {
            let plaintext = try AES.GCM.open(box, using: openKey, authenticating: header)
            receiveCounter &+= 1
            return plaintext
        } catch {
            throw SecureChannelError.decryptionFailed
        }
    }

    var framesSent: UInt64 { sendCounter }
    var framesReceived: UInt64 { receiveCounter }
}
