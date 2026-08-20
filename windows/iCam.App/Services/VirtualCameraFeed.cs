using Windows.Media.Playback;

namespace ICam.App.Services;

/// <summary>
/// Sends finished frames on to <c>iCam Camera</c>.
///
/// It no longer decodes or converts anything: <see cref="DecodedFrameSource"/>
/// does that once for both the window and the camera. All that is left here is
/// telling the source what geometry Windows negotiated, and putting each
/// finished frame on the pipe.
/// </summary>
public sealed class VirtualCameraFeed : IDisposable
{
    private readonly VirtualCameraPipe _pipe;
    private readonly DecodedFrameSource _frames;

    public ulong FramesDelivered { get; private set; }
    public ulong FramesSkipped { get; private set; }

    public VirtualCameraFeed(VirtualCameraPipe pipe, DecodedFrameSource frames)
    {
        _pipe = pipe;
        _frames = frames;

        _pipe.FormatRequested += OnFormatRequested;
        _frames.FrameReady += OnFrameReady;
    }

    private void OnFormatRequested(int width, int height, int fps)
    {
        // The camera's negotiated size becomes everybody's working size, so the
        // preview and the outgoing picture can never be different crops of the
        // same frame.
        _frames.SetWorkingSize(width, height);
        Log.Media.Info($"iCam Camera wants {width}x{height} at {fps}");
    }

    private void OnFrameReady(ReadOnlyMemory<byte> nv12, ReadOnlyMemory<byte> display)
    {
        if (!_pipe.IsConnected) return;

        if (_pipe.TryWriteFrame(nv12.Span, _frames.Width, _frames.Height,
                                _frames.Stride, MonotonicMicroseconds()))
        {
            FramesDelivered++;
        }
        else
        {
            FramesSkipped++;
        }
    }

    private static ulong MonotonicMicroseconds() =>
        (ulong)(System.Diagnostics.Stopwatch.GetTimestamp()
                / (double)System.Diagnostics.Stopwatch.Frequency * 1_000_000);

    public void Dispose()
    {
        _pipe.FormatRequested -= OnFormatRequested;
        _frames.FrameReady -= OnFrameReady;
    }
}
