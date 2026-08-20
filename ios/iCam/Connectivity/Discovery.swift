import Foundation
import Network
import Combine

/// A computer iCam can see on the local network.
struct DiscoveredPeer: Identifiable, Equatable, Sendable {
    /// Bonjour instance name — stable for the lifetime of the advertisement.
    var id: String
    /// The name a person would recognise: `RAEID-PC`.
    var name: String
    /// Identity fingerprint from the TXT record, when the advertiser published
    /// one. Lets iCam recognise a trusted computer before connecting to it.
    var fingerprint: String?
    var endpoint: NWEndpoint
    var protocolVersion: Int

    static func == (a: DiscoveredPeer, b: DiscoveredPeer) -> Bool {
        a.id == b.id && a.name == b.name && a.fingerprint == b.fingerprint
    }
}

/// Browses for iCam computers on the local network.
///
/// Discovery is passive and cheap: the browser sleeps until something changes.
/// It is stopped whenever the app is not looking for a device, because an idle
/// Bonjour browser still keeps the radio awake.
@MainActor
final class Discovery: ObservableObject {

    @Published private(set) var peers: [DiscoveredPeer] = []
    @Published private(set) var isBrowsing = false
    /// Set when the local network permission has been refused, so the interface
    /// can explain the situation instead of showing an empty list forever.
    @Published private(set) var isBlocked = false

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: Wire.bonjourType,
                                                                   domain: nil)
        let newBrowser = NWBrowser(for: descriptor, using: parameters)

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isBrowsing = true
                    self.isBlocked = false
                case .waiting(let error), .failed(let error):
                    Log.net.error("Discovery problem: \(String(describing: error))")
                    self.isBrowsing = false
                    // `-65555` and friends surface as `.waiting` when the local
                    // network permission has not been granted.
                    self.isBlocked = true
                case .cancelled:
                    self.isBrowsing = false
                default:
                    break
                }
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(from: results) }
        }

        browser = newBrowser
        newBrowser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        peers.removeAll()
    }

    private func update(from results: Set<NWBrowser.Result>) {
        var found: [DiscoveredPeer] = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }

            var displayName = name
            var fingerprint: String?
            var version = Wire.protocolVersion

            if case let .bonjour(record) = result.metadata {
                if let value = record["name"], !value.isEmpty { displayName = value }
                if let value = record["id"], !value.isEmpty { fingerprint = value }
                if let value = record["v"], let parsed = Int(value) { version = parsed }
            }

            found.append(DiscoveredPeer(id: name,
                                        name: displayName,
                                        fingerprint: fingerprint,
                                        endpoint: result.endpoint,
                                        protocolVersion: version))
        }
        peers = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
