import Foundation

// MARK: - Vocabulary shared with Windows

enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case h264, hevc
    var displayName: String { self == .h264 ? "H.264" : "HEVC" }
}

enum HDRMode: String, Codable, Sendable, CaseIterable {
    case off, auto, on
}

enum ExposureMode: String, Codable, Sendable, CaseIterable {
    case auto, manual
}

enum WhiteBalanceMode: String, Codable, Sendable, CaseIterable {
    case auto, manual
}

enum FocusMode: String, Codable, Sendable, CaseIterable {
    case continuous, single, manual
}

enum Stabilization: String, Codable, Sendable, CaseIterable {
    case off, standard, cinematic, cinematicExtended, auto
}

enum TorchMode: String, Codable, Sendable, CaseIterable {
    case off, on, auto
}

enum OrientationLock: String, Codable, Sendable, CaseIterable {
    case auto, portrait, landscapeLeft, landscapeRight
}

enum CaptureTarget: String, Codable, Sendable, CaseIterable {
    case phone, pc, both
}

/// White balance presets, expressed as a temperature the device can actually
/// be driven to. `custom` means the user picked a value or used Pick White.
enum WhiteBalancePreset: String, Codable, Sendable, CaseIterable {
    case auto, daylight, cloudy, shade, tungsten, fluorescent, warm, custom

    /// Kelvin, or `nil` for the two presets that are not a fixed temperature.
    var temperature: Double? {
        switch self {
        case .auto, .custom: return nil
        case .daylight:      return 5600
        case .cloudy:        return 6500
        case .shade:         return 7500
        case .tungsten:      return 3200
        case .fluorescent:   return 4000
        case .warm:          return 2800
        }
    }
}

// MARK: - The authoritative state

/// The one camera state. It lives on the phone, inside `CameraStateStore`.
/// Windows renders the last copy it received and sends mutations; it never
/// keeps a second state it believes in.
struct CameraState: Codable, Equatable, Sendable {
    var version: UInt64 = 0

    // Optics
    var lensId: String = ""
    var zoom: Double = 1.0
    var lensLocked: Bool = false

    // Format
    var width: Int = 1920
    var height: Int = 1080
    var fps: Int = 30
    var codec: VideoCodec = .hevc
    var hdr: HDRMode = .auto
    var stabilization: Stabilization = .auto

    // Exposure
    var exposureMode: ExposureMode = .auto
    var iso: Double = 100
    var exposureDurationUs: Int = 8_333
    var ev: Double = 0
    var exposureLocked: Bool = false

    // Colour
    var whiteBalanceMode: WhiteBalanceMode = .auto
    var whiteBalancePreset: WhiteBalancePreset = .auto
    var temperature: Double = 5000
    var tint: Double = 0

    // Focus
    var focusMode: FocusMode = .continuous
    var focusPosition: Double = 0.5
    var focusLocked: Bool = false
    var faceDrivenFocus: Bool = true

    // Output
    var torch: TorchMode = .off
    var torchLevel: Double = 1.0
    var mirrored: Bool = false
    var orientation: OrientationLock = .auto

    // Image rendering (applied to derived outputs, never to the master).
    // Each runs -1 to +1 and means "leave it alone" at 0.
    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var warmth: Double = 0
    var sharpness: Double = 0

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case lensId, zoom, lensLocked
        case width, height, fps, codec, hdr, stabilization
        case exposureMode, iso, exposureDurationUs, ev, exposureLocked
        case whiteBalanceMode, whiteBalancePreset, temperature, tint
        case focusMode, focusPosition, focusLocked, faceDrivenFocus
        case torch, torchLevel, mirrored, orientation
        case brightness, contrast, saturation, warmth, sharpness
    }

    /// Shutter denominator for display: 8333 µs reads as `1/120`.
    var shutterDenominator: Int {
        guard exposureDurationUs > 0 else { return 0 }
        return Int((1_000_000.0 / Double(exposureDurationUs)).rounded())
    }
}

/// A partial mutation of `CameraState`. Only the keys the sender actually
/// touched are present, which is what makes concurrent phone/PC edits safe.
struct CameraMutation: Codable, Equatable, Sendable {
    var lensId: String?
    var zoom: Double?
    var lensLocked: Bool?

