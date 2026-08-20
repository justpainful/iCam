import Foundation
import AVFoundation
import CoreMedia

/// On-disk description of one recording session. Rewritten atomically after
/// every segment, so a crash can lose at most the segment in progress.
struct SessionManifest: Codable, Equatable, Sendable {
    struct Segment: Codable, Equatable, Sendable {
        var index: Int
        var filename: String
        var startUs: UInt64
        var durationUs: UInt64
        var bytes: UInt64
    }

    var sessionId: String
    var createdAt: Date
    var width: Int
    var height: Int
    var fps: Int
    var codec: VideoCodec
    var hasAudio: Bool
    var segments: [Segment] = []
    /// `false` until the session is closed cleanly. A manifest found with
    /// `finished == false` at launch is an interrupted recording.
    var finished = false
    /// Ranges the PC did *not* receive, for missing-segment recovery.
    var pcGapsUs: [[UInt64]] = []

    var totalDurationUs: UInt64 { segments.reduce(0) { $0 + $1.durationUs } }
    var totalBytes: UInt64 { segments.reduce(0) { $0 + $1.bytes } }
}

/// Writes the master recording as a sequence of independently playable files.
///
/// A single long `.mov` is written with its index at the end: kill the process
/// and the whole file is unplayable. Rolling to a new file every minute bounds
/// the damage to at most one minute, and the manifest makes recovery
/// mechanical rather than forensic.
final class SegmentWriter {

    struct Configuration {
        var directory: URL
        var sessionId: String
        var videoSettings: [String: Any]
        var audioSettings: [String: Any]?
        var sourceFormatHint: CMFormatDescription?
        var transform: CGAffineTransform = .identity
        var segmentSeconds: Double = 60
        var width: Int
        var height: Int
        var fps: Int
        var codec: VideoCodec
    }

    private let config: Configuration
    private let lock = NSLock()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    private var manifest: SessionManifest
    private var segmentIndex = 0
    private var segmentStart: CMTime = .invalid
    private var sessionStart: CMTime = .invalid
    private var lastVideoTime: CMTime = .invalid
    private var isFinishing = false

    private(set) var isRunning = false
    /// Frames that could not be written because the writer was not ready.
    /// Surfaced in diagnostics — a non-zero value here is a real problem.
    private(set) var droppedFrames: UInt64 = 0

    var manifestURL: URL {
        config.directory.appendingPathComponent("\(config.sessionId).json")
    }

    init(configuration: Configuration) {
        self.config = configuration
        self.manifest = SessionManifest(sessionId: configuration.sessionId,
                                        createdAt: Date(),
                                        width: configuration.width,
                                        height: configuration.height,
                                        fps: configuration.fps,
                                        codec: configuration.codec,
                                        hasAudio: configuration.audioSettings != nil)
        try? FileManager.default.createDirectory(at: configuration.directory,
                                                 withIntermediateDirectories: true)
    }

    // MARK: - Lifecycle

    func start(at time: CMTime) throws {
        lock.lock(); defer { lock.unlock() }
        guard !isRunning else { return }
        sessionStart = time
        try openSegmentLocked(at: time)
        isRunning = true
        persistManifestLocked()
    }

    /// Appends a video sample. Called on the capture video queue.
    func append(video sampleBuffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard isRunning, !isFinishing else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isValid else { return }

        // Roll before appending, so the new segment opens on this frame. The
        // encoder always emits a keyframe first, which is what makes each
        // segment independently playable.
        if segmentStart.isValid,
           CMTimeGetSeconds(CMTimeSubtract(time, segmentStart)) >= config.segmentSeconds {
            rollLocked(at: time)
        }

        guard let input = videoInput, input.isReadyForMoreMediaData else {
            droppedFrames &+= 1
            return
        }
        if input.append(sampleBuffer) {
            lastVideoTime = time
        } else {
            droppedFrames &+= 1
            Log.recording.error("Video append failed: \(String(describing: self.writer?.error))")
        }
    }

