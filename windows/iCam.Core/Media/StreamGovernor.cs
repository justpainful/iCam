namespace ICam.Core.Media;

/// <summary>
/// Receiver-side bitrate governance: notices that the link cannot carry the
/// stream, and says what the bitrate should become.
///
/// The phone has its own send-side adaptation, but the receiver holds the one
/// measurement that cannot lie: how fast frames actually arrive. When a link
/// delivers 800 kbit/s of an 8 Mbit/s stream, TCP loses nothing — it just
/// takes ten seconds to deliver each second of video, and the sender's queue
/// wears the difference as latency. Here that shows up simply: the media time
/// spanned by arriving frames advances slower than the wall clock. Ratio
/// above one means congestion; the response is to ask the phone for less.
///
/// Deliberately transport-agnostic and clock-agnostic: it is handed media
/// timestamps and wall milliseconds and returns bitrate suggestions, which is
/// what makes it testable without a network.
/// </summary>
public sealed class StreamGovernor
{
    /// <summary>Long enough to see through keyframe bursts and Wi-Fi jitter.</summary>
    private const long WindowMs = 3000;

    /// <summary>Arrival running >12% slower than real time is congestion, not noise.</summary>
    private const double CongestedRatio = 1.12;

    /// <summary>Arrival keeping within 3% of real time is a healthy link.</summary>
    private const double HealthyRatio = 1.03;

    /// <summary>Windows of sustained health before the bitrate steps back up.</summary>
    private const int HealthyWindowsBeforeRaise = 10;

    /// <summary>Below this the picture is unusable anyway; congestion means something else.</summary>
    public const int FloorBitrate = 1_200_000;

    private ulong _firstPtsUs;
    private ulong _lastPtsUs;
    private long _firstWallMs;
    private long _lastWallMs;
    private bool _hasWindow;
    private int _healthyWindows;

    /// <summary>Feeds one arrived video frame. Cheap; called per frame.</summary>
    public void OnFrame(ulong ptsUs, long wallMs)
    {
        if (!_hasWindow)
        {
            _hasWindow = true;
            _firstPtsUs = ptsUs;
            _firstWallMs = wallMs;
        }
        _lastPtsUs = ptsUs;
        _lastWallMs = wallMs;
    }

    /// <summary>
    /// Called whenever convenient — per frame is fine. Returns the bitrate the
    /// stream should move to, or null to leave it alone.
    /// </summary>
    /// <param name="currentBitrate">The bitrate in force right now.</param>
    /// <param name="targetBitrate">What the user actually asked for.</param>
    public int? Evaluate(int currentBitrate, int targetBitrate)
    {
        if (!_hasWindow || _lastWallMs - _firstWallMs < WindowMs) return null;

        var wallMs = _lastWallMs - _firstWallMs;
        var mediaMs = (long)((_lastPtsUs - _firstPtsUs) / 1000);
        Reset();

        // A window with almost no media in it is a stall or a resync, not a
        // measurement. Skip it rather than divide by nearly zero.
        if (mediaMs < 500) return null;

        var ratio = (double)wallMs / mediaMs;

        if (ratio > CongestedRatio)
        {
            _healthyWindows = 0;
            var reduced = Math.Max(FloorBitrate, currentBitrate * 65 / 100);
            return reduced < currentBitrate ? reduced : null;
        }

        if (ratio <= HealthyRatio && currentBitrate < targetBitrate)
        {
            // Recovery is deliberately much slower than the cut: congestion
            // costs the user seconds of latency, a conservative bitrate only
            // costs a little sharpness.
            if (++_healthyWindows >= HealthyWindowsBeforeRaise)
            {
                _healthyWindows = 0;
                return Math.Min(targetBitrate, Math.Max(currentBitrate * 115 / 100,
                                                        currentBitrate + 200_000));
            }
        }

        return null;
    }

    /// <summary>The stream restarted or reconfigured; history means nothing now.</summary>
    public void Reset()
    {
        _hasWindow = false;
    }
}
