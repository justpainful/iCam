import Foundation
import Network
import Combine

/// The connection to one computer, with meaning attached.
///
/// Owns the handshake, the record layer, framing, the control loop, reconnect,
/// and the media send path. Everything above it works in iCam vocabulary;
/// everything below it works in bytes.
@MainActor
final class PeerLink: ObservableObject {

    enum Status: Equatable {
        case disconnected
        case connecting
        /// Waiting for the user to confirm the pairing digits on both devices.
        case pairing(digits: String, peerName: String)
        case connected(peerName: String)
        case failed(String)

        var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var link: Transport.Link = .unknown
    @Published private(set) var peerName: String?
    @Published private(set) var peerFingerprint: String?
    @Published private(set) var diagnostics = Diagnostics()

    struct Diagnostics: Equatable, Sendable {
        var latencyUs: UInt64 = 0
        var videoBitrate: Int = 0
        var droppedFrames: UInt64 = 0
        var bytesSent: UInt64 = 0
        var bytesReceived: UInt64 = 0
        var pendingBytes: Int = 0
        var isSynchronised = false
    }

    // MARK: Callbacks into the app

    /// A control message the app has to act on. Delivered on the main actor.
    var onControl: ((ControlEnvelope) -> Void)?
    /// Fired once per connection, after trust is established.
    var onReady: (() -> Void)?
    /// Fired when the link drops while something was relying on it.
    var onLost: ((String?) -> Void)?

    // MARK: Internals

    private let identity: DeviceIdentity
    private let deviceInfo: DeviceInfo
    private let trustStore: TrustStore

    private var transport = Transport()
    private var handshake: InitiatorHandshake?
    private var channel: SecureChannel?
    private var parser = FrameParser()
    private let timeSync = TimeSync()

    private var nextMessageId: UInt32 = 1
    private var pendingPings: [UInt32: UInt64] = [:]
    private var pingTimer: Timer?
    private var diagnosticsTimer: Timer?
    private var sessionStartedAt = Date()

    /// Endpoint to return to on reconnect.
    private var lastEndpoint: NWEndpoint?
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var wantsConnection = false

    /// Set while the handshake says the peer does not trust us yet.
    private var pendingTrustKey: Data?
    private var pendingTrustName: String?

    init(identity: DeviceIdentity, deviceInfo: DeviceInfo, trustStore: TrustStore) {
        self.identity = identity
        self.deviceInfo = deviceInfo
        self.trustStore = trustStore
    }

    // MARK: - Connecting

    func connect(to peer: DiscoveredPeer) {
        lastEndpoint = peer.endpoint
        wantsConnection = true
        reconnectAttempt = 0
        openConnection()
    }

    func connect(host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        lastEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        wantsConnection = true
        reconnectAttempt = 0
        openConnection()
    }

    func disconnect() {
        wantsConnection = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        teardown()
        status = .disconnected
    }

    /// The user confirmed the pairing digits.
    func confirmPairing() {
        guard case .pairing = status, let key = pendingTrustKey else { return }
        trustStore.trust(publicKey: key,
                         name: pendingTrustName ?? String(localized: "PC"),
                         host: nil, port: nil)
        pendingTrustKey = nil
        becomeReady(peerName: pendingTrustName ?? String(localized: "PC"))
    }

    func rejectPairing() {
        pendingTrustKey = nil
        pendingTrustName = nil
        disconnect()
    }

    // MARK: - Sending

    func send<T: Encodable>(_ type: String, payload: T, replyTo: UInt32? = nil) {
        guard let data = try? ControlCodec.encode(type: type, id: nextId(),
                                                  replyTo: replyTo, payload: payload) else { return }
        sendFrame(channel: .control, payload: data, isMedia: false)
    }

    func sendEmpty(_ type: String, replyTo: UInt32? = nil) {
        guard let data = try? ControlCodec.encodeEmpty(type: type, id: nextId(),
                                                       replyTo: replyTo) else { return }
        sendFrame(channel: .control, payload: data, isMedia: false)
    }

    /// Sends one encoded video access unit, plus its parameter sets when the
    /// encoder produced new ones.
    /// Set after the transport refuses a frame. Until a keyframe goes through,
    /// sending anything else is worse than sending nothing: every inter frame
    /// references the one the transport dropped, and the PC can only render
    /// them as smear.
    private var awaitingKeyframeAfterDrop = false
    /// Fired when the encoder should produce a keyframe soon — the transport
    /// dropped, and the wait for the next scheduled one is a frozen preview.
    var onNeedsKeyframe: (() -> Void)?

