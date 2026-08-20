import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// Owns the master recording on the iPhone.
///
/// It is a `VideoFrameSink` like any other, which is the point: the network can
/// disappear, the PC can crash, the stream encoder can be reconfigured, and
/// none of it reaches this class. **Safety Recording is not a feature bolted on
/// top — it is the consequence of the recorder having no dependency on the
/// transport at all.**
final class RecordingEngine: NSObject, VideoFrameSink, AudioFrameSink {

    struct Status: Equatable, Sendable {
        var isRecording = false
        var sessionId: String?
        var target: CaptureTarget = .phone
        var elapsedUs: UInt64 = 0
        var phoneOk = true
        var pcOk = true
        var droppedFrames: UInt64 = 0
    }

    /// Fires on the main queue whenever the status changes.
    var onStatusChange: ((Status) -> Void)?
    var onError: ((ICamError) -> Void)?
    /// Fires when a session finishes cleanly, with its manifest.
    var onSessionFinished: ((SessionManifest) -> Void)?

    private var writer: SegmentWriter?
    private let lock = NSLock()
    private var status = Status()
    /// Set when the phone should keep recording even though the PC has gone.
    private var pcDisconnectedAtUs: UInt64?

    private(set) var currentSessionId: String?

    // MARK: - Public

    var currentStatus: Status {
        lock.lock(); defer { lock.unlock() }
        var s = status
        s.elapsedUs = writer?.elapsedUs ?? 0
        s.droppedFrames = writer?.droppedFrames ?? 0
        return s
    }

    /// Starts the master recording.
    ///
    /// - Parameters:
    ///   - state: the live camera state, which decides the encoder settings.
    ///   - target: where the user asked the result to end up. Note that `pc`
    ///     alone still writes locally when Safety Recording is on — the PC copy
    ///     is what the phone stops caring about, not the pixels.
    func start(state: CameraState,
               target: CaptureTarget,
               audioEnabled: Bool,
               orientationTransform: CGAffineTransform,
               storage: StorageMonitorSnapshot) throws {
        lock.lock()
        guard !status.isRecording else { lock.unlock(); return }
        lock.unlock()

        guard storage.canRecord else { throw ICamError.storageFull() }

        let sessionId = Self.newSessionId()
        let directory = URL.icamRecordings.appendingPathComponent(sessionId, isDirectory: true)

        let bitrate = Self.recommendedBitrate(width: state.width, height: state.height,
                                              fps: state.fps, codec: state.codec)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: state.fps,
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoAllowFrameReorderingKey: false
        ]
        if state.codec == .hevc {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        } else {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: state.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: state.width,
            AVVideoHeightKey: state.height,
            AVVideoCompressionPropertiesKey: compression
        ]

        let audioSettings: [String: Any]? = audioEnabled ? [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ] : nil

        let configuration = SegmentWriter.Configuration(
            directory: directory,
            sessionId: sessionId,
            videoSettings: videoSettings,
            audioSettings: audioSettings,
            transform: orientationTransform,
            segmentSeconds: 60,
            width: state.width,
            height: state.height,
            fps: state.fps,
            codec: state.codec)

        let newWriter = SegmentWriter(configuration: configuration)

        lock.lock()
        writer = newWriter
        status.isRecording = true
        status.sessionId = sessionId
        status.target = target
        status.phoneOk = true
        status.pcOk = target != .phone
        currentSessionId = sessionId
        pcDisconnectedAtUs = nil
        lock.unlock()

        Log.recording.notice("Started session \(sessionId, privacy: .public) at \(state.width, privacy: .public)x\(state.height, privacy: .public)@\(state.fps, privacy: .public)")
        publish()
    }

    func stop() {
        lock.lock()
        guard status.isRecording, let writer else { lock.unlock(); return }
        status.isRecording = false
        lock.unlock()

        writer.finish { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            self.writer = nil
            self.status = Status()
            self.currentSessionId = nil
            self.lock.unlock()
            self.publish()

            switch result {
            case .success(let manifest):
                DispatchQueue.main.async { self.onSessionFinished?(manifest) }
            case .failure(let error):
                self.report(.recordFailed(detail: String(describing: error)))
            }
        }
    }

    /// The PC went away mid-session.
    ///
    /// The local recording is not told and does not stop. The gap is recorded
    /// so that, on reconnect, iCam knows exactly which range the PC is missing.
    func pcConnectionLost(atUs: UInt64) {
        lock.lock()
        guard status.isRecording else { lock.unlock(); return }
        pcDisconnectedAtUs = atUs
        status.pcOk = false
        lock.unlock()
        Log.recording.notice("PC connection lost during a recording; the local master continues")
        publish()
    }

    func pcConnectionRestored(atUs: UInt64) {
        lock.lock()
        guard status.isRecording else { lock.unlock(); return }
        if let from = pcDisconnectedAtUs {
            writer?.noteGap(fromUs: from, toUs: atUs)
            pcDisconnectedAtUs = nil
        }
        status.pcOk = true
        lock.unlock()
        publish()
    }

    var manifest: SessionManifest? { writer?.currentManifest }

    // MARK: - Frame sinks

    func receive(video sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let active = status.isRecording
        let current = writer
        lock.unlock()
        guard active, let current else { return }

        if !current.isRunning {
            // The first frame defines the session's time origin. Starting on a
            // real sample rather than on a wall-clock guess is what keeps the
            // video and audio tracks aligned.
            do {
                try current.start(at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            } catch {
                report(.recordFailed(detail: String(describing: error)))
                stop()
                return
            }
        }
        current.append(video: sampleBuffer)
    }

    func receive(audio sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let current = writer
        let active = status.isRecording
        lock.unlock()
        guard active, let current, current.isRunning else { return }
        current.append(audio: sampleBuffer)
    }

    // MARK: - Helpers

    private func publish() {
        let snapshot = currentStatus
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(snapshot) }
    }

    private func report(_ error: ICamError) {
        Log.recording.error("\(error.code, privacy: .public) \(error.detail ?? "", privacy: .public)")
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    static func newSessionId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    /// Bitrate for the *master*. Generous by design: this is the copy the user
    /// keeps, and it is never what goes to the PC.
    static func recommendedBitrate(width: Int, height: Int, fps: Int, codec: VideoCodec) -> Int {
        let pixels = Double(width * height)
        let rateFactor = Double(max(fps, 24)) / 30.0
        // Bits per pixel per frame, tuned per codec at capture quality.
        let bitsPerPixel = codec == .hevc ? 0.085 : 0.13
        let raw = pixels * 30.0 * rateFactor * bitsPerPixel
        return Int(min(max(raw, 4_000_000), 160_000_000))
    }
}

/// A value copy of what the recorder needs from `StorageMonitor`, so the
/// recorder never has to hop to the main actor to decide whether it may start.
struct StorageMonitorSnapshot: Sendable {
    var freeBytes: UInt64
    var canRecord: Bool
}
