import Foundation
import AVFoundation

/// Torch. Small surface, but it is the control most likely to be hit by
/// thermal limits, so it reports failure honestly rather than pretending.
struct TorchController {

    static func isSupported(_ device: AVCaptureDevice) -> Bool { device.hasTorch }

    static func isLevelAdjustable(_ device: AVCaptureDevice) -> Bool {
        device.hasTorch && device.isTorchModeSupported(.on)
    }

    @discardableResult
    static func apply(_ device: AVCaptureDevice, mode: TorchMode, level: Double) -> Bool {
        guard device.hasTorch else { return false }

        return DeviceLock.perform(device) { d in
            switch mode {
            case .off:
                if d.isTorchModeSupported(.off) { d.torchMode = .off }
            case .auto:
                if d.isTorchModeSupported(.auto) { d.torchMode = .auto }
                else if d.isTorchModeSupported(.on) { d.torchMode = .on }
            case .on:
                let clamped = Float(level.clamped(to: 0.01 ... 1.0))
                // `setTorchModeOn(level:)` throws when the LED is too warm to
                // run at that level. That is a real condition worth surfacing,
                // not something to swallow.
                try d.setTorchModeOn(level: min(clamped, AVCaptureDevice.maxAvailableTorchLevel))
            }
        }
    }

    static func isOverheated(_ device: AVCaptureDevice) -> Bool {
        device.hasTorch && device.torchMode != .off && !device.isTorchActive
    }
}