    /// Appends an audio sample. Called on the capture audio queue.
    func append(audio sampleBuffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard isRunning, !isFinishing, let input = audioInput else { return }
        // Audio before the first video frame would start the session at a time
        // the video track cannot match, and the result drifts.
        guard segmentStart.isValid else { return }
        guard input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// Closes the session. The completion carries the final manifest, which is
    /// what the library and any pending PC transfer work from.
    func finish(completion: @escaping (Result<SessionManifest, Error>) -> Void) {
        lock.lock()
        guard isRunning, !isFinishing else {
            let current = manifest
            lock.unlock()
            completion(.success(current))
            return
        }
        isFinishing = true
        let end = lastVideoTime.isValid ? lastVideoTime : segmentStart
        let writerToClose = writer
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        let index = segmentIndex
        let start = segmentStart
        lock.unlock()

        guard let writerToClose else {
            lock.lock()
            isRunning = false
            isFinishing = false
            manifest.finished = true
            persistManifestLocked()
            let final = manifest
            lock.unlock()
            completion(.success(final))
            return
        }

        writerToClose.finishWriting { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.closeSegmentLocked(writer: writerToClose, index: index, start: start, end: end)
            self.manifest.finished = true
            self.isRunning = false
            self.isFinishing = false
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            self.persistManifestLocked()
            let final = self.manifest
            self.lock.unlock()

            Log.recording.notice("Closed session with \(final.segments.count, privacy: .public) segments")
            completion(.success(final))
        }
    }

    /// Records a window the PC missed, so recovery can offer exactly that range.
    func noteGap(fromUs: UInt64, toUs: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard toUs > fromUs else { return }
        manifest.pcGapsUs.append([fromUs, toUs])
        persistManifestLocked()
    }

    var currentManifest: SessionManifest {
        lock.lock(); defer { lock.unlock() }
        return manifest
    }

    var elapsedUs: UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard sessionStart.isValid, lastVideoTime.isValid else { return 0 }
        return MonotonicClock.us(from: CMTimeSubtract(lastVideoTime, sessionStart))
    }

    // MARK: - Segments, lock held

    private func openSegmentLocked(at time: CMTime) throws {
        let filename = String(format: "%@-%04d.mov", config.sessionId, segmentIndex)
        let url = config.directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)

        let newWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Movie fragments give a partially written file a chance of being
        // readable even before recovery reassembles anything.
        newWriter.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        newWriter.shouldOptimizeForNetworkUse = false

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: config.videoSettings)
        video.expectsMediaDataInRealTime = true
        video.transform = config.transform
        guard newWriter.canAdd(video) else {
            throw ICamError.recordFailed(detail: "writer rejected the video input")
        }
        newWriter.add(video)

        var audio: AVAssetWriterInput?
        if let audioSettings = config.audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if newWriter.canAdd(input) {
                newWriter.add(input)
                audio = input
            }
        }

        guard newWriter.startWriting() else {
            throw ICamError.recordFailed(detail: newWriter.error.map { String(describing: $0) })
        }
        newWriter.startSession(atSourceTime: time)

        writer = newWriter
        videoInput = video
        audioInput = audio
        segmentStart = time
        lastVideoTime = time
    }

    private func rollLocked(at time: CMTime) {
        guard let old = writer else { return }
        let closingIndex = segmentIndex
        let closingStart = segmentStart
        let closingEnd = lastVideoTime.isValid ? lastVideoTime : time

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        segmentIndex += 1
        do {
            try openSegmentLocked(at: time)
        } catch {
            // The new segment could not be opened. Keep the old writer rather
            // than losing the recording entirely, and let the next roll retry.
            Log.recording.error("Could not roll to a new segment: \(String(describing: error))")
            writer = old
            segmentIndex = closingIndex
            segmentStart = closingStart
            return
        }

        // The old writer finishes on its own time; nothing downstream waits.
        old.finishWriting { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.closeSegmentLocked(writer: old, index: closingIndex,
                                    start: closingStart, end: closingEnd)
            self.persistManifestLocked()
            self.lock.unlock()
        }
    }

    private func closeSegmentLocked(writer: AVAssetWriter, index: Int,
                                    start: CMTime, end: CMTime) {
        let url = writer.outputURL
        guard writer.status == .completed else {
            Log.recording.error("Segment \(index, privacy: .public) ended in state \(writer.status.rawValue, privacy: .public)")
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let startUs = sessionStart.isValid
            ? MonotonicClock.us(from: CMTimeSubtract(start, sessionStart)) : 0
        let durationUs = (start.isValid && end.isValid && end > start)
            ? MonotonicClock.us(from: CMTimeSubtract(end, start)) : 0

        manifest.segments.append(SessionManifest.Segment(index: index,
                                                         filename: url.lastPathComponent,
                                                         startUs: startUs,
                                                         durationUs: durationUs,
                                                         bytes: bytes))
        manifest.segments.sort { $0.index < $1.index }
    }

    private func persistManifestLocked() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            Log.recording.error("Could not write the session manifest: \(String(describing: error))")
        }
    }
}
