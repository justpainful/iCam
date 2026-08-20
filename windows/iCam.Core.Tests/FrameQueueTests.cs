using ICam.Core.Media;
using Xunit;

namespace ICam.Core.Tests;

/// <summary>
/// The queue between the network thread and the decoder's sample requests.
///
/// These tests exist because of one specific failure: the hand-off this
/// replaced released a semaphore per accepted frame and never decremented it
/// for a dropped one, so the wake-up count drifted above the item count. A
/// reader then woke with nothing to hand back, and Media Foundation reads a
/// sample request left empty as end of stream — so the preview did not stutter,
/// it stopped, permanently, and no later frame could restart it.
/// </summary>
public class FrameQueueTests
{
    private static QueuedFrame Frame(ulong pts, bool keyframe = false) =>
        new([0x00, 0x00, 0x00, 0x01, 0x65], pts, keyframe);

    /// <summary>How long to let a read sit before calling it genuinely blocked.</summary>
    private static readonly TimeSpan Settle = TimeSpan.FromMilliseconds(100);

    [Fact]
    public async Task ADrainedQueueLeavesTheNextReadWaitingRatherThanEndingTheStream()
    {
        // Ten frames into three slots is the exact shape that used to leave
        // seven surplus wake-ups behind.
        var queue = new FrameQueue(capacity: 3);
        for (var i = 0ul; i < 10; i++) queue.Enqueue(Frame(i));

        for (var i = 0; i < 3; i++) Assert.NotNull(await queue.DequeueAsync(default));

        var pending = queue.DequeueAsync(default).AsTask();
        await Task.Delay(Settle);
        Assert.False(pending.IsCompleted);

        queue.Enqueue(Frame(99));
        Assert.Equal(99ul, (await pending)!.Value.PtsUs);
    }

    [Fact]
    public async Task DroppingUnderPressureKeepsTheNewestFrames()
    {
        // Dropping the oldest is the whole point: a viewer would rather see a
        // gap than watch themselves half a second late.
        var queue = new FrameQueue(capacity: 3);
        for (var i = 0ul; i < 10; i++) queue.Enqueue(Frame(i));

        Assert.Equal(10ul, queue.Accepted);
        Assert.Equal(7ul, queue.Dropped);

        var seen = new List<ulong>();
        for (var i = 0; i < 3; i++) seen.Add((await queue.DequeueAsync(default))!.Value.PtsUs);
        Assert.Equal<ulong>([7, 8, 9], seen);
    }

    [Fact]
    public async Task TheCapacityAskedForIsTheCapacityUsed()
    {
        var queue = new FrameQueue(capacity: 2);
        Assert.Equal(2, queue.Capacity);

        for (var i = 0ul; i < 5; i++) queue.Enqueue(Frame(i));
        Assert.Equal(3ul, queue.Dropped);

        Assert.Equal(3ul, (await queue.DequeueAsync(default))!.Value.PtsUs);
        Assert.Equal(4ul, (await queue.DequeueAsync(default))!.Value.PtsUs);
    }

    [Fact]
    public async Task EveryFrameIsEitherDeliveredOrCountedAsDropped()
    {
        // A writer flooding a reader that is keeping up only intermittently:
        // the arrangement in which the old hand-off drifted. If a single read
        // ever came back empty, the loop below would end early and the tally
        // would not close.
        var queue = new FrameQueue(capacity: 3);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        const int total = 20_000;

        var writer = Task.Run(() =>
        {
            for (var i = 0ul; i < total; i++) queue.Enqueue(Frame(i));
            queue.Complete();
        });

        ulong delivered = 0;
        ulong previousPts = 0;
        while (await queue.DequeueAsync(deadline.Token) is { } frame)
        {
            // Order survives the dropping, so a frame older than the last one
            // delivered would mean the queue handed back something stale.
            if (delivered > 0) Assert.True(frame.PtsUs > previousPts);
            previousPts = frame.PtsUs;
            delivered++;
        }
        await writer;

        Assert.False(deadline.IsCancellationRequested);
        Assert.Equal((ulong)total, queue.Accepted);
        Assert.Equal((ulong)total, delivered + queue.Dropped);
    }

