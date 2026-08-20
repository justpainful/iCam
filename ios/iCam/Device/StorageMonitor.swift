import Foundation
import Combine

/// Free space, and how long the current settings can keep recording into it.
///
/// The estimate is derived from the bitrate iCam is actually about to use, not
/// from a table of guesses, so it stays true when the user changes codec or
/// resolution.
@MainActor
final class StorageMonitor: ObservableObject {

    @Published private(set) var freeBytes: UInt64 = 0
    @Published private(set) var totalBytes: UInt64 = 0

    /// Below this, iCam refuses to start a new recording rather than producing
    /// a file that dies thirty seconds in.
    static let minimumFreeBytesToRecord: UInt64 = 500 * 1024 * 1024
    /// Below this, the interface warns before recording.
    static let lowFreeBytes: UInt64 = 2 * 1024 * 1024 * 1024

    private var timer: Timer?

    init() {
        refresh()
        // Once a minute is plenty; polling storage faster costs power and tells
        // us nothing new.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    var isLow: Bool { freeBytes < Self.lowFreeBytes }
    var canRecord: Bool { freeBytes >= Self.minimumFreeBytesToRecord }

    func refresh() {
        let url = URL.icamDocuments
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey
        ]) else { return }

        if let available = values.volumeAvailableCapacityForImportantUsage {
            freeBytes = UInt64(max(0, available))
        }
        if let total = values.volumeTotalCapacity {
            totalBytes = UInt64(max(0, total))
        }
    }

    /// Recording time left at a given bitrate, in seconds. Audio is included as
    /// a flat allowance because it is small and near-constant.
    func estimatedSeconds(videoBitrate: Int, audioBitrate: Int = 128_000) -> TimeInterval {
        let bytesPerSecond = Double(videoBitrate + audioBitrate) / 8
        guard bytesPerSecond > 0 else { return 0 }
        // Keep the reserve out of the estimate, so "2 hours left" means two
        // hours that will actually be written.
        let usable = Double(freeBytes > Self.minimumFreeBytesToRecord
                            ? freeBytes - Self.minimumFreeBytesToRecord : 0)
        return usable / bytesPerSecond
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds)
        if total >= 3600 {
            let h = total / 3600, m = (total % 3600) / 60
            return m > 0 ? String(localized: "\(h) hr \(m) min") : String(localized: "\(h) hr")
        }
        return String(localized: "\(max(1, total / 60)) min")
    }
}

extension URL {
    /// Where iCam keeps everything it owns. One root, so `Clear Cache` and
    /// storage accounting can never touch anything outside it.
    static var icamDocuments: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iCam", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    static var icamRecordings: URL { icamSubdirectory("Recordings") }
    static var icamPhotos: URL { icamSubdirectory("Photos") }
    static var icamCache: URL { icamSubdirectory("Cache") }

    private static func icamSubdirectory(_ name: String) -> URL {
        let url = icamDocuments.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }
}
