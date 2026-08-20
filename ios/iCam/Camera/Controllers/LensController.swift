import Foundation
import AVFoundation

/// Zoom and lens selection, including Lens Lock.
struct LensController {

    /// Converts the number the user sees (`1.0` = wide) into the device's own
    /// zoom factor, which on a virtual device is measured from the ultra-wide.
    static func nativeZoom(displayZoom: Double, wideBase: Double) -> Double {
        displayZoom * wideBase
    }

    static func displayZoom(nativeZoom: Double, wideBase: Double) -> Double {
        nativeZoom / max(wideBase, 0.0001)
    }

    /// Applies zoom immediately. Used for pinch, where any ramp would feel like
    /// lag between the fingers and the image.
    @discardableResult
    static func setZoom(_ device: AVCaptureDevice,
                        displayZoom: Double,
                        wideBase: Double,
                        allowedDisplayRange: ClosedRange<Double>) -> Double? {
        let clampedDisplay = displayZoom.clamped(to: allowedDisplayRange)
        let native = nativeZoom(displayZoom: clampedDisplay, wideBase: wideBase)
            .clamped(to: 1.0 ... Double(device.activeFormat.videoMaxZoomFactor))

        return DeviceLock.with(device) { d -> Double in
            d.videoZoomFactor = CGFloat(native)
            return LensController.displayZoom(nativeZoom: native, wideBase: wideBase)
        }
    }

    /// Applies zoom as a ramp. Used when tapping a lens button, so the optical
    /// transition reads as a move rather than a cut.
    @discardableResult
    static func rampZoom(_ device: AVCaptureDevice,
                         toDisplayZoom target: Double,
                         wideBase: Double,
                         allowedDisplayRange: ClosedRange<Double>,
                         rate: Float = 12.0) -> Double? {
        let clampedDisplay = target.clamped(to: allowedDisplayRange)
        let native = nativeZoom(displayZoom: clampedDisplay, wideBase: wideBase)
            .clamped(to: 1.0 ... Double(device.activeFormat.videoMaxZoomFactor))

        return DeviceLock.with(device) { d -> Double in
            d.ramp(toVideoZoomFactor: CGFloat(native), withRate: rate)
            return clampedDisplay
        }
    }

    static func cancelRamp(_ device: AVCaptureDevice) {
        DeviceLock.perform(device) { d in
            if d.isRampingVideoZoom { d.cancelVideoZoomRamp() }
        }
    }

    /// The display-zoom range the user may reach.
    ///
    /// With Lens Lock on, this is the range that stays on the current physical
    /// lens — that is the whole mechanism. Without it, the full device range.
    static func allowedDisplayRange(lens: LensOption,
                                    device: AVCaptureDevice,
                                    wideBase: Double,
                                    locked: Bool,
                                    maxDigitalZoom: Double = 16) -> ClosedRange<Double> {
        if locked { return lens.lockedDisplayZoomRange }
        let deviceMax = Double(device.activeFormat.videoMaxZoomFactor) / max(wideBase, 0.0001)
        let lower = 1.0 / max(wideBase, 0.0001)
        return lower ... min(deviceMax, maxDigitalZoom)
    }

    /// The zoom factor at which the wide lens takes over, used as the reference
    /// for every number shown to the user.
    static func wideBase(for device: AVCaptureDevice) -> Double {
        let constituents = device.constituentDevices
        guard !constituents.isEmpty else { return 1.0 }
        var factors: [Double] = [1.0]
        factors.append(contentsOf: device.virtualDeviceSwitchOverVideoZoomFactors.map { Double(truncating: $0) })
        guard let wideIndex = constituents.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }),
              factors.indices.contains(wideIndex) else { return 1.0 }
        return factors[wideIndex]
    }

    /// Which lens a display zoom currently resolves to. Used to keep the lens
    /// selector honest while the user pinches across a switch-over point.
    static func activeLens(for displayZoom: Double, among lenses: [LensOption]) -> LensOption? {
        lenses
            .filter { $0.lockedDisplayZoomRange.lowerBound <= displayZoom + 0.001 }
            .max { $0.displayZoom < $1.displayZoom }
            ?? lenses.min { $0.displayZoom < $1.displayZoom }
    }
}
