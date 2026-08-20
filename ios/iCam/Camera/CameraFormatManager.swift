import Foundation
import AVFoundation
import CoreMedia

/// Chooses `AVCaptureDevice.Format`s and reports what is genuinely available.
///
/// The interface only ever offers combinations that come out of this file, so
/// the user cannot pick 4K120 on a device that does not have it and then watch
/// iCam quietly fall back to something else.
enum CameraFormatManager {

    struct Request {
        var width: Int
        var height: Int
        var fps: Int
        var hdr: HDRMode
        var requiresMultiCam: Bool = false
        /// Photo quality matters when the same session serves stills.
        var prefersHighestPhotoQuality: Bool = true
    }

    static func dimensions(_ format: AVCaptureDevice.Format) -> (width: Int, height: Int) {
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return (Int(d.width), Int(d.height))
    }

    static func maxFrameRate(_ format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
    }

    static func supports(_ format: AVCaptureDevice.Format, fps: Int) -> Bool {
        format.videoSupportedFrameRateRanges.contains {
            Double(fps) >= $0.minFrameRate - 0.01 && Double(fps) <= $0.maxFrameRate + 0.01
        }
    }

    /// Best format for a request, or `nil` if nothing on this device fits.
    ///
    /// Scoring, in order: exact resolution, frame rate, HDR intent, then the
    /// format with the least cost — narrower field-of-view crops and binned
    /// formats run cooler, so between two equal candidates we take the cheaper.
    static func bestFormat(for device: AVCaptureDevice, request: Request) -> AVCaptureDevice.Format? {
        var candidates = device.formats.filter { format in
            guard supports(format, fps: request.fps) else { return false }
            if request.requiresMultiCam && !format.isMultiCamSupported { return false }
            let d = dimensions(format)
            return d.width == request.width && d.height == request.height
        }

        if candidates.isEmpty {
            // Nothing exact. Take the closest resolution that still hits the
            // frame rate, preferring not to exceed what was asked for.
            candidates = device.formats.filter { format in
                supports(format, fps: request.fps)
                    && (!request.requiresMultiCam || format.isMultiCamSupported)
            }
            guard !candidates.isEmpty else { return nil }
            let target = request.width * request.height
            candidates.sort { a, b in
                let da = dimensions(a), db = dimensions(b)
                let ca = abs(da.width * da.height - target)
                let cb = abs(db.width * db.height - target)
                return ca < cb
            }
        }

        func score(_ format: AVCaptureDevice.Format) -> Int {
            var s = 0
            switch request.hdr {
            case .on, .auto:
                if #available(iOS 14.1, *), format.isVideoHDRSupported { s += 100 }
            case .off:
                if #available(iOS 14.1, *), !format.isVideoHDRSupported { s += 20 }
            }
            if request.prefersHighestPhotoQuality {
                let photo = format.supportedMaxPhotoDimensions
                    .map { Int($0.width) * Int($0.height) }.max() ?? 0
                s += min(photo / 1_000_000, 60)
            }
            // Prefer a format whose maximum rate is closest above the request:
            // a 240 fps format used at 30 fps burns power for nothing.
            let headroom = maxFrameRate(format) - Double(request.fps)
            s -= Int(max(0, headroom))
            return s
        }

        return candidates.max { score($0) < score($1) }
    }

    /// Everything the capabilities message reports for one lens. Read from the
    /// device, filtered to resolutions a person would actually pick.
    static func capabilities(for device: AVCaptureDevice, lens: LensOption) -> [FormatCapability] {
        // Group by resolution so the phone does not send forty near-identical
        // formats across the wire.
        var byResolution: [Resolution: [AVCaptureDevice.Format]] = [:]
        for format in device.formats {
            let d = dimensions(format)
            // Below 720p is not something iCam offers as a capture resolution;
            // lower outputs are produced by the stream encoder instead.
            guard d.height >= 720 else { continue }
            byResolution[Resolution(width: d.width, height: d.height), default: []].append(format)
        }

        return byResolution.map { resolution, formats in
            let ranges = formats.flatMap(\.videoSupportedFrameRateRanges)
                .map { [$0.minFrameRate, $0.maxFrameRate] }
            let hdr: Bool = {
                if #available(iOS 14.1, *) { return formats.contains { $0.isVideoHDRSupported } }
                return false
            }()
            let iso = formats.map { ($0.minISO, $0.maxISO) }
            let minISO = iso.map(\.0).min() ?? 0
            let maxISO = iso.map(\.1).max() ?? 0
            let durations = formats.map {
                (CMTimeGetSeconds($0.minExposureDuration), CMTimeGetSeconds($0.maxExposureDuration))
            }
            let minDuration = Int((durations.map(\.0).min() ?? 0.001) * 1_000_000)
            let maxDuration = Int((durations.map(\.1).max() ?? 1.0) * 1_000_000)
            let photo = formats.flatMap(\.supportedMaxPhotoDimensions)
                .max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
            let raw = device.isVirtualDevice
                ? false
                : AVCapturePhotoOutput().availableRawPhotoPixelFormatTypes.isEmpty == false

            return FormatCapability(
                lensId: lens.id,
                width: resolution.width,
                height: resolution.height,
                fpsRanges: ranges,
                hdr: hdr,
                codecs: [.h264, .hevc],
                stabilization: stabilizationModes(formats),
                isoRange: [Double(minISO), Double(maxISO)],
                exposureDurationUsRange: [minDuration, maxDuration],
                maxPhotoDimensions: [Int(photo?.width ?? 0), Int(photo?.height ?? 0)],
                supportsRaw: raw,
                isMultiCamSupported: formats.contains(where: \.isMultiCamSupported))
        }
        .sorted { $0.width * $0.height > $1.width * $1.height }
    }

    private static func stabilizationModes(_ formats: [AVCaptureDevice.Format]) -> [Stabilization] {
        var modes: [Stabilization] = [.off]
        func any(_ mode: AVCaptureVideoStabilizationMode) -> Bool {
            formats.contains { $0.isVideoStabilizationModeSupported(mode) }
        }
        if any(.standard) { modes.append(.standard) }
        if any(.cinematic) { modes.append(.cinematic) }
        if #available(iOS 13.0, *), any(.cinematicExtended) { modes.append(.cinematicExtended) }
        if any(.auto) { modes.append(.auto) }
        return modes
    }

    static func avStabilization(_ mode: Stabilization) -> AVCaptureVideoStabilizationMode {
        switch mode {
        case .off:               return .off
        case .standard:          return .standard
        case .cinematic:         return .cinematic
        case .cinematicExtended: return .cinematicExtended
        case .auto:              return .auto
        }
    }
}
