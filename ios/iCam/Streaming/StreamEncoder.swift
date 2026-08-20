import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware video encoder for the stream sent to the PC.
///
/// This is a **second, independent** encoder. It never reads the master
/// recording and the master never reads it. That is what allows 4K60 HEVC on
/// the phone at the same time as 1080p30 H.264 in Discord.
///
/// Frames go in as `CVPixelBuffer` and come out as AVCC access units. Nothing
/// is ever converted to `UIImage`, `CGImage`, or `Data` on the way.
final class StreamEncoder {

    struct EncodedFrame {
        var data: Data
        var isKeyframe: Bool
        var ptsUs: UInt64
        var dtsUs: UInt64
        /// Present only on the first frame after a (re)configuration.
        var parameterSets: Data?
    }

    /// Called on the encoder's own queue.
    var onEncodedFrame: ((EncodedFrame) -> Void)?
    var onError: ((ICamError) -> Void)?

    private let queue = DispatchQueue(label: "com.icam.encoder", qos: .userInitiated)
    private var session: VTCompressionSession?
    private var profile = StreamProfile()
    private var needsParameterSets = true
    private var sequence: UInt32 = 0

    /// Frames currently inside the encoder. Bounded so a stalled encoder
    /// applies back pressure by dropping instead of growing without limit.
    private var inFlight = 0
    private let maxInFlight = 4

    private(set) var encodedFrames: UInt64 = 0
    private(set) var droppedFrames: UInt64 = 0
    private var lastRateSampleUs: UInt64 = 0
    private var framesSinceRateSample: UInt64 = 0
    private var bytesSinceRateSample: UInt64 = 0
    private(set) var measuredFps: Double = 0
    private(set) var measuredBitrate: Int = 0
    private(set) var lastLatencyUs: UInt64 = 0

    deinit { teardown() }

    // MARK: - Configuration

    /// Rebuilds the encoder for a new profile.
    ///
    /// Resolution and codec changes require a new session; bitrate does not, so
    /// `updateBitrate` exists separately and is what the adaptive controller
    /// calls many times a minute.
    func configure(profile newProfile: StreamProfile) {
        queue.async { [weak self] in
            guard let self else { return }
            if let session, self.profile.width == newProfile.width,
               self.profile.height == newProfile.height,
               self.profile.codec == newProfile.codec {
                self.profile = newProfile
                self.applyRateLocked(session: session, profile: newProfile)
                return
            }
            self.teardownLocked()
            self.profile = newProfile
            self.buildLocked()
        }
    }

    func updateBitrate(_ bitrate: Int) {
        queue.async { [weak self] in
            guard let self, let session = self.session else { return }
            self.profile.bitrate = bitrate
            self.applyRateLocked(session: session, profile: self.profile)
        }
    }

    /// Forces the next frame to be an IDR. Used on reconnect, so a PC that
    /// joins mid-stream gets a picture immediately instead of after the next
    /// scheduled keyframe.
    func requestKeyframe() {
        queue.async { [weak self] in self?.needsParameterSets = true }
    }

    func stop() {
        queue.async { [weak self] in self?.teardownLocked() }
    }

    // MARK: - Encoding

    /// Submits a captured frame. Safe to call from the capture video queue.
    func encode(pixelBuffer: CVPixelBuffer, ptsUs: UInt64, forceKeyframe: Bool = false) {
        queue.async { [weak self] in
            guard let self, let session = self.session else { return }

            guard self.inFlight < self.maxInFlight else {
                // The encoder is behind. Dropping now is far better than queuing
                // and adding latency the user will feel as lag.
                self.droppedFrames &+= 1
                return
            }

            var properties: CFDictionary?
            if forceKeyframe || self.needsParameterSets {
                properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            }

            let pts = CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000)
            let duration = CMTime(value: 1, timescale: CMTimeScale(max(self.profile.fps, 1)))
            self.inFlight += 1
            let submittedAt = MonotonicClock.nowUs()

            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                duration: duration,
                frameProperties: properties,
                infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
                    guard let self else { return }
                    self.queue.async {
                        self.inFlight = max(0, self.inFlight - 1)
                        self.lastLatencyUs = MonotonicClock.nowUs() - submittedAt
                        self.handleEncoded(status: status, sampleBuffer: sampleBuffer)
                    }
                }

