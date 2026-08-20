import Foundation
import CoreMedia

/// A single monotonic time base for the whole app, in microseconds.
///
/// Every timestamp that crosses the wire, lands in a recording, or feeds the
/// A/V sync logic comes from here. `Date` is never used for timing: it jumps
/// when the user changes the clock, when NTP corrects, and across DST.
enum MonotonicClock {

    /// Microseconds since an arbitrary, fixed boot-relative origin.
    /// Continues to advance while the device is asleep.
    static func nowUs() -> UInt64 {
        let raw = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        return raw / 1_000
    }

    /// The same domain that `CMSampleBuffer` presentation timestamps live in,
    /// so capture timestamps and wire timestamps are directly comparable.
    static func hostTimeUs() -> UInt64 {
        UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1_000_000)
    }

    static func us(from time: CMTime) -> UInt64 {
        guard time.isValid, time.seconds.isFinite, time.seconds > 0 else { return 0 }
        return UInt64(time.seconds * 1_000_000)
    }

    static func cmTime(fromUs us: UInt64) -> CMTime {
        CMTime(value: CMTimeValue(us), timescale: 1_000_000)
    }
}

/// Formats a duration for the recording readout: `04:18` or `1:04:18`.
func formatElapsed(_ microseconds: UInt64) -> String {
    let total = Int(microseconds / 1_000_000)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}