    /// Sealed-frame overhead: 8-byte framing header plus the AEAD tag.
    private static let sealOverhead = 8 + 16

    func sendVideo(_ frame: StreamEncoder.EncodedFrame, sequence: UInt32) {
        if awaitingKeyframeAfterDrop && !frame.isKeyframe {
            transport.noteSkippedMedia()
            return
        }

        // The whole decision happens *before anything is sealed*: the cipher's
        // frame counter is implicit and strict on both ends, so a frame sealed
        // and then dropped would desynchronise the channel permanently. The
        // parameter sets and the frame travel or stay together for the same
        // reason a keyframe without parameter sets is useless.
        let cost = frame.data.count + (frame.parameterSets?.count ?? 0)
                 + 2 * (VideoFrameHeader.size + Self.sealOverhead)
        guard transport.canAcceptMedia(byteCount: cost) else {
            transport.noteSkippedMedia()
            awaitingKeyframeAfterDrop = true
            onNeedsKeyframe?()
            return
        }

        if let parameterSets = frame.parameterSets {
            let header = VideoFrameHeader(codec: currentVideoCodec,
                                          isKeyframe: true,
                                          isParameterSets: true,
                                          sequence: sequence,
                                          ptsUs: frame.ptsUs,
                                          dtsUs: frame.dtsUs)
            var payload = header.encoded
            payload.append(parameterSets)
            sendFrame(channel: .video, payload: payload, isMedia: true)
        }

        let header = VideoFrameHeader(codec: currentVideoCodec,
                                      isKeyframe: frame.isKeyframe,
                                      isParameterSets: false,
                                      sequence: sequence,
                                      ptsUs: frame.ptsUs,
                                      dtsUs: frame.dtsUs)
        var payload = header.encoded
        payload.append(frame.data)
        sendFrame(channel: .video, payload: payload, isMedia: true)
        awaitingKeyframeAfterDrop = false
    }

    func sendAudio(_ packet: AudioStreamer.Packet) {
        // Checked before sealing, for the same counter reason as video.
        guard transport.canAcceptMedia(byteCount: packet.data.count
                                       + AudioFrameHeader.size + Self.sealOverhead) else {
            transport.noteSkippedMedia()
            return
        }
        let header = AudioFrameHeader(codec: .pcmS16LE,
                                      channels: packet.channels,
                                      isParameterSets: false,
                                      sampleRate: packet.sampleRate,
                                      sequence: packet.sequence,
                                      ptsUs: packet.ptsUs)
        var payload = header.encoded
        payload.append(packet.data)
        sendFrame(channel: .audio, payload: payload, isMedia: true)
    }

    var currentVideoCodec: VideoCodec = .h264

    var currentRttUs: UInt64 { timeSync.rttUs }
    var currentPendingBytes: Int { transport.pendingBytes }

    /// The encoder's current bitrate, which sets how much video may wait in
    /// the send queue — a time budget, priced in bytes.
    func setPendingBudget(bitsPerSecond: Int) {
        transport.setPendingBudget(bitsPerSecond: bitsPerSecond)
    }
    var currentTransportDrops: UInt64 { transport.droppedFrames }

    // MARK: - Connection lifecycle

    /// A connection that arrived *at* the phone — the USB tunnel, where the PC
    /// dials through Apple's cable service. The phone still plays the protocol
    /// initiator: who dialled and who says hello first are independent, and
    /// keeping one role keeps one code path for handshake and trust.
    func adoptIncoming(_ connection: NWConnection) {
        lastEndpoint = nil        // reconnection is the PC's job over USB
        wantsConnection = true
        reconnectAttempt = 0
        activateTransport { $0.adopt(connection) }
    }

    private func openConnection() {
        guard let endpoint = lastEndpoint else { return }
        activateTransport { $0.connect(to: endpoint) }
    }

    private func activateTransport(_ begin: (Transport) -> Void) {
        teardown()
        status = .connecting

        let newTransport = Transport()
        transport = newTransport
        parser.reset()
        timeSync.reset()

        newTransport.onState = { [weak self] state in
            Task { @MainActor in self?.handle(transportState: state) }
        }
        newTransport.onBytes = { [weak self] data in
            Task { @MainActor in self?.handle(bytes: data) }
        }
        begin(newTransport)
    }