            if status != noErr {
                self.inFlight = max(0, self.inFlight - 1)
                self.droppedFrames &+= 1
                Log.stream.error("Encode submission failed: \(status, privacy: .public)")
            }
        }
    }

    // MARK: - Internals, encoder queue only

    private func buildLocked() {
        let codecType: CMVideoCodecType = profile.codec == .hevc ? kCMVideoCodecType_HEVC
                                                                 : kCMVideoCodecType_H264
        var newSession: VTCompressionSession?

        // Refusing a software fallback matters: a CPU encoder would cook the
        // phone and still miss the frame rate. The keys that say so only exist
        // from iOS 17.4; before that, iOS already picks the hardware encoder
        // for these codecs on every device iCam supports.
        var encoderSpec: [CFString: Any] = [:]
        if #available(iOS 17.4, *) {
            encoderSpec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = true
            encoderSpec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true
        }

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(profile.width),
            height: Int32(profile.height),
            codecType: codecType,
            encoderSpecification: encoderSpec.isEmpty ? nil : encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession)

        guard status == noErr, let created = newSession else {
            Log.stream.error("Could not create the hardware encoder: \(status, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.onError?(ICamError(
                    code: "stream.unsupported",
                    title: String(localized: "Streaming is not available"),
                    message: String(localized: "This iPhone could not start a video encoder for these settings."),
                    detail: "VTCompressionSessionCreate \(status)"))
            }
            return
        }

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(created, key: key, value: value)
        }

        // Real time, low latency, no B-frames. Every one of these matters for a
        // live camera: reordering alone would add a frame of delay.
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: profile.fps))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            NSNumber(value: profile.keyframeIntervalSeconds))
        set(kVTCompressionPropertyKey_ProfileLevel,
            profile.codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel
                                   : kVTProfileLevel_H264_High_AutoLevel)

        applyRateLocked(session: created, profile: profile)
        VTCompressionSessionPrepareToEncodeFrames(created)

        session = created
        needsParameterSets = true
        sequence = 0
        Log.stream.notice("Encoder ready: \(self.profile.width, privacy: .public)x\(self.profile.height, privacy: .public)@\(self.profile.fps, privacy: .public)")
    }

    private func applyRateLocked(session: VTCompressionSession, profile: StreamProfile) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: profile.bitrate))
        // A hard ceiling over a one-second window keeps a sudden scene change
        // from producing a burst the link cannot carry.
        let limits = [NSNumber(value: profile.bitrate / 8 * 3 / 2), NSNumber(value: 1.0)] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    private func teardownLocked() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        inFlight = 0
    }

    private func teardown() {
        // `deinit` cannot dispatch; the session is invalidated inline.
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }

    private func handleEncoded(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            if status != noErr { droppedFrames &+= 1 }
            return
        }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                  createIfNecessary: false)
        var isKeyframe = true
        if let array = attachments as? [[CFString: Any]], let first = array.first {
            isKeyframe = !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        }

        var parameterSets: Data?
        if isKeyframe && needsParameterSets {
            parameterSets = Self.codecConfiguration(from: sampleBuffer, codec: profile.codec)
            if parameterSets != nil { needsParameterSets = false }
        }

        // The encoder already produces AVCC (4-byte length prefixes), which is
        // exactly what both `CMSampleBuffer` and Media Foundation want. No
        // Annex-B conversion pass, no extra copy.
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                                          lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPointer) == noErr,
              let dataPointer, totalLength > 0 else { return }

        let payload = Data(bytes: dataPointer, count: totalLength)
        let pts = MonotonicClock.us(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let dtsTime = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        let dts = dtsTime.isValid ? MonotonicClock.us(from: dtsTime) : pts

        encodedFrames &+= 1
        sequence &+= 1
        sampleRate(bytes: UInt64(totalLength))

        onEncodedFrame?(EncodedFrame(data: payload,
                                     isKeyframe: isKeyframe,
                                     ptsUs: pts,
                                     dtsUs: dts,
                                     parameterSets: parameterSets))
    }

    /// `avcC` or `hvcC`, as the protocol's parameter-set frame carries it.
    private static func codecConfiguration(from sampleBuffer: CMSampleBuffer,
                                           codec: VideoCodec) -> Data? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let key = codec == .hevc ? "hvcC" : "avcC"
        guard let extensions = CMFormatDescriptionGetExtension(
                description,
                extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
                as? [String: Any],
              let atom = extensions[key] as? Data else { return nil }
        return atom
    }

    private func sampleRate(bytes: UInt64) {
        framesSinceRateSample &+= 1
        bytesSinceRateSample &+= bytes
        let now = MonotonicClock.nowUs()
        if lastRateSampleUs == 0 { lastRateSampleUs = now; return }
        let elapsed = now - lastRateSampleUs
        guard elapsed >= 1_000_000 else { return }
        measuredFps = Double(framesSinceRateSample) * 1_000_000 / Double(elapsed)
        measuredBitrate = Int(Double(bytesSinceRateSample * 8) * 1_000_000 / Double(elapsed))
        framesSinceRateSample = 0
        bytesSinceRateSample = 0
        lastRateSampleUs = now
    }
}
