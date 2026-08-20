import Foundation
import AVFoundation

/// Finds recordings that were interrupted and puts them back together.
///
/// Nothing incomplete is ever deleted automatically. If iCam cannot repair a
/// session, the segments stay on disk and the user is told where they are.
enum RecoveryManager {

    struct InterruptedSession: Identifiable, Equatable, Sendable {
        var id: String { manifest.sessionId }
        var manifest: SessionManifest
        var directory: URL
        var recoverableDurationUs: UInt64
    }

    /// Scans the recordings folder for manifests that were never closed.
    static func findInterruptedSessions() -> [InterruptedSession] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: URL.icamRecordings,
                                                        includingPropertiesForKeys: nil) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var result: [InterruptedSession] = []
        for directory in entries where directory.hasDirectoryPath {
            let manifestURL = directory.appendingPathComponent("\(directory.lastPathComponent).json")
            guard let data = try? Data(contentsOf: manifestURL),
                  var manifest = try? decoder.decode(SessionManifest.self, from: data),
                  !manifest.finished else { continue }

            // The manifest lists segments that were closed cleanly. There may
            // also be a final file that was still being written; it is left
            // alone rather than guessed at.
            manifest.segments = manifest.segments.filter {
                fm.fileExists(atPath: directory.appendingPathComponent($0.filename).path)
            }
            guard !manifest.segments.isEmpty else { continue }

            result.append(InterruptedSession(manifest: manifest,
                                             directory: directory,
                                             recoverableDurationUs: manifest.totalDurationUs))
        }
        return result.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    /// Marks a session as recovered so it stops being offered, without touching
    /// any media.
    static func markRecovered(_ session: InterruptedSession) throws {
        var manifest = session.manifest
        manifest.finished = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = session.directory.appendingPathComponent("\(manifest.sessionId).json")
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    /// Joins the segments of a session into one file, without re-encoding.
    ///
    /// Passthrough is not an optimisation here — re-encoding a recovered master
    /// would throw away the quality the whole architecture exists to protect.
    static func compose(_ session: InterruptedSession,
                        to outputURL: URL,
                        completion: @escaping (Result<URL, Error>) -> Void) {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(.failure(ICamError.internalError("could not create a video track")))
            return
        }
        let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid)

        Task {
            var cursor = CMTime.zero
            do {
                for segment in session.manifest.segments {
                    let url = session.directory.appendingPathComponent(segment.filename)
                    let asset = AVURLAsset(url: url)
                    let duration = try await asset.load(.duration)
                    guard duration.seconds > 0 else { continue }
                    let range = CMTimeRange(start: .zero, duration: duration)

                    if let source = try await asset.loadTracks(withMediaType: .video).first {
                        try videoTrack.insertTimeRange(range, of: source, at: cursor)
                        videoTrack.preferredTransform = try await source.load(.preferredTransform)
                    }
                    if let audioTrack,
                       let source = try await asset.loadTracks(withMediaType: .audio).first {
                        try audioTrack.insertTimeRange(range, of: source, at: cursor)
                    }
                    cursor = CMTimeAdd(cursor, duration)
                }

                guard cursor.seconds > 0 else {
                    completion(.failure(ICamError.recordFailed(detail: "nothing recoverable")))
                    return
                }

                guard let export = AVAssetExportSession(asset: composition,
                                                        presetName: AVAssetExportPresetPassthrough) else {
                    completion(.failure(ICamError.internalError("no passthrough export session")))
                    return
                }
                try? FileManager.default.removeItem(at: outputURL)
                export.outputURL = outputURL
                export.outputFileType = .mov
                await export.export()

                if export.status == .completed {
                    completion(.success(outputURL))
                } else {
                    completion(.failure(export.error
                        ?? ICamError.recordFailed(detail: "export status \(export.status.rawValue)")))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Total bytes held by every recording on disk. Used by Storage settings.
    static func totalRecordedBytes() -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: URL.icamRecordings,
                                             includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: UInt64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += UInt64(size)
        }
        return total
    }
}
