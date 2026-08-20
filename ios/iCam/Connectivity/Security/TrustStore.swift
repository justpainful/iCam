import Foundation

struct TrustedPeer: Codable, Equatable, Identifiable, Sendable {
    /// Fingerprint of the peer identity key — also the stable identifier.
    var id: String
    var name: String
    var publicKey: Data
    var pairedAt: Date
    var lastSeenAt: Date?
    /// Reconnect without asking, once paired.
    var autoConnect: Bool = true
    /// Last endpoint that worked, so a reconnect can skip discovery.
    var lastHost: String?
    var lastPort: UInt16?
}

/// Persistent record of which computers this iPhone trusts.
///
/// Trust is bound to the peer's public key. An attacker who takes over the IP
/// address, the hostname, or the Bonjour name of a paired PC still fails the
/// handshake, because the signature will not verify.
@MainActor
final class TrustStore: ObservableObject {
    @Published private(set) var peers: [TrustedPeer] = []

    private let url: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iCam", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("trusted-devices.json")
        load()
    }

    func peer(withKey publicKey: Data) -> TrustedPeer? {
        let fingerprint = DeviceIdentity.fingerprint(publicKey: publicKey)
        return peers.first { $0.id == fingerprint }
    }

    func isTrusted(publicKey: Data) -> Bool { peer(withKey: publicKey) != nil }

    func trust(publicKey: Data, name: String, host: String?, port: UInt16?) {
        let fingerprint = DeviceIdentity.fingerprint(publicKey: publicKey)
        if let index = peers.firstIndex(where: { $0.id == fingerprint }) {
            peers[index].name = name
            peers[index].lastSeenAt = Date()
            peers[index].lastHost = host
            peers[index].lastPort = port
        } else {
            peers.append(TrustedPeer(id: fingerprint, name: name, publicKey: publicKey,
                                     pairedAt: Date(), lastSeenAt: Date(),
                                     lastHost: host, lastPort: port))
            Log.security.notice("Trusted a new computer")
        }
        save()
    }

    func noteSeen(fingerprint: String, host: String?, port: UInt16?) {
        guard let index = peers.firstIndex(where: { $0.id == fingerprint }) else { return }
        peers[index].lastSeenAt = Date()
        if let host { peers[index].lastHost = host }
        if let port { peers[index].lastPort = port }
        save()
    }

    func setAutoConnect(_ value: Bool, for fingerprint: String) {
        guard let index = peers.firstIndex(where: { $0.id == fingerprint }) else { return }
        peers[index].autoConnect = value
        save()
    }

    /// `Forget Device`. The link, if live, is closed by whoever observes this.
    func forget(_ fingerprint: String) {
        peers.removeAll { $0.id == fingerprint }
        save()
        Log.security.notice("Forgot a trusted computer")
    }

    func forgetAll() {
        peers.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            peers = try JSONDecoder().decode([TrustedPeer].self, from: data)
        } catch {
            // A corrupt trust file must not brick the app, but it also must not
            // silently become "trust nothing" without a trace in the log.
            Log.security.error("Trust store unreadable, starting empty: \(String(describing: error))")
            peers = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(peers)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            Log.security.error("Could not save trust store: \(String(describing: error))")
        }
    }
}
