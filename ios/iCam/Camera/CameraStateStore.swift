import Foundation

/// The single source of truth for camera settings.
///
/// Mutations arrive from two places — the phone's own interface and the PC —
/// and they can arrive at the same time. The store serialises them, lets the
/// owner clamp the result to what the hardware really supports, bumps a
/// version, and notifies. Nobody else keeps a state they believe in.
final class CameraStateStore {

    /// Called on the store's queue after every accepted mutation, with the
    /// state as it actually ended up.
    var onChange: ((CameraState) -> Void)?

    private var _state: CameraState
    private let lock = NSLock()

    init(initial: CameraState = CameraState()) {
        _state = initial
    }

    var state: CameraState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    var version: UInt64 { state.version }

    /// Applies a mutation.
    ///
    /// - Parameters:
    ///   - mutation: only the keys the caller touched.
    ///   - base: the version the caller was looking at. A stale base is not an
    ///     error — the mutation still applies, but only to its own keys, so an
    ///     out-of-date PC slider cannot revert an unrelated setting the user
    ///     just changed on the phone.
    ///   - reconcile: the owner's chance to clamp to live hardware limits and
    ///     push the values to the device. It receives the candidate state and
    ///     may edit it in place.
    /// - Returns: the state that is now authoritative.
    @discardableResult
    func apply(_ mutation: CameraMutation,
               base: UInt64? = nil,
               reconcile: (inout CameraState) -> Void) -> CameraState {
        lock.lock()
        var candidate = _state
        mutation.apply(to: &candidate)
        lock.unlock()

        // Reconciliation talks to the capture device, which can block for a few
        // milliseconds. Doing it outside the lock keeps `state` readable from
        // the interface the whole time.
        reconcile(&candidate)

        lock.lock()
        candidate.version = _state.version &+ 1
        _state = candidate
        let published = _state
        lock.unlock()

        if let base, base != published.version &- 1 {
            Log.camera.debug("Applied a mutation from an older state version \(base, privacy: .public)")
        }
        onChange?(published)
        return published
    }

    /// Replaces the whole state without going through a mutation. Used when the
    /// engine reconfigures itself — a new lens, a new format — and the resulting
    /// state is discovered rather than requested.
    @discardableResult
    func replace(with newState: CameraState) -> CameraState {
        lock.lock()
        var next = newState
        next.version = _state.version &+ 1
        _state = next
        let published = _state
        lock.unlock()
        onChange?(published)
        return published
    }

    /// Reads and edits under one lock. For values the hardware reports back
    /// on its own, such as the current lens position while autofocusing.
    @discardableResult
    func update(_ body: (inout CameraState) -> Void) -> CameraState {
        lock.lock()
        var next = _state
        body(&next)
        next.version = _state.version &+ 1
        _state = next
        let published = _state
        lock.unlock()
        onChange?(published)
        return published
    }

    /// Updates values that came from the hardware itself without bumping the
    /// version. Autofocus reporting a new lens position is not a user edit, and
    /// treating it as one would make every PC slider fight the sensor.
    func observe(_ body: (inout CameraState) -> Void) {
        lock.lock()
        body(&_state)
        let published = _state
        lock.unlock()
        onChange?(published)
    }
}
