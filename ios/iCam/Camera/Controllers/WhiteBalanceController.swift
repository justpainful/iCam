import Foundation
import AVFoundation

/// White balance: auto, lock, presets, manual temperature and tint, Pick White.
struct WhiteBalanceController {

    static func supportsManual(_ device: AVCaptureDevice) -> Bool {
        device.isWhiteBalanceModeSupported(.locked)
            && device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
    }

    @discardableResult
    static func setAuto(_ device: AVCaptureDevice) -> Bool {
        guard device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else { return false }
        return DeviceLock.with(device) { d in
            d.whiteBalanceMode = .continuousAutoWhiteBalance
        } != nil
    }

    @discardableResult
    static func lock(_ device: AVCaptureDevice) -> Bool {
        guard device.isWhiteBalanceModeSupported(.locked) else { return false }
        return DeviceLock.with(device) { d in
            d.whiteBalanceMode = .locked
        } != nil
    }

    /// Applies a colour temperature in kelvin and a tint.
    ///
    /// The device gains that come out of a temperature can exceed what the
    /// sensor accepts, especially at the extremes. Normalising them keeps the
    /// image neutral rather than letting one channel clip.
    @discardableResult
    static func setTemperature(_ device: AVCaptureDevice,
                               kelvin: Double,
                               tint: Double) -> (kelvin: Double, tint: Double)? {
        guard supportsManual(device) else { return nil }

        let clampedKelvin = kelvin.clamped(to: 2_000 ... 10_000)
        let clampedTint = tint.clamped(to: -150 ... 150)
        let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
            temperature: Float(clampedKelvin), tint: Float(clampedTint))

        return DeviceLock.with(device) { d -> (Double, Double) in
            let gains = normalise(d.deviceWhiteBalanceGains(for: values), for: d)
            d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            return (clampedKelvin, clampedTint)
        }
    }

    /// Pick White: the user taps something that should be neutral and iCam
    /// derives the gains that make it neutral, then reports back the equivalent
    /// temperature and tint so the sliders stay meaningful.
    @discardableResult
    static func pickWhite(_ device: AVCaptureDevice,
                          averageColor: (r: Double, g: Double, b: Double))
    -> (kelvin: Double, tint: Double)? {
        guard supportsManual(device) else { return nil }
        guard averageColor.r > 0.001, averageColor.g > 0.001, averageColor.b > 0.001 else {
            return nil
        }

        // Gains that would drive the sampled patch to equal RGB.
        var gains = AVCaptureDevice.WhiteBalanceGains(
            redGain: Float(averageColor.g / averageColor.r),
            greenGain: 1.0,
            blueGain: Float(averageColor.g / averageColor.b))

        return DeviceLock.with(device) { d -> (Double, Double) in
            gains = normalise(gains, for: d)
            d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            let values = d.temperatureAndTintValues(for: gains)
            return (Double(values.temperature), Double(values.tint))
        }
    }

    static func currentTemperatureAndTint(_ device: AVCaptureDevice) -> (kelvin: Double, tint: Double) {
        let values = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
        return (Double(values.temperature), Double(values.tint))
    }

    /// Clamps every channel into `[1, maxWhiteBalanceGain]` while keeping green
    /// at 1 where possible, which is what the hardware expects.
    private static func normalise(_ gains: AVCaptureDevice.WhiteBalanceGains,
                                  for device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        var out = gains
        let upper = device.maxWhiteBalanceGain
        out.redGain = min(max(1.0, out.redGain), upper)
        out.greenGain = min(max(1.0, out.greenGain), upper)
        out.blueGain = min(max(1.0, out.blueGain), upper)
        return out
    }
}
