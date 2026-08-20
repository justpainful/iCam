import Foundation
import Network

/// A byte pipe to one computer.
///
/// Deliberately dumb: it knows about TCP, back pressure and disconnection, and
/// nothing about iCam's protocol. `PeerLink` layers meaning on top.
final class Transport {

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
        case cancelled
    }

    enum Link: String, Sendable {
        case wifi, wired, unknown

        var displayName: String {
            switch self {
            case .wifi:    return String(localized: "Wi-Fi")
            case .wired:   return String(localized: "USB")
            case .unknown: return String(localized: "Network")
            }
        }
    }

    /// Called on `queue`.
    var onState: ((State) -> Void)?
    var onBytes: ((Data) -> Void)?

    let queue = DispatchQueue(label: "com.icam.net", qos: .utility)

    private var connection: NWConnection?
    private(set) var state: State = .idle
    private(set) var link: Link = .unknown

    /// Bytes handed to the stack that have not been sent yet. The adaptive
    /// bitrate controller reads this: it is the earliest honest signal that the
    /// link cannot keep up.
    private(set) var pendingBytes = 0
    private(set) var bytesSent: UInt64 = 0
    private(set) var bytesReceived: UInt64 = 0
    /// Media frames dropped because the queue was already too deep.
    private(set) var droppedFrames: UInt64 = 0

    /// Above this, new *media* frames are dropped rather than queued. Control
    /// frames are always sent: they are tiny, and losing them breaks the session
    /// far more visibly than losing a video frame.
    ///
    /// This number is denominated in bytes but *experienced in seconds*: on a
    /// link delivering 800 kbit/s, a fixed 1.5 MB cap was fifteen to twenty
    /// seconds of video queued ahead of live — all faithfully delivered by
    /// TCP, all latency. The budget is therefore set by the encoder through
    /// `setPendingBudget` as a fraction of a second at the *current* bitrate,
    /// and this value is only the floor it can never go below.
    private var maxPendingBytes = 300_000

    /// Called by whoever knows the bitrate. Roughly a third of a second of
    /// video at the given rate, never less than one keyframe's worth.
    func setPendingBudget(bitsPerSecond: Int) {
        maxPendingBytes = max(150_000, bitsPerSecond / 8 / 3)
    }

    // MARK: - Lifecycle

    func connect(to endpoint: NWEndpoint) {
        cancel()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        // Nagle would batch small control frames into the video stream's
        // rhythm and add latency for no benefit on a local link.
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 8
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
            tcp.keepaliveCount = 3
            tcp.keepaliveInterval = 3
        }
        start(NWConnection(to: endpoint, using: parameters))
    }

    func connect(host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            update(.failed(String(localized: "That port number is not valid.")))
            return
        }
        connect(to: NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort))
    }

    /// Takes over a connection that arrived at this device — the USB tunnel.
    /// From here on it is indistinguishable from one this side dialled.
    func adopt(_ newConnection: NWConnection) {
        cancel()
        start(newConnection)
    }

    func cancel() {
        connection?.cancel()
        connection = nil
        pendingBytes = 0
        if state != .idle { update(.cancelled) }
    }

    // MARK: - Sending

    /// Sends bytes that must arrive: handshake and control.
    func send(_ data: Data) {
        guard let connection else { return }
        pendingBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingBytes -= data.count
            self.bytesSent &+= UInt64(data.count)
            if let error {
                self.update(.failed(Self.describe(error)))
            }
        })
    }

    /// Whether a media frame of this size may be sent right now.
    ///
    /// **This must be asked before the frame is sealed.** The cipher's frame
    /// counter is implicit and strict on both ends — sealing a frame and then
    /// not sending it desynchronises the channel permanently, and every frame
    /// after it fails authentication. The drop decision therefore lives here,
    /// ahead of the seal, and `sendMedia` itself never refuses.
    func canAcceptMedia(byteCount: Int) -> Bool {
        connection != nil && pendingBytes + byteCount <= maxPendingBytes
    }

    /// Records a frame the caller chose not to seal. Bookkeeping only.
    func noteSkippedMedia() {
        droppedFrames &+= 1
    }

    /// Sends bytes that were cleared by `canAcceptMedia`. Unconditional: by the
    /// time a frame reaches here it is sealed, and a sealed frame must go out.
    func sendMedia(_ data: Data) {
        guard let connection else { return }
        pendingBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingBytes -= data.count
            self.bytesSent &+= UInt64(data.count)
            if let error {
                self.update(.failed(Self.describe(error)))
            }
        })
    }

    // MARK: - Internals

    private func start(_ newConnection: NWConnection) {
        connection = newConnection
        update(.connecting)

        newConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.link = Self.classify(newConnection)
                self.update(.connected)
                self.receiveLoop()
            case .failed(let error):
                self.update(.failed(Self.describe(error)))
            case .waiting(let error):
                Log.net.notice("Waiting for the network: \(String(describing: error))")
            case .cancelled:
                self.update(.cancelled)
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.bytesReceived &+= UInt64(data.count)
                self.onBytes?(data)
            }
            if let error {
                self.update(.failed(Self.describe(error)))
                return
            }
            if isComplete {
                self.update(.cancelled)
                return
            }
            self.receiveLoop()
        }
    }

    private func update(_ newState: State) {
        guard state != newState else { return }
        state = newState
        onState?(newState)
    }

    private static func classify(_ connection: NWConnection) -> Link {
        guard let path = connection.currentPath else { return .unknown }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        if path.usesInterfaceType(.wifi) { return .wifi }
        return .unknown
    }

    /// Network errors are technical. This turns the ones a user can actually do
    /// something about into a sentence, and leaves the rest generic.
    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(.ECONNREFUSED):
            return String(localized: "Your PC refused the connection. Make sure iCam is open on it.")
        case .posix(.ETIMEDOUT), .posix(.EHOSTUNREACH), .posix(.ENETUNREACH):
            return String(localized: "iCam could not reach your PC. Check that both devices are on the same network.")
        case .posix(.ECONNRESET), .posix(.ENOTCONN), .posix(.EPIPE):
            return String(localized: "The connection to your PC ended.")
        default:
            return String(localized: "The connection to your PC ended.")
        }
    }
}
