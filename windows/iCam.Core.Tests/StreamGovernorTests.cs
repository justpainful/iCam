using ICam.Core.Media;
using Xunit;

namespace ICam.Core.Tests;

/// <summary>
/// The governor watches one truth — how fast frames arrive against the wall
/// clock — and these tests feed it synthetic truths.
/// </summary>
public class StreamGovernorTests
{
    private const int Target = 8_000_000;

    /// <summary>Feeds a window where media time advances at the given fraction of wall time.</summary>
    private static int? Window(StreamGovernor governor, double mediaRate,
                               int current, long startMs = 0)
    {
        int? decision = null;
        for (var ms = 0L; ms <= 3200; ms += 33)
        {
            governor.OnFrame((ulong)((startMs + ms) * mediaRate * 1000), startMs + ms);
            decision = governor.Evaluate(current, Target) ?? decision;
        }
        return decision;
    }

    [Fact]
    public void AHealthyLinkIsLeftAlone()
    {
        var governor = new StreamGovernor();
        Assert.Null(Window(governor, 1.0, Target));
    }

    [Fact]
    public void AStarvedLinkGetsAskedForLess()
    {
        var governor = new StreamGovernor();
        // Media advancing at 60% of real time: the classic drowning Wi-Fi.
        var decision = Window(governor, 0.6, Target);
        Assert.NotNull(decision);
        Assert.True(decision < Target, $"suggested {decision}, expected a cut");
    }

    [Fact]
    public void TheCutNeverGoesBelowTheFloor()
    {
        var governor = new StreamGovernor();
        var decision = Window(governor, 0.3, StreamGovernor.FloorBitrate);
        // Already at the floor: there is nothing useful left to ask for.
        Assert.Null(decision);
    }

    [Fact]
    public void RecoveryIsSlowerThanTheCut()
    {
        var governor = new StreamGovernor();
        var current = 2_000_000;

        // Nine healthy windows: not enough. The tenth: a raise.
        int? decision = null;
        for (var window = 0; window < 10 && decision is null; window++)
        {
            decision = Window(governor, 1.0, current, window * 4000);
        }
        Assert.NotNull(decision);
        Assert.True(decision > current, "sustained health should raise the bitrate");
        Assert.True(decision < Target, "but not in one leap");
    }

    [Fact]
    public void AStallIsNotAMeasurement()
    {
        var governor = new StreamGovernor();
        // Wall time passes, media time barely moves — a resync, not a rate.
        governor.OnFrame(0, 0);
        governor.OnFrame(100_000, 3500);
        Assert.Null(governor.Evaluate(Target, Target));
    }
}
