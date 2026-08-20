import Foundation
import AVFoundation
import CoreMedia

/// Everything that happens between "a frame was captured" and "the PC has it".
///
/// Owns the stream encoder, the adaptive bitrate controller, and the sequence
/// numbering. Deliberately separate from `CameraViewModel`: the view model
/// should not know what a parameter set is, and this should not know what a
/// button is.
final class StreamSession: NSObject, VideoFrameSink {

    private let encoder = StreamEncoder()
    private var bitrateController: BitrateController
    private var profile: StreamProfile
    private var sequence: UInt32 = 0
    private let lock = NSLock()

    private var isActive = false
    private var thermalCeiling = ThermalBudget.full.maxStreamBitrate
    /// Set when the PC has just (re)connected and needs a picture immediately.
    private var needsKeyframe = true

    /// Only every Nth captured frame is encoded, when the stream runs slower
    /// than the capture. Decimating here rather than in the encoder means the
    /// encoder never sees work it would only throw away.
    private var captureFps: Int = 30
    private var frameCounter: UInt64 = 0

    /// Called on the encoder queue with a ready-to-send access unit.
    var onEncodedFrame: ((StreamEncoder.EncodedFrame, UInt32) -> Void)?
    var onError: ((ICamError) -> Void)?
    var onProfileChanged: ((StreamProfile) -> Void)?

    init(profile: StreamProfile = .webcam1080p30) {
        self.profile = profile
        self.bitrateController = BitrateController(profile: profile)
        super.init()

        encoder.onEncodedFrame = { [weak self] frame in
            guard let self else { return }
            self.lock.lock()
            self.sequence &+= 1
            let sequence = self.sequence
            self.lock.unlock()
            self.onEncodedFrame?(frame, sequence)
        }
        encoder.onError = { [weak self] error in self?.onError?(error) }
    }

    // MARK: - Control

    func start(profile newProfile: StreamProfile, captureFps: Int) {
        lock.lock()
        profile = clamp(newProfile)
        self.captureFps = max(1, captureFps)
        bitrateController = BitrateController(profile: profile)
        bitrateController.setCeiling(thermalCeiling)
        isActive = true
        needsKeyframe = true
        frameCounter = 0
        let applied = profile
        lock.unlock()

        encoder.configure(profile: applied)
        onProfileChanged?(applied)
        Log.stream.notice("Streaming \(applied.width, privacy: .public)x\(applied.height, privacy: .public)@\(applied.fps, privacy: .public)")
    }

    func stop() {
        lock.lock()
        isActive = false
        lock.unlock()
        encoder.stop()
    }

    func reconfigure(profile newProfile: StreamProfile) {
        lock.lock()
        profile = clamp(newProfile)
        bitrateController = BitrateController(profile: profile)
        bitrateController.setCeiling(thermalCeiling)
        needsKeyframe = true
        let applied = profile
        lock.unlock()
        encoder.configure(profile: applied)
        onProfileChanged?(applied)
    }

    /// The PC reconnected; it needs an IDR and fresh parameter sets now, not at
    /// the next scheduled keyframe two seconds from now.
    func requestKeyframe() {
        lock.lock(); needsKeyframe = true; lock.unlock()
        encoder.requestKeyframe()
    }

    /// The thermal manager lowered what the stream is allowed to use.
    func applyThermalBudget(_ budget: ThermalBudget) {
        lock.lock()
        thermalCeiling = budget.maxStreamBitrate
        bitrateController.setCeiling(budget.maxStreamBitrate)
        var next = profile
        let pixels = next.width * next.height
        var changedResolution = false
        if pixels > budget.maxStreamPixels {
            // Only at this point does resolution move — bitrate has already
            // been tried, and dropping resolution is the last thing before
            // dropping frames.
            let scale = (Double(budget.maxStreamPixels) / Double(pixels)).squareRoot()
            next.width = Int((Double(next.width) * scale / 16).rounded()) * 16
            next.height = Int((Double(next.height) * scale / 16).rounded()) * 16
            changedResolution = true
        }
        next.bitrate = min(next.bitrate, budget.maxStreamBitrate)
        profile = next
        let applied = next
        lock.unlock()

        if changedResolution {
            encoder.configure(profile: applied)
            onProfileChanged?(applied)
        } else {
            encoder.updateBitrate(applied.bitrate)
        }
    }

    /// One adaptive step, fed once a second by the view model.
    func updateAdaptiveBitrate(rttUs: UInt64, pendingBytes: Int, transportDrops: UInt64) {
        let feedback = BitrateController.Feedback(rttUs: rttUs,
                                                  pendingBytes: pendingBytes,
                                                  encoderDrops: encoder.droppedFrames,
                                                  transportDrops: transportDrops)
        lock.lock()
        let decision = bitrateController.update(feedback)
        if let decision { profile.bitrate = decision.bitrate }
        lock.unlock()
        if let decision { encoder.updateBitrate(decision.bitrate) }
    }

    var currentProfile: StreamProfile {
        lock.lock(); defer { lock.unlock() }
        return profile
    }

    var stats: (fps: Double, bitrate: Int, latencyUs: UInt64, dropped: UInt64) {
        (encoder.measuredFps, encoder.measuredBitrate, encoder.lastLatencyUs, encoder.droppedFrames)
    }

    // MARK: - Frame sink

    func receive(video sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let active = isActive
        let targetFps = profile.fps
        let sourceFps = captureFps
        let forceKeyframe = needsKeyframe
        if needsKeyframe { needsKeyframe = false }
        frameCounter &+= 1
        let counter = frameCounter
        lock.unlock()

        guard active, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Decimate when the stream is slower than the capture. A 60 fps capture
        // feeding a 30 fps webcam encodes every second frame — and the frames it
        // skips cost nothing at all.
        if targetFps < sourceFps {
            let step = max(1, UInt64((Double(sourceFps) / Double(targetFps)).rounded()))
            guard counter % step == 0 || forceKeyframe else { return }
        }

        encoder.encode(pixelBuffer: pixelBuffer,
                       ptsUs: MonotonicClock.us(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                       forceKeyframe: forceKeyframe)
    }

    // MARK: - Helpers

    /// Keeps a requested profile inside what the encoder and the link can
    /// sensibly do, so a bad value from the PC cannot wedge the stream.
    private func clamp(_ requested: StreamProfile) -> StreamProfile {
        var p = requested
        p.width = max(160, min(p.width, 3840)) / 2 * 2
        p.height = max(120, min(p.height, 2160)) / 2 * 2
        p.fps = max(1, min(p.fps, 120))
        p.bitrate = max(300_000, min(p.bitrate, thermalCeiling))
        p.keyframeIntervalSeconds = max(0.5, min(p.keyframeIntervalSeconds, 10))
        return p
    }
}
