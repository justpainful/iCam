import Foundation
import AVFoundation
import CoreMedia

/// Anything that wants camera frames implements this. Recording, streaming and
/// analysis are all just sinks — none of them owns the capture session, and
/// none of them can stall another, because each is called in turn on the video
/// queue and is expected to hand off immediately.
protocol VideoFrameSink: AnyObject {
    /// Called on `CameraEngine.videoQueue`. Do not block. Do not convert the
    /// pixel buffer into an image type.
    func receive(video sampleBuffer: CMSampleBuffer)
}

protocol AudioFrameSink: AnyObject {
    /// Called on `CameraEngine.audioQueue`.
    func receive(audio sampleBuffer: CMSampleBuffer)
}

/// Owns the `AVCaptureSession` and nothing else.
///
/// It does not encode, it does not record, it does not draw. It configures the
/// hardware, hands out frames, and keeps `CameraStateStore` honest about what
/// the hardware actually accepted.
final class CameraEngine: NSObject {

    // MARK: Queues

    /// Session configuration and every `lockForConfiguration`.
    let sessionQueue = DispatchQueue(label: "com.icam.session", qos: .userInitiated)
    /// Video sample delivery. Everything downstream of capture runs here.
    let videoQueue = DispatchQueue(label: "com.icam.video", qos: .userInitiated)
    /// Audio sample delivery, separate so a slow video sink cannot cause an
    /// audio gap.
    let audioQueue = DispatchQueue(label: "com.icam.audio", qos: .userInitiated)

    // MARK: Capture graph

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    let photoOutput = AVCapturePhotoOutput()

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    let devices = CameraDeviceManager()
    let stateStore = CameraStateStore()

    private(set) var capabilities = CameraCapabilities()
    private(set) var activeLens: LensOption?
    private var wideBase: Double = 1.0

    // MARK: Sinks

    private var videoSinks: [VideoFrameSink] = []
    private var audioSinks: [AudioFrameSink] = []

    // MARK: Observation callbacks (main thread)

    var onStateChange: ((CameraState) -> Void)?
    var onCapabilities: ((CameraCapabilities) -> Void)?
    var onError: ((ICamError) -> Void)?
    var onInterruption: ((Bool, String?) -> Void)?
    var onSystemPressure: ((AVCaptureDevice.SystemPressureState.Level) -> Void)?
    var onRunningChanged: ((Bool) -> Void)?

    // MARK: Statistics

    private(set) var capturedFrames: UInt64 = 0
    private(set) var droppedFrames: UInt64 = 0
    private var lastFpsSampleUs: UInt64 = 0
    private var framesSinceFpsSample: UInt64 = 0
    private(set) var measuredFps: Double = 0

    private var systemPressureObservation: NSKeyValueObservation?
    private var isConfigured = false

