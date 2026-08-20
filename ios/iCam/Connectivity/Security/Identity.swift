import Foundation
import CryptoKit
import Security

/// This device's long-lived cryptographic identity.
///
/// Trust is bound to this key, never to an IP address, a hostname, or a shared
/// password. The private key lives in the keychain with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: available to a
/// background streaming session, never synced, never exported.
struct DeviceIdentity: Sendable {
    let privateKey: P256.Signing.PrivateKey

    var publicKeyData: Data { privateKey.publicKey.x963Representation }

    /// First 16 bytes of SHA-256 over the public key, lowercase hex. Stable,
    /// short enough to show in a diagnostics panel.
    var fingerprint: String { DeviceIdentity.fingerprint(publicKey: publicKeyData) }

    static func fingerprint(publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func sign(_ message: Data) throws -> Data {
        try privateKey.signature(for: message).derRepresentation
    }

    static func verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            return false
        }
        return key.isValidSignature(sig, for: message)
    }
}

enum IdentityStore {
    private static let service = "com.icam.identity"
    private static let account = "device"

    /// Loads the identity, creating it on first launch. Throws only if the
    /// keychain itself is unusable, which is not something to paper over.
    static func loadOrCreate() throws -> DeviceIdentity {
        if let existing = try load() { return existing }
        let key = P256.Signing.PrivateKey()
        try save(key)
        Log.security.notice("Created device identity")
        return DeviceIdentity(privateKey: key)
    }

    static func load() throws -> DeviceIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return DeviceIdentity(privateKey: try P256.Signing.PrivateKey(rawRepresentation: data))
        case errSecItemNotFound:
            return nil
        default:
            throw ICamError.internalError("keychain read failed: \(status)")
        }
    }

    private static func save(_ key: P256.Signing.PrivateKey) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key.rawRepresentation
        ]
        SecItemDelete(attributes as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ICamError.internalError("keychain write failed: \(status)")
        }
    }

    /// Only used by `Reset iCam Identity` in Advanced settings. Every trusted
    /// computer will need to pair again, which is exactly the intent.
    static func destroy() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
