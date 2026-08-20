import Foundation
import AVFoundation
import CoreMedia

/// Exposure, ISO, shutter and EV.
///
/// Every setter clamps to the range the *active format* reports and returns the
/// value that was actually applied, so the interface can snap to reality
/// instead of showing a number the sensor never accepted.
struct ExposureController {

    static func isoRange(_ device: AVCaptureDevice) -> ClosedRange<Double> {
        Double(device.activeFormat.minISO) ... Double(device.activeFormat.maxISO)
    }

    static func exposureDurationUsRange(_ device: AVCaptureDevice) -> ClosedRange<Int> {
        let minUs = Int(CMTimeGetSeconds(device.activeFormat.minExposureDuration) * 1_000_000)
        let maxUs = Int(CMTimeGetSeconds(device.activeFormat.maxExposureDuration) * 1_000_000)
        return max(1, minUs) ... max(minUs + 1, maxUs)
    }

    static func evRange(_ device: AVCaptureDevice) -> ClosedRange<Double> {
        Double(device.minExposureTargetBias) ... Double(device.maxExposureTargetBias)
    }

    /// Switches to continuous auto exposure.
    @discardableResult
    static func setAuto(_ device: AVCaptureDevice) -> Bool {
        guard device.isExposureModeSupported(.continuousAutoExposure) else { return false }
        return DeviceLock.perform(device) { d in
            d.exposureMode = .continuousAutoExposure
        }
    }

    /// Locks exposure at whatever the sensor is doing right now.
    @discardableResult
    static func lock(_ device: AVCaptureDevice) -> Bool {
        guard device.isExposureModeSupported(.locked) else { return false }
        return DeviceLock.perform(device) { d in
            d.exposureMode = .locked
        }
    }

    /// Applies manual ISO and shutter together — the device requires both in
    /// one call, and setting them separately produces a visible exposure jump.
    @discardableResult
    static func setManual(_ device: AVCaptureDevice,
                          iso: Double,
                          durationUs: Int) -> (iso: Double, durationUs: Int)? {
        guard device.isExposureModeSupported(.custom) else { return nil }

        let clampedISO = Float(iso.clamped(to: isoRange(device)))
        let clampedUs = durationUs.clamped(to: exposureDurationUsRange(device))
        let duration = CMTime(value: CMTimeValue(clampedUs), timescale: 1_000_000)

        let applied = DeviceLock.with(device) { d -> (Double, Int) in
            d.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
            return (Double(clampedISO), clampedUs)
        }
        guard let applied else { return nil }
        return (applied.0, applied.1)
    }

    /// Exposure compensation. Works in auto mode; in custom mode the device
    /// ignores it, which is why the interface hides the slider there.
    @discardableResult
    static func setEV(_ device: AVCaptureDevice, _ ev: Double) -> Double? {
        let clamped = ev.clamped(to: evRange(device))
        return DeviceLock.with(device) { d -> Double in
            d.setExposureTargetBias(Float(clamped), completionHandler: nil)
            return clamped
        }
    }

    /// Tap to expose. `point` is in device coordinates: (0,0) top-left of the
    /// sensor in landscape-left, which is what the preview layer converts to.
    @discardableResult
    static func setPointOfInterest(_ device: AVCaptureDevice, _ point: CGPoint) -> Bool {
        guard device.isExposurePointOfInterestSupported else { return false }
        return DeviceLock.perform(device) { d in
            d.exposurePointOfInterest = point
            if d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposureMode = .continuousAutoExposure
            }
        }
    }

    /// Values to show as shutter stops. Filtered to what the format allows, so
    /// a 30 fps format never offers 1/1000 that it cannot hold.
    static func shutterPresets(_ device: AVCaptureDevice) -> [Int] {
        let denominators = [24, 30, 48, 50, 60, 100, 120, 240, 500, 1000, 2000, 4000]
        let range = exposureDurationUsRange(device)
        return denominators.filter { d in
            let us = 1_000_000 / d
            return range.contains(us)
        }
    }
}
