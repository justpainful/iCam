import Foundation
import SwiftUI
import AVFoundation
import Combine
import UIKit

/// The camera screen's state and actions.
///
/// It composes the engines; it does not implement them. Anything that touches
/// pixels, sockets, or capture devices lives in its own type, and this class
/// exists to turn user intent into calls on those types and their state into
/// something SwiftUI can render.
@MainActor
final class CameraViewModel: ObservableObject {

    // MARK: Published state

    @Published private(set) var cameraState = CameraState()
    @Published private(set) var capabilities = CameraCapabilities()
    @Published private(set) var lenses: [LensOption] = []
    @Published private(set) var isSessionRunning = false
    @Published private(set) var recording = RecordingEngine.Status()
    @Published private(set) var isStreaming = false
    @Published private(set) var streamProfile = StreamProfile.webcam1080p30

    @Published var error: ICamError?
    @Published var interruptionMessage: String?
    /// Where the last focus tap landed, in preview coordinates.
    @Published var focusIndicator: FocusIndicatorState?
    /// A brief white flash confirming a photo was actually taken.
    @Published var shutterFlash = false
    /// Hides the controls after a period of no interaction, so the preview is
    /// as clean as possible while shooting.
    @Published private(set) var controlsVisible = true
    @Published var isScreenOff = false

    struct FocusIndicatorState: Equatable {
        var point: CGPoint
        var id = UUID()
    }

    // MARK: Collaborators

    let engine = CameraEngine()
    let recorder = RecordingEngine()
    let stream = StreamSession()
    let audio = AudioStreamer()
    private(set) var photos: PhotoEngine?

    private let settings: AppSettings
    private let thermal: ThermalManager
    private let storage: StorageMonitor
    private weak var link: PeerLink?

    private var cancellables = Set<AnyCancellable>()
    private var idleTimer: Timer?
    private var adaptiveTimer: Timer?
    private var telemetryTimer: Timer?
    private var recordingTimer: Timer?
    private var lastTelemetry: TelemetryPayload?
    private var nextPhotoRequestId: UInt32 = 1

    init(settings: AppSettings, thermal: ThermalManager, storage: StorageMonitor) {
        self.settings = settings
        self.thermal = thermal
        self.storage = storage
        wire()
    }

    // MARK: - Lifecycle

    func attach(link: PeerLink) {
        link.onNeedsKeyframe = { [weak self] in
            Task { @MainActor in self?.stream.requestKeyframe() }
        }
        self.link = link
        link.onControl = { [weak self] envelope in self?.handle(control: envelope) }
        link.onReady = { [weak self] in self?.peerBecameReady() }
        link.onLost = { [weak self] _ in self?.peerWasLost() }
    }