    override init() {
        super.init()
        stateStore.onChange = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async { self.onStateChange?(state) }
        }
        registerNotifications()
    }

    deinit {
        systemPressureObservation?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Sinks

    func addVideoSink(_ sink: VideoFrameSink) {
        videoQueue.async { [weak self] in
            guard let self, !self.videoSinks.contains(where: { $0 === sink }) else { return }
            self.videoSinks.append(sink)
        }
    }

    func removeVideoSink(_ sink: VideoFrameSink) {
        videoQueue.async { [weak self] in
            self?.videoSinks.removeAll { $0 === sink }
        }
    }

    func addAudioSink(_ sink: AudioFrameSink) {
        audioQueue.async { [weak self] in
            guard let self, !self.audioSinks.contains(where: { $0 === sink }) else { return }
            self.audioSinks.append(sink)
        }
    }

    func removeAudioSink(_ sink: AudioFrameSink) {
        audioQueue.async { [weak self] in
            self?.audioSinks.removeAll { $0 === sink }
        }
    }

    // MARK: - Lifecycle

    /// Builds the capture graph. Safe to call once; later calls are ignored.
    func prepare(completion: (() -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self, !self.isConfigured else { completion?(); return }
            self.devices.refresh()

            guard let lens = self.devices.defaultLens else {
                self.report(.cameraUnavailable())
                completion?()
                return
            }

            self.session.beginConfiguration()
            // `inputPriority` is required for `activeFormat` to stick: presets
            // and explicit formats are mutually exclusive.
            self.session.sessionPreset = .inputPriority

            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }

            // `audioSettings` is macOS-only, so on iOS the output delivers
            // whatever the session negotiated. `AudioStreamer` reads the real
            // format off each buffer instead of assuming one.
            self.audioOutput.setSampleBufferDelegate(self, queue: self.audioQueue)
            if self.session.canAddOutput(self.audioOutput) {
                self.session.addOutput(self.audioOutput)
            }

            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.maxPhotoQualityPrioritization = .quality
            }
            self.session.commitConfiguration()

            self.isConfigured = true
            self.applyLensLocked(lens, initial: true)
            self.rebuildCapabilities()
            completion?()
        }
    }

    /// Adds the microphone input. Deliberately separate from `prepare` so the
    /// microphone permission is only requested when audio is actually wanted.
    func enableAudio(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if enabled {
                guard self.audioInput == nil,
                      let device = AVCaptureDevice.default(for: .audio),
                      let input = try? AVCaptureDeviceInput(device: device) else { return }
                self.session.beginConfiguration()
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.audioInput = input
                }
                self.session.commitConfiguration()
            } else if let input = self.audioInput {
                self.session.beginConfiguration()
                self.session.removeInput(input)
                self.audioInput = nil
                self.session.commitConfiguration()
            }
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
            let running = self.session.isRunning
            DispatchQueue.main.async { self.onRunningChanged?(running) }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.onRunningChanged?(false) }
        }
    }

    // MARK: - Mutations

    /// The one entry point for changing anything about the camera, from either
    /// device. Runs on the session queue, reconciles against real hardware
    /// limits, and publishes the result.
    func apply(_ mutation: CameraMutation, base: UInt64? = nil,
               completion: ((CameraState) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            // A lens change is a graph change, not a property change, so it is
            // handled before the rest of the mutation touches the new device.
            if let lensId = mutation.lensId, lensId != self.stateStore.state.lensId,
               let lens = self.devices.lens(id: lensId) {
                self.applyLensLocked(lens, initial: false)
            }

            let result = self.stateStore.apply(mutation, base: base) { state in
                self.reconcileLocked(&state)
            }
            completion?(result)
        }
    }

    /// Tap to focus and expose at a point in the preview's coordinate space,
    /// already converted by the preview layer into device coordinates.
    func focusAndExpose(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            FocusController.setPointOfInterest(device, devicePoint)
            ExposureController.setPointOfInterest(device, devicePoint)
            self.stateStore.observe { state in
                state.focusMode = .single
                state.focusLocked = false
                state.exposureLocked = false
            }
        }
    }

    /// Puts focus and exposure back to fully automatic.
    func resetFocusAndExposure() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            FocusController.setPointOfInterest(device, CGPoint(x: 0.5, y: 0.5))
            ExposureController.setPointOfInterest(device, CGPoint(x: 0.5, y: 0.5))
            FocusController.setContinuous(device)
            ExposureController.setAuto(device)
            self.stateStore.observe { state in
                state.focusMode = .continuous
                state.exposureMode = .auto
                state.focusLocked = false
                state.exposureLocked = false
            }
        }
    }

    /// Pinch zoom. Applied immediately, without a ramp, because a ramp here
    /// feels like the image lagging behind the fingers.
    func setZoom(displayZoom: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device,
                  let lens = self.activeLens else { return }
            let range = LensController.allowedDisplayRange(lens: lens, device: device,
                                                           wideBase: self.wideBase,
                                                           locked: self.stateStore.state.lensLocked)
            guard let applied = LensController.setZoom(device, displayZoom: displayZoom,
                                                       wideBase: self.wideBase,
                                                       allowedDisplayRange: range) else { return }
            // Zoom crossing a switch-over point changes which physical lens is
            // live. The selector must follow, or it will lie.
            let resolved = LensController.activeLens(for: applied,
                                                     among: self.devices.lenses(position: lens.position))
            self.stateStore.observe { state in
                state.zoom = applied
                if let resolved, !state.lensLocked { state.lensId = resolved.id }
            }
            if let resolved, !self.stateStore.state.lensLocked { self.activeLens = resolved }
        }
    }

    /// Tapping a lens button. Ramped, so an optical change reads as a move.
    func selectLens(_ lensId: String) {
        sessionQueue.async { [weak self] in
            guard let self, let lens = self.devices.lens(id: lensId) else { return }

            if lens.deviceUniqueID != self.videoInput?.device.uniqueID {
                self.applyLensLocked(lens, initial: false)
                self.rebuildCapabilities()
                return
            }

            guard let device = self.videoInput?.device else { return }
            let range = LensController.allowedDisplayRange(lens: lens, device: device,
                                                           wideBase: self.wideBase,
                                                           locked: self.stateStore.state.lensLocked)
            let applied = LensController.rampZoom(device, toDisplayZoom: lens.displayZoom,
                                                  wideBase: self.wideBase,
                                                  allowedDisplayRange: range)
            self.activeLens = lens
            self.stateStore.observe { state in
                state.lensId = lens.id
                if let applied { state.zoom = applied }
            }
        }
    }

    /// Pick White — samples a neutral patch and derives custom white balance.
    func pickWhite(averageColor: (r: Double, g: Double, b: Double)) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            guard let result = WhiteBalanceController.pickWhite(device, averageColor: averageColor) else {
                self.report(ICamError(code: "camera.unsupported",
                                      title: String(localized: "Not available on this lens"),
                                      message: String(localized: "This camera does not support custom white balance.")))
                return
            }
            self.stateStore.observe { state in
                state.whiteBalanceMode = .manual
                state.whiteBalancePreset = .custom
                state.temperature = result.kelvin
                state.tint = result.tint
            }
        }
    }

    // MARK: - Configuration, session queue only

    private func applyLensLocked(_ lens: LensOption, initial: Bool) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))

        guard let device = devices.device(for: lens) else {
            report(.cameraUnavailable())
            return
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let existing = videoInput, existing.device.uniqueID != device.uniqueID {
            session.removeInput(existing)
            videoInput = nil
        }

        if videoInput == nil {
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    report(.cameraBusy(detail: "canAddInput == false"))
                    return
                }
                session.addInput(input)
                videoInput = input
            } catch {
                report(.cameraBusy(detail: String(describing: error)))
                return
            }
        }

        activeLens = lens
        wideBase = LensController.wideBase(for: device)
        observeSystemPressure(on: device)

        var state = stateStore.state
        state.lensId = lens.id
        if initial {
            state.zoom = lens.displayZoom
            // A first run should look like a camera, not like a configuration
            // exercise: the most common webcam format, at the lens the user
            // expects, with everything automatic.
            state.width = 1920
            state.height = 1080
            state.fps = 30
        } else {
            state.zoom = lens.displayZoom
        }
        reconcileLocked(&state)
        stateStore.replace(with: state)
    }

    /// Pushes `state` onto the hardware and edits it in place to reflect what
    /// the hardware actually accepted. This is the only place values are
    /// clamped, so the interface and the PC always see the truth.
    private func reconcileLocked(_ state: inout CameraState) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let device = videoInput?.device, let lens = activeLens else { return }

        // --- Format -----------------------------------------------------
        let request = CameraFormatManager.Request(width: state.width,
                                                  height: state.height,
                                                  fps: state.fps,
                                                  hdr: state.hdr)
        if let format = CameraFormatManager.bestFormat(for: device, request: request) {
            let dims = CameraFormatManager.dimensions(format)
            let fps = CameraFormatManager.supports(format, fps: state.fps)
                ? state.fps
                : Int(CameraFormatManager.maxFrameRate(format))

            DeviceLock.perform(device) { d in
                if d.activeFormat != format { d.activeFormat = format }
                let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
                d.activeVideoMinFrameDuration = duration
                d.activeVideoMaxFrameDuration = duration

                if #available(iOS 14.1, *), format.isVideoHDRSupported {
                    switch state.hdr {
                    case .off:
                        d.automaticallyAdjustsVideoHDREnabled = false
                        d.isVideoHDREnabled = false
                    case .on:
                        d.automaticallyAdjustsVideoHDREnabled = false
                        d.isVideoHDREnabled = true
                    case .auto:
                        d.automaticallyAdjustsVideoHDREnabled = true
                    }
                }
            }
            state.width = dims.width
            state.height = dims.height
            state.fps = fps
            if !(format.isVideoHDRSupported) { state.hdr = .off }
        }

        // Pixel format follows HDR: 10-bit only when HDR is genuinely on, so an
        // SDR session never pays for the wider buffers.
        let wantsHDR = state.hdr != .off
        let pixelFormat: OSType = wantsHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let available = videoOutput.availableVideoPixelFormatTypes
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                available.contains(pixelFormat) ? pixelFormat : (available.first ?? pixelFormat)
        ]

        // --- Stabilisation ----------------------------------------------
        if let connection = videoOutput.connection(with: .video) {
            let mode = CameraFormatManager.avStabilization(state.stabilization)
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = mode
            } else {
                state.stabilization = .off
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = state.mirrored
            }
        }

        // --- Zoom and Lens Lock -----------------------------------------
        let allowed = LensController.allowedDisplayRange(lens: lens, device: device,
                                                         wideBase: wideBase,
                                                         locked: state.lensLocked)
        if let applied = LensController.setZoom(device, displayZoom: state.zoom,
                                                wideBase: wideBase,
                                                allowedDisplayRange: allowed) {
            state.zoom = applied
        }

        // --- Exposure ----------------------------------------------------
        switch state.exposureMode {
        case .auto:
            if state.exposureLocked {
                ExposureController.lock(device)
            } else {
                ExposureController.setAuto(device)
                if let ev = ExposureController.setEV(device, state.ev) { state.ev = ev }
            }
            state.iso = Double(device.iso)
            state.exposureDurationUs = Int(CMTimeGetSeconds(device.exposureDuration) * 1_000_000)
        case .manual:
            if let applied = ExposureController.setManual(device,
                                                          iso: state.iso,
                                                          durationUs: state.exposureDurationUs) {
                state.iso = applied.iso
                state.exposureDurationUs = applied.durationUs
            } else {
                state.exposureMode = .auto
                ExposureController.setAuto(device)
            }
        }

        // --- White balance -----------------------------------------------
        switch state.whiteBalanceMode {
        case .auto:
            WhiteBalanceController.setAuto(device)
            let current = WhiteBalanceController.currentTemperatureAndTint(device)
            state.temperature = current.kelvin
            state.tint = current.tint
        case .manual:
            let kelvin = state.whiteBalancePreset.temperature ?? state.temperature
            if let applied = WhiteBalanceController.setTemperature(device,
                                                                   kelvin: kelvin,
                                                                   tint: state.tint) {
                state.temperature = applied.kelvin
                state.tint = applied.tint
            } else {
                state.whiteBalanceMode = .auto
                WhiteBalanceController.setAuto(device)
            }
        }

        // --- Focus --------------------------------------------------------
        switch state.focusMode {
        case .continuous:
            FocusController.setContinuous(device)
        case .single:
            if state.focusLocked { FocusController.lock(device) }
        case .manual:
            if let applied = FocusController.setManual(device, position: state.focusPosition) {
                state.focusPosition = applied
            } else {
                state.focusMode = .continuous
                FocusController.setContinuous(device)
            }
        }
        FocusController.setFaceDriven(device, enabled: state.faceDrivenFocus)

        // --- Torch --------------------------------------------------------
        if device.hasTorch {
            TorchController.apply(device, mode: state.torch, level: state.torchLevel)
        } else {
            state.torch = .off
        }
    }

    private func rebuildCapabilities() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))

        var caps = CameraCapabilities()
        caps.lenses = devices.lenses.map { lens in
            LensCapability(id: lens.id,
                           label: lens.label,
                           deviceType: lens.deviceType.rawValue,
                           position: lens.position == .front ? "front" : "back",
                           minZoom: lens.lockedDisplayZoomRange.lowerBound,
                           maxZoom: lens.lockedDisplayZoomRange.upperBound,
                           supportsMultiCam: lens.supportsMultiCam,
                           baseZoom: lens.displayZoom)
        }

        // Formats are only enumerated for lenses on devices we can reach
        // without tearing down the running session.
        var formats: [FormatCapability] = []
        for lens in devices.lenses {
            guard let device = devices.device(for: lens) else { continue }
            formats.append(contentsOf: CameraFormatManager.capabilities(for: device, lens: lens))
        }
        caps.formats = formats

        if let device = videoInput?.device {
            caps.torch = TorchCapability(supported: device.hasTorch,
                                         levelAdjustable: TorchController.isLevelAdjustable(device))
            caps.whiteBalance = WhiteBalanceCapability(
                supported: WhiteBalanceController.supportsManual(device),
                temperatureRange: [2_000, 10_000],
                tintRange: [-150, 150])
            caps.focus = FocusCapability(manual: FocusController.supportsManual(device),
                                         faceDriven: true,
                                         pointOfInterest: device.isFocusPointOfInterestSupported)
        }

        caps.multiCam = MultiCamCapability(
            supported: AVCaptureMultiCamSession.isMultiCamSupported,
            combinations: [])

        capabilities = caps
        DispatchQueue.main.async { [weak self] in self?.onCapabilities?(caps) }
    }

    // MARK: - Health

    private func observeSystemPressure(on device: AVCaptureDevice) {
        systemPressureObservation?.invalidate()
        systemPressureObservation = device.observe(\.systemPressureState,
                                                    options: [.new]) { [weak self] _, change in
            guard let self, let level = change.newValue?.level else { return }
            Log.thermal.notice("System pressure: \(level.rawValue, privacy: .public)")
            DispatchQueue.main.async { self.onSystemPressure?(level) }
        }
    }

    private func registerNotifications() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                           name: .AVCaptureSessionRuntimeError, object: session)
        center.addObserver(self, selector: #selector(sessionInterrupted(_:)),
                           name: .AVCaptureSessionWasInterrupted, object: session)
        center.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                           name: .AVCaptureSessionInterruptionEnded, object: session)
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        guard let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        Log.camera.error("Capture session runtime error: \(error.code.rawValue, privacy: .public)")

        // `mediaServicesWereReset` is recoverable and common after a phone call
        // or a Control Centre camera grab. Restarting is the correct response,
        // not an error dialog.
        if error.code == .mediaServicesWereReset {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if !self.session.isRunning { self.session.startRunning() }
            }
            return
        }
        report(.cameraBusy(detail: "AVError \(error.code.rawValue)"))
    }

    @objc private func sessionInterrupted(_ note: Notification) {
        let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        let reason = raw.flatMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
        let message: String?
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            message = nil     // Expected. Screen-off mode handles this path.
        case .audioDeviceInUseByAnotherClient:
            message = String(localized: "Another app is using the microphone.")
        case .videoDeviceInUseByAnotherClient:
            message = String(localized: "Another app is using the camera.")
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            message = String(localized: "The camera pauses while iCam shares the screen with another app.")
        case .videoDeviceNotAvailableDueToSystemPressure:
            message = String(localized: "iPhone paused the camera to cool down. iCam will resume it.")
        default:
            message = nil
        }
        DispatchQueue.main.async { [weak self] in self?.onInterruption?(true, message) }
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.onInterruption?(false, nil) }
    }

    private func report(_ error: ICamError) {
        Log.camera.error("\(error.code, privacy: .public) \(error.detail ?? "", privacy: .public)")
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }
}

// MARK: - Sample delivery

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate,
                        AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput {
            capturedFrames &+= 1
            sampleFps()
            // The buffer is passed by reference to every sink. Nothing here
            // copies it, converts it, or retains it beyond the call.
            for sink in videoSinks { sink.receive(video: sampleBuffer) }
        } else if output === audioOutput {
            for sink in audioSinks { sink.receive(audio: sampleBuffer) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output === videoOutput else { return }
        droppedFrames &+= 1
    }

    private func sampleFps() {
        framesSinceFpsSample &+= 1
        let now = MonotonicClock.nowUs()
        if lastFpsSampleUs == 0 { lastFpsSampleUs = now; return }
        let elapsed = now - lastFpsSampleUs
        guard elapsed >= 1_000_000 else { return }
        measuredFps = Double(framesSinceFpsSample) * 1_000_000 / Double(elapsed)
        framesSinceFpsSample = 0
        lastFpsSampleUs = now
    }
}
