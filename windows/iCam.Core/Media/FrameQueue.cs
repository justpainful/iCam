using System.Threading.Channels;

namespace ICam.Core.Media;

/// <summary>One decoded-ready access unit, waiting to be handed to the decoder.</summary>
public readonly record struct QueuedFrame(byte[] Data, ulong PtsUs, bool IsKeyframe);

/// <summary>
/// The hand-off between the network thread and the decoder's sample requests.
///
/// Small on purpose: a live camera preview that buffers is a live camera
/// preview that lags, and a viewer would rather see a dropped frame than watch
/// themselves half a second late.
///
/// The rule that matters is the one that is easy to get wrong: **a waiting
/// reader must never be woken with nothing to give it.** Media Foundation reads
/// an empty sample request as end of stream, so a single spurious wake-up does
/// not drop one frame — it ends the video permanently. A bounded channel with
/// `DropOldest` gets this right by construction: dropping is done by the
/// channel itself, so the count of pending items and the count of pending
/// wake-ups can never drift apart.
/// </summary>
public sealed class FrameQueue
{
    private readonly Channel<QueuedFrame> _channel;
    private long _accepted;
    private long _dropped;

    public FrameQueue(int capacity = 3)
    {
        Capacity = capacity;
        _channel = Channel.CreateBounded<QueuedFrame>(
            new BoundedChannelOptions(capacity)
            {
                FullMode = BoundedChannelFullMode.DropOldest,
                SingleReader = true,
                SingleWriter = false,
            },
            // `DropOldest` reports success even when it evicted something, so
            // the channel is the only party that knows a frame was lost. Asking
            // it beats inferring it from the counts, which goes wrong the moment
            // a reader is draining at the same time.
            _ => Interlocked.Increment(ref _dropped));
    }

    public int Capacity { get; }

    public ulong Accepted => (ulong)Interlocked.Read(ref _accepted);
    public ulong Dropped => (ulong)Interlocked.Read(ref _dropped);

    /// <summary>
    /// Adds a frame, discarding the oldest if the decoder is behind. Never
    /// blocks the network thread.
    /// </summary>
    public void Enqueue(QueuedFrame frame)
    {
        if (_channel.Writer.TryWrite(frame)) Interlocked.Increment(ref _accepted);
        else Interlocked.Increment(ref _dropped);
    }

    /// <summary>
    /// Waits for the next frame. Returns <c>null</c> only when the queue has
    /// been completed or the wait was cancelled — never merely because nothing
    /// has arrived yet.
    /// </summary>
    public async ValueTask<QueuedFrame?> DequeueAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (await _channel.Reader.WaitToReadAsync(cancellationToken).ConfigureAwait(false))
            {
                if (_channel.Reader.TryRead(out var frame)) return frame;
            }
        }
        catch (OperationCanceledException)
        {
            // The pipeline is shutting down.
        }
        return null;
    }

    /// <summary>Discards everything pending, for a format change or a reconnect.</summary>
    public void Clear()
    {
        while (_channel.Reader.TryRead(out _)) { }
    }

    public void Complete() => _channel.Writer.TryComplete();
}