    func onAppear() {
        Haptics.prepare()
        engine.prepare { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.engine.enableAudio(self.settings.audioEnabled)
                self.engine.start()
                self.photos = PhotoEngine(output: self.engine.photoOutput)
                self.wirePhotos()
            }
        }
        engine.addVideoSink(recorder)
        engine.addAudioSink(recorder)
        engine.addVideoSink(stream)
        engine.addAudioSink(audio)
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
        scheduleIdleHide()
        // Timers do not fire in the background, so a recording that survived a
        // trip there comes back with its ticker stopped. Restarted here rather
        // than trusted to still exist.
        syncRecordingTicker()
    }

    func onDisappear() {
        idleTimer?.invalidate()
        adaptiveTimer?.invalidate()
        telemetryTimer?.invalidate()
        recordingTimer?.invalidate()
        recordingTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func applicationDidEnterBackground() {
        // Recording and streaming carry on where iOS allows it. What stops is
        // everything that only exists to draw on a screen nobody can see.
        setControls(visible: false)
    }

    // MARK: - Actions

    func capturePhoto() {
        guard let photos else { return }
        let requestId = nextPhotoRequestId
        nextPhotoRequestId &+= 1
        photos.capture(requestId: requestId,
                       state: cameraState,
                       saveToLibrary: settings.savePhotosToLibrary,
                       flashMode: cameraState.torch == .on ? .on : .off,
                       orientationAngle: currentRotationAngle)
        showControls()
    }

    func toggleRecording() {
        if recording.isRecording {
            recorder.stop()
            Haptics.record(starting: false)
            link?.send(ControlType.recordStop,
                       payload: RecordStopPayload(sessionId: recording.sessionId ?? ""))
        } else {
            do {
                try recorder.start(state: cameraState,
                                   target: settings.recordingTarget,
                                   audioEnabled: settings.audioEnabled,
                                   orientationTransform: .identity,
                                   storage: StorageMonitorSnapshot(freeBytes: storage.freeBytes,
                                                                   canRecord: storage.canRecord))
                Haptics.record(starting: true)
                if let sessionId = recorder.currentSessionId {
                    link?.send(ControlType.recordStart,
                               payload: RecordStartPayload(target: settings.recordingTarget,
                                                           sessionId: sessionId,
                                                           startedAtUs: MonotonicClock.nowUs()))
                }
            } catch let failure as ICamError {
                error = failure
                Haptics.warning()
            } catch {
                self.error = .recordFailed(detail: String(describing: error))
            }
        }
        showControls()
    }

    func selectLens(_ lens: LensOption) {
        guard lens.id != cameraState.lensId else { return }
        Haptics.select()
        engine.selectLens(lens.id)
        showControls()
    }

    /// Swaps between the front camera and the back camera the user last used.
    func toggleFrontBack() {
        let currentPosition: AVCaptureDevice.Position =
            engine.devices.lens(id: cameraState.lensId)?.position ?? .back
        let target: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
        let candidates = engine.devices.lenses(position: target)
        guard let lens = candidates.first(where: { abs($0.displayZoom - 1.0) < 0.01 })
                ?? candidates.first else { return }
        Haptics.select()
        engine.selectLens(lens.id)
        showControls()
    }

    func setZoom(_ displayZoom: Double) {
        engine.setZoom(displayZoom: displayZoom)
    }

    func focusAndExpose(previewPoint: CGPoint, devicePoint: CGPoint) {
        engine.focusAndExpose(at: devicePoint)
        focusIndicator = FocusIndicatorState(point: previewPoint)
        Haptics.lock()
        showControls()
    }

    func resetFocusAndExposure() {
        engine.resetFocusAndExposure()
        focusIndicator = nil
        Haptics.lock()
    }

    func apply(_ mutation: CameraMutation) {
        engine.apply(mutation, base: cameraState.version)
        showControls()
    }

    func setStreaming(_ enabled: Bool) {
        guard enabled != isStreaming else { return }
        isStreaming = enabled
        if enabled {
            let profile = settings.streamProfile
            stream.start(profile: profile, captureFps: cameraState.fps)
            stream.applyThermalBudget(thermal.budget)
            audio.setEnabled(settings.sendMicrophoneToPC)
            link?.currentVideoCodec = profile.codec
            streamProfile = stream.currentProfile
            startAdaptiveLoop()
        } else {
            stream.stop()
            audio.setEnabled(false)
            adaptiveTimer?.invalidate()
        }
    }

    // MARK: - Controls visibility

    /// The interface fades back to just the preview a few seconds after the
    /// last interaction. Any touch brings it straight back.
    func showControls() {
        if !controlsVisible { controlsVisible = true }
        scheduleIdleHide()
    }

    private func scheduleIdleHide() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.setControls(visible: false) }
        }
    }

    private func setControls(visible: Bool) {
        guard controlsVisible != visible else { return }
        controlsVisible = visible
    }

    var currentRotationAngle: CGFloat {
        switch cameraState.orientation {
        case .auto:
            switch UIDevice.current.orientation {
            case .landscapeLeft:      return 0
            case .landscapeRight:     return 180
            case .portraitUpsideDown: return 270
            default:                  return 90
            }
        case .portrait:       return 90
        case .landscapeLeft:  return 0
        case .landscapeRight: return 180
        }
    }

    // MARK: - Wiring

    private func wire() {
        engine.onStateChange = { [weak self] state in
            guard let self else { return }
            self.cameraState = state
            self.link?.send(ControlType.cameraState, payload: state)
        }
        engine.onCapabilities = { [weak self] caps in
            guard let self else { return }
            self.capabilities = caps
            self.lenses = self.engine.devices.lenses
            self.link?.send(ControlType.capabilities, payload: caps)
        }
        engine.onError = { [weak self] error in
            self?.error = error
            Haptics.warning()
        }
        engine.onRunningChanged = { [weak self] running in self?.isSessionRunning = running }
        engine.onInterruption = { [weak self] interrupted, message in
            self?.interruptionMessage = interrupted ? message : nil
        }
        engine.onSystemPressure = { [weak self] level in
            self?.thermal.update(systemPressure: level)
        }

        recorder.onStatusChange = { [weak self] status in
            self?.recording = status
            self?.syncRecordingTicker()
        }
        recorder.onError = { [weak self] error in
            self?.error = error
            Haptics.warning()
        }

        stream.onEncodedFrame = { [weak self] frame, sequence in
            Task { @MainActor in self?.link?.sendVideo(frame, sequence: sequence) }
        }
        stream.onError = { [weak self] error in
            Task { @MainActor in self?.error = error }
        }
        stream.onProfileChanged = { [weak self] profile in
            Task { @MainActor in
                self?.streamProfile = profile
                self?.link?.send(ControlType.streamStatus,
                                 payload: StreamStatusPayload(active: true, actual: profile,
                                                              reason: nil))
            }
        }

        audio.onPacket = { [weak self] packet in
            Task { @MainActor in self?.link?.sendAudio(packet) }
        }

        // The thermal budget is an input to the stream, not a suggestion.
        thermal.onBudgetChange = { [weak self] budget in
            self?.stream.applyThermalBudget(budget)
        }
        thermal.$mode.sink { [weak self] _ in self?.settings.thermalMode = self?.thermal.mode ?? .smart }
            .store(in: &cancellables)
    }

    private func wirePhotos() {
        photos?.onWillCapture = { [weak self] in
            guard let self else { return }
            Haptics.shutter()
            withAnimation(.easeOut(duration: 0.08)) { self.shutterFlash = true }
            withAnimation(.easeIn(duration: 0.22).delay(0.08)) { self.shutterFlash = false }
        }
        photos?.onResult = { [weak self] result in
            guard let self else { return }
            self.link?.send(ControlType.photoResult,
                            payload: PhotoResultPayload(requestId: result.requestId,
                                                        ok: true,
                                                        assetId: result.fileURL.lastPathComponent,
                                                        transferId: nil,
                                                        error: nil))
        }
        photos?.onError = { [weak self] requestId, error in
            guard let self else { return }
            self.error = error
            self.link?.send(ControlType.photoResult,
                            payload: PhotoResultPayload(requestId: requestId, ok: false,
                                                        assetId: nil, transferId: nil,
                                                        error: ProtocolError(code: error.code,
                                                                             message: error.message,
                                                                             detail: error.detail)))
        }
    }

    // MARK: - Peer

    private func peerBecameReady() {
        Haptics.connection(success: true)
        link?.send(ControlType.capabilities, payload: capabilities)
        link?.send(ControlType.cameraState, payload: cameraState)
        if recording.isRecording {
            recorder.pcConnectionRestored(atUs: MonotonicClock.nowUs())
        }
        stream.requestKeyframe()
        startTelemetryLoop()
    }

    private func peerWasLost() {
        Haptics.connection(success: false)
        telemetryTimer?.invalidate()
        // The local master keeps writing. This is the whole point of Safety
        // Recording, and it costs exactly one line here because the recorder
        // was never coupled to the link in the first place.
        if recording.isRecording {
            recorder.pcConnectionLost(atUs: MonotonicClock.nowUs())
        }
        setStreaming(false)
    }

    private func handle(control envelope: ControlEnvelope) {
        switch envelope.t {
        case ControlType.cameraCommand:
            guard let payload = try? ControlCodec.payload(CameraCommandPayload.self,
                                                          from: envelope) else { return }
            engine.apply(payload.set, base: payload.base) { [weak self] applied in
                Task { @MainActor in
                    self?.link?.send(ControlType.cameraCommandResult,
                                     payload: CameraCommandResult(ok: true,
                                                                  appliedVersion: applied.version,
                                                                  error: nil),
                                     replyTo: envelope.id)
                }
            }

        case ControlType.streamStart:
            guard let payload = try? ControlCodec.payload(StreamStartPayload.self,
                                                          from: envelope) else { return }
            stream.start(profile: payload.profile, captureFps: cameraState.fps)
            link?.currentVideoCodec = payload.profile.codec
            isStreaming = true
            startAdaptiveLoop()

        case ControlType.streamStop:
            setStreaming(false)

        case ControlType.streamConfig:
            guard let payload = try? ControlCodec.payload(StreamStartPayload.self,
                                                          from: envelope) else { return }
            stream.reconfigure(profile: payload.profile)
            link?.currentVideoCodec = payload.profile.codec

        case ControlType.streamKeyframe:
            // The PC's decoder lost its place — usually a network burst it
            // could not swallow. An IDR now costs a bitrate spike; the frozen
            // preview it ends costs the user's trust.
            stream.requestKeyframe()

        case ControlType.photoCapture:
            capturePhoto()

        case ControlType.recordStart:
            if !recording.isRecording { toggleRecording() }

        case ControlType.recordStop:
            if recording.isRecording { toggleRecording() }

        default:
            break
        }
    }

    // MARK: - Loops

    private func startAdaptiveLoop() {
        adaptiveTimer?.invalidate()
        adaptiveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let link = self.link, self.isStreaming else { return }
                self.stream.updateAdaptiveBitrate(rttUs: link.currentRttUs,
                                                  pendingBytes: link.currentPendingBytes,
                                                  transportDrops: link.currentTransportDrops)
                let stats = self.stream.stats
                link.noteEncoderBitrate(stats.bitrate)
                link.setPendingBudget(bitsPerSecond: stats.bitrate)
                self.streamProfile = self.stream.currentProfile
            }
        }
    }

    /// The recording readout has its own pulse, because nothing else has the
    /// right lifetime: the telemetry loop only runs while a PC is connected,
    /// and the writer publishes on events, not on the passage of time. Without
    /// this the elapsed time froze at the value captured when recording
    /// started — 00:00, forever — while the file grew perfectly well.
    ///
    /// The same beat carries `record.state` to the PC, so its readout ticks
    /// too, and keeps ticking even for a recording started on the phone.
    private func syncRecordingTicker() {
        guard recording.isRecording else {
            recordingTimer?.invalidate()
            recordingTimer = nil
            // The final state still goes out, so the PC learns the recording
            // ended even when it was stopped from the phone.
            sendRecordState()
            return
        }
        guard recordingTimer == nil else { return }
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.recording = self.recorder.currentStatus
                self.sendRecordState()
            }
        }
    }

    private func sendRecordState() {
        guard let link, link.status.isConnected else { return }
        link.send(ControlType.recordState,
                  payload: RecordStatePayload(recording: recording.isRecording,
                                              sessionId: recording.sessionId,
                                              target: settings.recordingTarget,
                                              elapsedUs: recording.elapsedUs,
                                              phoneOk: recording.phoneOk,
                                              pcOk: recording.pcOk))
    }

    /// Telemetry is sent at most once a second, and only when something
    /// actually changed — a heartbeat that repeats identical numbers is just
    /// radio time.
    private func startTelemetryLoop() {
        telemetryTimer?.invalidate()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendTelemetryIfChanged() }
        }
    }

    private func sendTelemetryIfChanged() {
        guard let link, link.status.isConnected else { return }
        let stats = stream.stats
        let payload = TelemetryPayload(
            thermal: thermal.level.wireValue,
            pressure: Self.pressureName(thermal.systemPressure),
            battery: Double((UIDevice.current.batteryLevel * 100).rounded()) / 100,
            power: UIDevice.current.batteryState == .unplugged ? "battery" : "usb",
            storageFreeBytes: storage.freeBytes,
            capture: .init(fps: (engine.measuredFps * 10).rounded() / 10,
                           dropped: engine.droppedFrames),
            encoder: .init(fps: (stats.fps * 10).rounded() / 10,
                           bitrate: stats.bitrate / 100_000 * 100_000,
                           latencyUs: stats.latencyUs))

        guard payload != lastTelemetry else { return }
        lastTelemetry = payload
        link.send(ControlType.telemetry, payload: payload)
    }

    private static func pressureName(_ level: AVCaptureDevice.SystemPressureState.Level) -> String {
        switch level {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "serious"
        case .shutdown: return "shutdown"
        default:        return "nominal"
        }
    }
}
