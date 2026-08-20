import Foundation
import AVFoundation

/// `lockForConfiguration` is easy to leave locked on an early return, and a
/// device left locked stops responding to everything else. One helper, used
/// everywhere, makes that impossible.
enum DeviceLock {

    /// Runs `body` with the device locked and returns what it produced, or
    /// `nil` if the lock or the body failed.
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

    /// The same, for the common case where the caller only needs to know
    /// whether it worked. Kept separate from `with` because a closure that
    /// returns nothing gives the compiler nothing to infer `T` from.
    @discardableResult
    static func perform(_ device: AVCaptureDevice,
                        _ body: (AVCaptureDevice) throws -> Void) -> Bool {
        let result: Void? = with(device) { d in try body(d) }
        return result != nil
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