    private func handle(transportState state: Transport.State) {
        switch state {
        case .connected:
            link = transport.link
            beginHandshake()
        case .failed(let message):
            fail(message)
        case .cancelled:
            if wantsConnection { fail(nil) } else { status = .disconnected }
        default:
            break
        }
    }

    private func beginHandshake() {
        let session = InitiatorHandshake(identity: identity, deviceInfo: deviceInfo)
        handshake = session
        do {
            let hello = try session.clientHello()
            transport.send(Frame(channel: .handshake, payload: hello).encoded)
        } catch {
            fail(String(localized: "iCam could not start a secure connection."))
        }
    }

    private func handle(bytes: Data) {
        parser.append(bytes)
        while true {
            do {
                guard let (frame, header) = try parser.next() else { return }
                route(frame: frame, header: header)
            } catch FrameError.unknownChannel(let id) {
                Log.net.notice("Ignoring a frame on unknown channel \(id, privacy: .public)")
                continue
            } catch {
                fail(String(localized: "Your PC sent something iCam could not read."))
                return
            }
        }
    }

    private func route(frame: Frame, header: Data) {
        if frame.channel == .handshake {
            handleHandshake(frame.payload)
            return
        }
        guard let channel else { return }
        guard let plaintext = try? channel.open(header: header, payload: frame.payload) else {
            // A frame that fails authentication means the stream is no longer
            // trustworthy. There is no safe way to continue.
            fail(String(localized: "The secure connection to your PC failed."))
            return
        }
        switch frame.channel {
        case .control:
            guard let envelope = try? ControlCodec.envelope(from: plaintext) else { return }
            handleControl(envelope)
        case .bulk, .video, .audio, .handshake:
            // The phone is the sender for media in Phase 1. Bulk transfer
            // arrives here when the PC pushes a file back.
            break
        }
    }

    private func handleHandshake(_ payload: Data) {
        guard let session = handshake else { return }
        switch HandshakeCodec.messageType(of: payload) {
        case "hello_ack":
            do {
                let auth = try session.handle(serverHello: payload)
                transport.send(Frame(channel: .handshake, payload: auth).encoded)
            } catch {
                fail(Self.describeHandshake(error))
            }
        case "ready":
            do {
                let trusted = try session.handle(ready: payload)
                finishHandshake(trusted: trusted)
            } catch {
                fail(Self.describeHandshake(error))
            }
        default:
            fail(String(localized: "Your PC did not complete the connection."))
        }
    }

    private func finishHandshake(trusted: Bool) {
        guard let session = handshake, let keys = session.keys else {
            fail(String(localized: "iCam could not establish a secure connection."))
            return
        }

        channel = SecureChannel(keys: keys, role: .initiator)
        let name = session.peerDevice?.name ?? String(localized: "PC")
        peerName = name
        peerFingerprint = DeviceIdentity.fingerprint(publicKey: session.peerIdentityKey)

        let alreadyTrusted = trustStore.isTrusted(publicKey: session.peerIdentityKey)

        if trusted && alreadyTrusted {
            trustStore.noteSeen(fingerprint: peerFingerprint ?? "", host: nil, port: nil)
            becomeReady(peerName: name)
        } else {
            // First pairing: both sides show the same six digits, derived from
            // the handshake transcript. Matching digits prove there is nobody
            // in the middle.
            pendingTrustKey = session.peerIdentityKey
            pendingTrustName = name
            status = .pairing(digits: keys.pairingDigits, peerName: name)
        }
    }

    private func becomeReady(peerName name: String) {
        status = .connected(peerName: name)
        reconnectAttempt = 0
        sessionStartedAt = Date()
        startTimers()
        send(ControlType.deviceInfo, payload: deviceInfo)
        onReady?()
        Log.net.notice("Connected over \(self.link.rawValue, privacy: .public)")
    }

    private func fail(_ message: String?) {
        teardown()
        if let message { status = .failed(message) } else { status = .disconnected }
        onLost?(message)
        scheduleReconnectIfWanted()
    }

    private func teardown() {
        stopTimers()
        transport.cancel()
        transport.onState = nil
        transport.onBytes = nil
        channel = nil
        handshake = nil
        parser.reset()
        pendingPings.removeAll()
    }