    [Fact]
    public async Task ClearDiscardsWhatIsPendingAndLeavesNoPhantomWakeUpBehind()
    {
        var queue = new FrameQueue(capacity: 3);
        queue.Enqueue(Frame(1));
        queue.Enqueue(Frame(2));

        queue.Clear();

        var pending = queue.DequeueAsync(default).AsTask();
        await Task.Delay(Settle);
        Assert.False(pending.IsCompleted);

        queue.Enqueue(Frame(3));
        Assert.Equal(3ul, (await pending)!.Value.PtsUs);
    }

    [Fact]
    public async Task ClearOnAQueueNobodyIsReadingIsHarmless()
    {
        var queue = new FrameQueue(capacity: 3);
        queue.Clear();
        queue.Clear();

        queue.Enqueue(Frame(1));
        Assert.Equal(1ul, (await queue.DequeueAsync(default))!.Value.PtsUs);
    }

    [Fact]
    public async Task CompleteHandsBackWhatIsLeftBeforeReportingTheEnd()
    {
        var queue = new FrameQueue(capacity: 3);
        queue.Enqueue(Frame(1));
        queue.Enqueue(Frame(2, keyframe: true));

        queue.Complete();

        var first = await queue.DequeueAsync(default);
        Assert.Equal(1ul, first!.Value.PtsUs);

        var second = await queue.DequeueAsync(default);
        Assert.Equal(2ul, second!.Value.PtsUs);
        Assert.True(second.Value.IsKeyframe);

        // Only now, with nothing left and no more coming, is the end real.
        Assert.Null(await queue.DequeueAsync(default));
        Assert.Null(await queue.DequeueAsync(default));
    }

    [Fact]
    public async Task CompleteReleasesAReaderThatIsAlreadyWaiting()
    {
        var queue = new FrameQueue(capacity: 3);
        var pending = queue.DequeueAsync(default).AsTask();
        await Task.Delay(Settle);
        Assert.False(pending.IsCompleted);

        queue.Complete();
        Assert.Null(await pending);
    }

    [Fact]
    public async Task WritesAfterCompleteAreRefusedAndCounted()
    {
        var queue = new FrameQueue(capacity: 3);
        queue.Complete();

        queue.Enqueue(Frame(1));
        Assert.Equal(0ul, queue.Accepted);
        Assert.Equal(1ul, queue.Dropped);
        Assert.Null(await queue.DequeueAsync(default));
    }

    [Fact]
    public async Task ACancelledWaitReportsTheEndRatherThanThrowing()
    {
        // Cancellation is how a source being replaced releases the request
        // still waiting on it, so it has to arrive as an ordinary end.
        var queue = new FrameQueue(capacity: 3);
        using var cancellation = new CancellationTokenSource();

        var pending = queue.DequeueAsync(cancellation.Token).AsTask();
        await Task.Delay(Settle);
        Assert.False(pending.IsCompleted);

        await cancellation.CancelAsync();
        Assert.Null(await pending);
    }

    [Fact]
    public async Task AnAlreadyCancelledTokenDoesNotConsumeAFrame()
    {
        var queue = new FrameQueue(capacity: 3);
        queue.Enqueue(Frame(1));

        using var cancellation = new CancellationTokenSource();
        await cancellation.CancelAsync();
        Assert.Null(await queue.DequeueAsync(cancellation.Token));

        // The frame belongs to whoever reads next, not to the reader that left.
        Assert.Equal(1ul, (await queue.DequeueAsync(default))!.Value.PtsUs);
    }

    [Fact]
    public async Task ManyWritersCannotDriveTheWakeUpCountAboveTheItemCount()
    {
        // The drift the old hand-off suffered was a counting bug, and counting
        // bugs surface under contention. Eight threads writing at once, one
        // reader draining, and the same tally has to close.
        var queue = new FrameQueue(capacity: 3);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        const int writers = 8;
        const int perWriter = 2_000;

        var writing = Task.WhenAll(Enumerable.Range(0, writers).Select(w => Task.Run(() =>
        {
            for (var i = 0; i < perWriter; i++)
            {
                queue.Enqueue(Frame((ulong)(w * perWriter + i)));
            }
        })));

        var reading = Task.Run(async () =>
        {
            ulong count = 0;
            while (await queue.DequeueAsync(deadline.Token) is not null) count++;
            return count;
        });

        await writing;
        queue.Complete();
        var delivered = await reading;

        Assert.False(deadline.IsCancellationRequested);
        Assert.Equal((ulong)(writers * perWriter), queue.Accepted);
        Assert.Equal((ulong)(writers * perWriter), delivered + queue.Dropped);
    }
}
