import Foundation

/// What this specific iPhone can actually do. Every value here is read from the
/// live `AVCaptureDevice`; nothing in this file is ever hardcoded per model.
struct CameraCapabilities: Codable, Equatable, Sendable {
    var lenses: [LensCapability] = []
    var formats: [FormatCapability] = []
    var torch = TorchCapability()
    var whiteBalance = WhiteBalanceCapability()
    var focus = FocusCapability()
    var multiCam = MultiCamCapability()

    func lens(id: String) -> LensCapability? { lenses.first { $0.id == id } }

    func formats(forLens id: String) -> [FormatCapability] {
        formats.filter { $0.lensId == id }
    }

    /// Distinct resolutions available on a lens, largest first.
    func resolutions(forLens id: String) -> [Resolution] {
        var seen = Set<Resolution>()
        for f in formats(forLens: id) {
            seen.insert(Resolution(width: f.width, height: f.height))
        }
        return seen.sorted { $0.width * $0.height > $1.width * $1.height }
    }

    /// Frame rates available for a lens at a resolution. Never assume every
    /// resolution supports every rate — many do not.
    func frameRates(forLens id: String, width: Int, height: Int) -> [Int] {
        let candidates = [24, 25, 30, 50, 60, 120, 240]
        let matching = formats(forLens: id).filter { $0.width == width && $0.height == height }
        var result: [Int] = []
        for rate in candidates {
            let supported = matching.contains { f in
                f.fpsRanges.contains { Double(rate) >= $0[0] - 0.01 && Double(rate) <= $0[1] + 0.01 }
            }
            if supported { result.append(rate) }
        }
        return result
    }
}

struct Resolution: Codable, Hashable, Sendable {
    var width: Int
    var height: Int

    /// `1080p`, `4K`, or `1440 × 1080` when it is not a familiar name.
    var displayName: String {
        switch (width, height) {
        case (3840, 2160), (4096, 2160): return "4K"
        case (2560, 1440):               return "1440p"
        case (1920, 1080):               return "1080p"
        case (1280, 720):                return "720p"
        default:                         return "\(width) × \(height)"
        }
    }
}

struct LensCapability: Codable, Equatable, Sendable, Identifiable {
    var id: String
    /// What the lens selector shows: `0.5`, `1`, `2`, `3`.
    var label: String
    var deviceType: String
    var position: String          // "back" | "front"
    var minZoom: Double
    var maxZoom: Double
    /// Zoom factors at which a virtual device switches physical lenses.
    var switchOverZoom: [Double] = []
    var supportsMultiCam: Bool = false
    /// The zoom factor on the *virtual* device that this label corresponds to,
    /// for devices that expose several physical lenses through one AVCaptureDevice.
    var baseZoom: Double = 1.0
}

struct FormatCapability: Codable, Equatable, Sendable {
    var lensId: String
    var width: Int
    var height: Int
    /// `[[min, max], ...]` frame-rate ranges.
    var fpsRanges: [[Double]]
    var hdr: Bool
    var codecs: [VideoCodec]
    var stabilization: [Stabilization]
    var isoRange: [Double]                 // [min, max]
    var exposureDurationUsRange: [Int]     // [min, max]
    var maxPhotoDimensions: [Int]          // [width, height]
    var supportsRaw: Bool
    var isMultiCamSupported: Bool = false
}

struct TorchCapability: Codable, Equatable, Sendable {
    var supported = false
    var levelAdjustable = false
}

struct WhiteBalanceCapability: Codable, Equatable, Sendable {
    var supported = false
    var temperatureRange: [Double] = [2000, 10000]
    var tintRange: [Double] = [-150, 150]
}

struct FocusCapability: Codable, Equatable, Sendable {
    var manual = false
    var faceDriven = false
    var pointOfInterest = false
}

struct MultiCamCapability: Codable, Equatable, Sendable {
    var supported = false
    var combinations: [[String]] = []
}
