import Foundation
import AVFoundation

/// `lockForConfiguration` is easy to leave locked on an early return, and a
/// device left locked stops responding to everything else. One helper, used
/// everywhere, makes that impossible.
enum DeviceLock {
    @discardableResult
    static func with<T>(_ device: AVCaptureDevice, _ body: (AVCaptureDevice) throws -> T) -> T? {
        do {
            try device.lockForConfiguration()
        } catch {
            Log.camera.error("Could not lock camera for configuration: \(String(describing: error))")
            return nil
        }
        defer { device.unlockForConfiguration() }
        do {
            return try body(device)
        } catch {
            Log.camera.error("Camera configuration failed: \(String(describing: error))")
            return nil
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