    /// Exponential backoff with a ceiling and a little jitter.
    ///
    /// Retrying every second forever would keep the radio awake and drain the
    /// battery of a phone sitting on a desk next to a PC that is switched off.
    private func scheduleReconnectIfWanted() {
        guard wantsConnection, lastEndpoint != nil else { return }
        reconnectWorkItem?.cancel()

        reconnectAttempt = min(reconnectAttempt + 1, 8)
        let base = min(pow(1.8, Double(reconnectAttempt)), 60)
        let jitter = Double.random(in: 0 ... 0.4) * base
        let delay = min(base + jitter, 60)

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.wantsConnection else { return }
                self.openConnection()
            }
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        Log.net.notice("Reconnecting in \(Int(delay), privacy: .public)s")
    }

    // MARK: - Control

    private func handleControl(_ envelope: ControlEnvelope) {
        switch envelope.t {
        case ControlType.timePong:
            guard let payload = try? ControlCodec.payload(TimePongPayload.self, from: envelope),
                  let replyTo = envelope.r, pendingPings.removeValue(forKey: replyTo) != nil else {
                return
            }
            timeSync.record(t1: payload.t1, t2: payload.t2, t3: payload.t3,
                            t4: MonotonicClock.nowUs())
        case ControlType.timePing:
            // The PC can measure in the other direction too.
            guard let payload = try? ControlCodec.payload(TimePingPayload.self, from: envelope) else { return }
            let received = MonotonicClock.nowUs()
            send(ControlType.timePong,
                 payload: TimePongPayload(t1: payload.t1, t2: received, t3: MonotonicClock.nowUs()),
                 replyTo: envelope.id)
        default:
            onControl?(envelope)
        }
    }

    private func sendFrame(channel: Channel, payload: Data, isMedia: Bool) {
        guard let secure = self.channel, status.isConnected else { return }
        guard let sealed = try? secure.seal(channel: channel, plaintext: payload) else { return }
        // By this point the frame is sealed and the counter has moved, so it
        // must go out — the admission decision already happened, before the
        // seal, in the callers that carry media.
        if isMedia {
            transport.sendMedia(sealed)
        } else {
            transport.send(sealed)
        }
    }

    private func nextId() -> UInt32 {
        defer { nextMessageId = nextMessageId == UInt32.max ? 1 : nextMessageId + 1 }
        return nextMessageId
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()
        sendPing()
        reschedulePing()

        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDiagnostics() }
        }
    }

    private func reschedulePing() {
        pingTimer?.invalidate()
        let interval = TimeSync.interval(sinceStart: Date().timeIntervalSince(sessionStartedAt))
        pingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.status.isConnected else { return }
                self.sendPing()
                self.reschedulePing()
            }
        }
    }

    private func stopTimers() {
        pingTimer?.invalidate(); pingTimer = nil
        diagnosticsTimer?.invalidate(); diagnosticsTimer = nil
    }

    private func sendPing() {
        let id = nextId()
        let t1 = MonotonicClock.nowUs()
        pendingPings[id] = t1
        guard let data = try? ControlCodec.encode(type: ControlType.timePing, id: id,
                                                  payload: TimePingPayload(t1: t1)) else { return }
        sendFrame(channel: .control, payload: data, isMedia: false)

        // A ping that never comes back is the earliest sign the link is gone,
        // well before TCP gives up.
        if pendingPings.count > 6 {
            fail(String(localized: "iCam lost contact with your PC."))
        }
    }

    private func refreshDiagnostics() {
        diagnostics = Diagnostics(latencyUs: timeSync.rttUs / 2,
                                  videoBitrate: diagnostics.videoBitrate,
                                  droppedFrames: transport.droppedFrames,
                                  bytesSent: transport.bytesSent,
                                  bytesReceived: transport.bytesReceived,
                                  pendingBytes: transport.pendingBytes,
                                  isSynchronised: timeSync.isSynchronised)
    }

    func noteEncoderBitrate(_ bitrate: Int) {
        diagnostics.videoBitrate = bitrate
    }

    private static func describeHandshake(_ error: Error) -> String {
        switch error {
        case HandshakeError.versionMismatch:
            return String(localized: "iCam on your PC is a different version. Update both to continue.")
        case HandshakeError.badSignature, HandshakeError.untrusted:
            return String(localized: "iCam could not verify your PC. Pair the devices again.")
        default:
            return String(localized: "iCam could not connect to your PC.")
        }
    }
}
