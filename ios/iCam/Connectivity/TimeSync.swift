import Foundation

/// Estimates the offset between this iPhone's monotonic clock and the PC's.
///
/// Two devices' clocks are never aligned, and assuming they are shows up as A/V
/// drift, mismatched dual recordings, and missing-segment ranges that do not
/// line up. The estimator is the same idea as NTP, kept small: sample, keep the
/// lowest-latency samples, take their median.
final class TimeSync {

    private struct Sample {
        var rttUs: UInt64
        var offsetUs: Int64
    }

    private var samples: [Sample] = []
    private let maximumSamples = 8
    private let lock = NSLock()

    private(set) var isSynchronised = false

    /// Signed offset to add to a local timestamp to express it in the peer's
    /// clock. Zero until the first exchange completes.
    var offsetUs: Int64 {
        lock.lock(); defer { lock.unlock() }
        guard !samples.isEmpty else { return 0 }
        let offsets = samples.map(\.offsetUs).sorted()
        return offsets[offsets.count / 2]
    }

    /// Best round-trip estimate, which is also the honest latency figure to show
    /// in diagnostics.
    var rttUs: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return samples.map(\.rttUs).min() ?? 0
    }

    /// Feeds one completed ping/pong exchange.
    ///
    /// - Parameters:
    ///   - t1: local send time
    ///   - t2: peer receive time
    ///   - t3: peer send time
    ///   - t4: local receive time
    func record(t1: UInt64, t2: UInt64, t3: UInt64, t4: UInt64) {
        guard t4 >= t1, t3 >= t2 else { return }
        let rtt = (t4 - t1) - (t3 - t2)
        // ((t2 - t1) + (t3 - t4)) / 2, computed without underflowing unsigned
        // arithmetic on the way.
        let offset = ((Int64(t2) - Int64(t1)) + (Int64(t3) - Int64(t4))) / 2

        lock.lock()
        samples.append(Sample(rttUs: rtt, offsetUs: offset))
        // Keep only the fastest exchanges: a sample that spent time in a queue
        // carries that queue's delay in its offset estimate.
        samples.sort { $0.rttUs < $1.rttUs }
        if samples.count > maximumSamples { samples.removeLast(samples.count - maximumSamples) }
        isSynchronised = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        isSynchronised = false
        lock.unlock()
    }

    /// How often to ping. Frequent while an estimate is still forming, then
    /// rarely — a stable local link does not need constant traffic, and each
    /// ping keeps the radio awake.
    static func interval(sinceStart seconds: TimeInterval) -> TimeInterval {
        seconds < 30 ? 2 : 15
    }

    func peerTime(forLocalUs local: UInt64) -> UInt64 {
        let shifted = Int64(local) + offsetUs
        return shifted > 0 ? UInt64(shifted) : 0
    }

    func localTime(forPeerUs peer: UInt64) -> UInt64 {
        let shifted = Int64(peer) - offsetUs
        return shifted > 0 ? UInt64(shifted) : 0
    }
}
