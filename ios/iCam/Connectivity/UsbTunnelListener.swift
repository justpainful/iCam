import Foundation
import Network

/// The phone's half of Direct USB.
///
/// Over the cable the direction inverts: Apple's device service only tunnels
/// *into* the phone, so the PC dials and this listener answers. What it hands
/// over is an ordinary `NWConnection` that `PeerLink` adopts and treats
/// exactly like one the phone dialled — same handshake, same trust, same
/// encryption. A cable is convenient, not trusted.
///
/// The port is fixed because the PC has no way to discover a dynamic one
/// through the tunnel: 48214, one above the Wi-Fi default, documented in
/// `docs/PROTOCOL.md`.
final class UsbTunnelListener {

    static let port: UInt16 = 48214

    /// A new tunnel. Newest wins — the PC only redials after losing the
    /// previous session, so an arriving connection is always the live one.
    var onConnection: ((NWConnection) -> Void)?

    private var listener: NWListener?

    func start() {
        guard listener == nil else { return }

        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        do {
            let listener = try NWListener(using: parameters,
                                          on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] connection in
                Log.net.notice("A computer reached this iPhone over USB")
                self?.onConnection?(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    Log.net.error("The USB listener failed: \(String(describing: error), privacy: .public)")
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            // Port taken — almost certainly a second copy of iCam. The Wi-Fi
            // path still works; USB quietly does not.
            Log.net.error("Could not listen for USB: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