    var width: Int?
    var height: Int?
    var fps: Int?
    var codec: VideoCodec?
    var hdr: HDRMode?
    var stabilization: Stabilization?

    var exposureMode: ExposureMode?
    var iso: Double?
    var exposureDurationUs: Int?
    var ev: Double?
    var exposureLocked: Bool?

    var whiteBalanceMode: WhiteBalanceMode?
    var whiteBalancePreset: WhiteBalancePreset?
    var temperature: Double?
    var tint: Double?

    var focusMode: FocusMode?
    var focusPosition: Double?
    var focusLocked: Bool?
    var faceDrivenFocus: Bool?

    var torch: TorchMode?
    var torchLevel: Double?
    var mirrored: Bool?
    var orientation: OrientationLock?

    var brightness: Double?
    var contrast: Double?
    var saturation: Double?
    var warmth: Double?
    var sharpness: Double?

    var isEmpty: Bool {
        lensId == nil && zoom == nil && lensLocked == nil
            && width == nil && height == nil && fps == nil && codec == nil
            && hdr == nil && stabilization == nil
            && exposureMode == nil && iso == nil && exposureDurationUs == nil
            && ev == nil && exposureLocked == nil
            && whiteBalanceMode == nil && whiteBalancePreset == nil
            && temperature == nil && tint == nil
            && focusMode == nil && focusPosition == nil && focusLocked == nil
            && faceDrivenFocus == nil
            && torch == nil && torchLevel == nil && mirrored == nil && orientation == nil
            && brightness == nil && contrast == nil && saturation == nil
            && warmth == nil && sharpness == nil
    }

    /// Applies every present key onto `state`. Clamping to what the hardware
    /// supports happens afterwards, in `CameraStateStore`, because only it can
    /// see the live `AVCaptureDevice`.
    func apply(to state: inout CameraState) {
        if let v = lensId { state.lensId = v }
        if let v = zoom { state.zoom = v }
        if let v = lensLocked { state.lensLocked = v }

        if let v = width { state.width = v }
        if let v = height { state.height = v }
        if let v = fps { state.fps = v }
        if let v = codec { state.codec = v }
        if let v = hdr { state.hdr = v }
        if let v = stabilization { state.stabilization = v }

        if let v = exposureMode { state.exposureMode = v }
        if let v = iso { state.iso = v }
        if let v = exposureDurationUs { state.exposureDurationUs = v }
        if let v = ev { state.ev = v }
        if let v = exposureLocked { state.exposureLocked = v }

        if let v = whiteBalanceMode { state.whiteBalanceMode = v }
        if let v = whiteBalancePreset { state.whiteBalancePreset = v }
        if let v = temperature { state.temperature = v }
        if let v = tint { state.tint = v }

        if let v = focusMode { state.focusMode = v }
        if let v = focusPosition { state.focusPosition = v }
        if let v = focusLocked { state.focusLocked = v }
        if let v = faceDrivenFocus { state.faceDrivenFocus = v }

        if let v = torch { state.torch = v }
        if let v = torchLevel { state.torchLevel = v }
        if let v = mirrored { state.mirrored = v }
        if let v = orientation { state.orientation = v }

        if let v = brightness { state.brightness = v }
        if let v = contrast { state.contrast = v }
        if let v = saturation { state.saturation = v }
        if let v = warmth { state.warmth = v }
        if let v = sharpness { state.sharpness = v }
    }
}

/// What the PC receives. Deliberately unrelated to what the phone captures or
/// records — that separation is the whole point.
struct StreamProfile: Codable, Equatable, Sendable {
    var width: Int = 1280
    var height: Int = 720
    var fps: Int = 30
    var codec: VideoCodec = .h264
    var bitrate: Int = 6_000_000
    var keyframeIntervalSeconds: Double = 2

    static let webcam1080p30 = StreamProfile(width: 1920, height: 1080, fps: 30,
                                             codec: .h264, bitrate: 8_000_000)
    static let webcam720p30  = StreamProfile(width: 1280, height: 720, fps: 30,
                                             codec: .h264, bitrate: 4_000_000)
    static let webcam1080p60 = StreamProfile(width: 1920, height: 1080, fps: 60,
                                             codec: .h264, bitrate: 12_000_000)
}
