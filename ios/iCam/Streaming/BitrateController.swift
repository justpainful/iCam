import Foundation

/// Decides what bitrate the stream should run at, from link feedback.
///
/// The rule that matters most here is **hysteresis**. A controller that reacts
/// to every sample oscillates, and the user sees the picture pumping between
/// sharp and soft every few seconds — which reads as far worse than simply
/// sitting at the lower rate. So: drop fast, recover slowly, and never move
/// unless the change is worth making.
final class BitrateController {

    struct Feedback {
        /// Round-trip time in microseconds, from the time-sync pings.
        var rttUs: UInt64
        /// Bytes the transport has accepted but not yet put on the wire.
        var pendingBytes: Int
        /// Frames the encoder dropped since the last sample.
        var encoderDrops: UInt64
        /// Frames the transport dropped since the last sample.
        var transportDrops: UInt64
    }

    struct Decision: Equatable {
        var bitrate: Int
        /// Set when the change is large enough to be worth telling the user.
        var userVisibleReason: String?
    }

    private let minimumBitrate: Int
    private var maximumBitrate: Int
    private var current: Int

    /// Consecutive good samples needed before stepping back up.
    private let recoverySamplesNeeded = 8
    private var goodSamples = 0
    private var lastChange = Date.distantPast
    /// No two changes closer together than this, in either direction.
    private let minimumIntervalSeconds: TimeInterval = 2

    init(profile: StreamProfile) {
        current = profile.bitrate
        maximumBitrate = profile.bitrate
        minimumBitrate = max(400_000, profile.bitrate / 8)
    }

    var bitrate: Int { current }

    /// The user (or the thermal manager) changed the ceiling.
    func setCeiling(_ ceiling: Int) {
        maximumBitrate = max(minimumBitrate, ceiling)
        if current > maximumBitrate {
            current = maximumBitrate
            lastChange = Date()
        }
    }

    /// Feed one sample, roughly once a second.
    func update(_ feedback: Feedback) -> Decision? {
        let congested = feedback.pendingBytes > current / 8 / 2   // half a second queued
            || feedback.transportDrops > 0
            || feedback.rttUs > 250_000

        let strained = feedback.pendingBytes > current / 8 / 8    // an eighth of a second
            || feedback.encoderDrops > 0
            || feedback.rttUs > 120_000

        guard Date().timeIntervalSince(lastChange) >= minimumIntervalSeconds else { return nil }

        if congested {
            goodSamples = 0
            let next = max(minimumBitrate, Int(Double(current) * 0.6))
            guard next < current else { return nil }
            current = next
            lastChange = Date()
            Log.stream.notice("Lowered the stream to \(next / 1000, privacy: .public) kbit/s")
            return Decision(bitrate: next, userVisibleReason: nil)
        }

        if strained {
            goodSamples = 0
            let next = max(minimumBitrate, Int(Double(current) * 0.85))
            guard next < current else { return nil }
            current = next
            lastChange = Date()
            return Decision(bitrate: next, userVisibleReason: nil)
        }

        goodSamples += 1
        guard goodSamples >= recoverySamplesNeeded, current < maximumBitrate else { return nil }
        goodSamples = 0
        // Recovery is a small step, not a jump back to the ceiling: a link that
        // just recovered is the least trustworthy moment to gamble on.
        let next = min(maximumBitrate, Int(Double(current) * 1.2))
        guard next > current else { return nil }
        current = next
        lastChange = Date()
        return Decision(bitrate: next, userVisibleReason: nil)
    }
}
