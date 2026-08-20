import Foundation
import AVFoundation

/// Focus: continuous, single, manual, locked, tap-to-focus, face-driven.
struct FocusController {

    @discardableResult
    static func setContinuous(_ device: AVCaptureDevice) -> Bool {
        guard device.isFocusModeSupported(.continuousAutoFocus) else { return false }
        return DeviceLock.with(device) { d in
            d.focusMode = .continuousAutoFocus
        } != nil
    }

    /// One autofocus pass, then hold. What a photographer means by "AF-S".
    @discardableResult
    static func focusOnce(_ device: AVCaptureDevice) -> Bool {
        guard device.isFocusModeSupported(.autoFocus) else { return false }
        return DeviceLock.with(device) { d in
            d.focusMode = .autoFocus
        } != nil
    }

    @discardableResult
    static func lock(_ device: AVCaptureDevice) -> Bool {
        guard device.isFocusModeSupported(.locked) else { return false }
        return DeviceLock.with(device) { d in
            d.focusMode = .locked
        } != nil
    }

    /// Manual focus. `position` is 0 (near) to 1 (infinity).
    @discardableResult
    static func setManual(_ device: AVCaptureDevice, position: Double) -> Double? {
        guard device.isLockingFocusWithCustomLensPositionSupported else { return nil }
        let clamped = position.clamped(to: 0 ... 1)
        return DeviceLock.with(device) { d -> Double in
            d.setFocusModeLocked(lensPosition: Float(clamped), completionHandler: nil)
            return clamped
        }
    }

    @discardableResult
    static func setPointOfInterest(_ device: AVCaptureDevice, _ point: CGPoint) -> Bool {
        guard device.isFocusPointOfInterestSupported else { return false }
        return DeviceLock.with(device) { d in
            d.focusPointOfInterest = point
            if d.isFocusModeSupported(.autoFocus) {
                d.focusMode = .autoFocus
            }
        } != nil
    }

    /// iOS biases autofocus and exposure toward faces by default. Some setups
    /// — a product on a desk, a whiteboard — are better off without it, so it
    /// is exposed rather than left as an invisible behaviour.
    @discardableResult
    static func setFaceDriven(_ device: AVCaptureDevice, enabled: Bool) -> Bool {
        guard device.isFaceDrivenAutoFocusEnabled != enabled else { return true }
        return DeviceLock.with(device) { d in
            if d.isFocusModeSupported(.continuousAutoFocus) {
                d.automaticallyAdjustsFaceDrivenAutoFocusEnabled = false
                d.isFaceDrivenAutoFocusEnabled = enabled
            }
        } != nil
    }

    static func supportsManual(_ device: AVCaptureDevice) -> Bool {
        device.isLockingFocusWithCustomLensPositionSupported
    }

    static func currentPosition(_ device: AVCaptureDevice) -> Double {
        Double(device.lensPosition)
    }
}
