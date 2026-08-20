using System.Collections.Concurrent;
using ICam.Core.Media;
using ICam.Core.Protocol;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Storage.Streams;

namespace ICam.App.Services;

/// <summary>
/// Turns the phone's encoded access units into a picture on screen.
///
/// The decode path is <see cref="MediaStreamSource"/> feeding a
/// <c>MediaPlayer</c>: native, hardware-accelerated by Media Foundation, and
/// with no third-party decoder anywhere. iCam supplies compressed samples and
/// Windows does the rest on the GPU.
///
/// The queue is small on purpose. A live camera preview that buffers is a live
/// camera preview that lags, and a viewer would rather see a dropped frame than
/// watch themselves half a second late.
/// </summary>
public sealed class VideoPipeline : IDisposable
{
    /// <summary>At 30 fps this is a tenth of a second of slack, and no more.</summary>
    private const int MaxQueuedFrames = 3;

    private readonly ConcurrentQueue<(byte[] Data, ulong PtsUs, bool IsKeyframe)> _queue = new();
    private readonly SemaphoreSlim _available = new(0);
    private readonly Lock _lock = new();

    private MediaStreamSource? _source;
    private VideoStreamDescriptor? _descriptor;
    private BitstreamConverter.CodecConfiguration? _configuration;
    private VideoCodec _codec = VideoCodec.H264;
    private uint _width;
    private uint _height;
    private ulong _firstPtsUs;
    private bool _hasFirstPts;

    public ulong FramesRendered { get; private set; }
    public ulong FramesDropped { get; private set; }
    public bool IsReady => _source is not null;

    /// <summary>Raised when a new source is built and the player must be re-pointed.</summary>
    public event Action<MediaStreamSource>? SourceChanged;

    /// <summary>
    /// Called for a frame carrying codec configuration. Until this arrives
    /// there is nothing a decoder could do with the samples, which is why the
    /// phone resends it on every reconnect.
    /// </summary>
    public void SetConfiguration(VideoCodec codec, ReadOnlySpan<byte> record,
                                 uint width, uint height)
    {
        var parsed = BitstreamConverter.ParseConfiguration(codec, record);
        if (parsed is null || parsed.IsEmpty)
        {
            Log.Media.Warn($"Ignoring an unreadable {codec} configuration record");
            return;
        }

        lock (_lock)
        {
            var unchanged = _configuration is not null
                && _codec == codec
                && _width == width
                && _height == height
                && _configuration.AnnexBParameterSets.AsSpan()
                    .SequenceEqual(parsed.AnnexBParameterSets);
            if (unchanged) return;

            _codec = codec;
            _configuration = parsed;
            _width = width;
            _height = height;
            _hasFirstPts = false;
            while (_queue.TryDequeue(out _)) { }
        }

        BuildSource();
    }

    /// <summary>Queues one access unit. Called from the network thread.</summary>
    public void Enqueue(VideoFrameHeader header, ReadOnlyMemory<byte> avcc)
    {
        BitstreamConverter.CodecConfiguration? configuration;
        lock (_lock) configuration = _configuration;
        if (configuration is null) return;

        // Before the first keyframe there is nothing a decoder can start from,
        // and feeding it inter frames only produces a smear.
        if (!_hasFirstPts && !header.IsKeyframe) return;

        var annexB = BitstreamConverter.AvccToAnnexB(avcc.Span, configuration.NalLengthSize);
        if (annexB.Length == 0) return;

        while (_queue.Count >= MaxQueuedFrames && _queue.TryDequeue(out _))
        {
            FramesDropped++;
        }

        _queue.Enqueue((annexB, header.PtsUs, header.IsKeyframe));
        _available.Release();
    }

    public void Reset()
    {
        lock (_lock)
        {
            while (_queue.TryDequeue(out _)) { }
            _hasFirstPts = false;
            _configuration = null;
        }
    }

    private void BuildSource()
    {
        VideoEncodingProperties properties;
        lock (_lock)
        {
            if (_configuration is null) return;

            properties = _codec == VideoCodec.Hevc
                ? VideoEncodingProperties.CreateHevc()
                : VideoEncodingProperties.CreateH264();

            if (_width > 0 && _height > 0)
            {
                properties.Width = _width;
                properties.Height = _height;
            }

            // The sequence header is how Media Foundation learns the stream's
            // parameter sets without having to find them inside the first
            // sample.
            properties.SetFormatUserData(_configuration.AnnexBParameterSets);
        }

        var descriptor = new VideoStreamDescriptor(properties);
        var source = new MediaStreamSource(descriptor)
        {
            // Live, not a file. There is no duration, there is nothing to seek
            // to, and any buffering at all is latency the user will notice.
            BufferTime = TimeSpan.Zero,
            CanSeek = false,
        };

        source.Starting += OnStarting;
        source.SampleRequested += OnSampleRequested;
        source.Closed += OnClosed;

        var previous = _source;
        _source = source;
        _descriptor = descriptor;

        if (previous is not null)
        {
            previous.Starting -= OnStarting;
            previous.SampleRequested -= OnSampleRequested;
            previous.Closed -= OnClosed;
        }

        Log.Media.Info($"Decoder ready: {_codec} {_width}x{_height}");
        SourceChanged?.Invoke(source);
    }

    private void OnStarting(MediaStreamSource sender, MediaStreamSourceStartingEventArgs args)
    {
        // A live source starts at zero and simply runs.
        args.Request.SetActualStartPosition(TimeSpan.Zero);
    }

    private async void OnSampleRequested(MediaStreamSource sender,
                                         MediaStreamSourceSampleRequestedEventArgs args)
    {
        var deferral = args.Request.GetDeferral();
        try
        {
            // Waiting rather than returning an empty request: an empty one ends
            // the stream, and a camera that pauses for half a second must not
            // look like a camera that stopped.
            if (!await _available.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(true))
            {
                return;
            }
            if (!_queue.TryDequeue(out var frame)) return;

            if (!_hasFirstPts)
            {
                // Timestamps are relative to the first frame we actually show,
                // so a session that starts hours into the phone's uptime does
                // not begin with a huge presentation time.
                _firstPtsUs = frame.PtsUs;
                _hasFirstPts = true;
            }

            var offsetUs = frame.PtsUs >= _firstPtsUs ? frame.PtsUs - _firstPtsUs : 0;
            var buffer = frame.Data.AsBuffer();
            var sample = MediaStreamSample.CreateFromBuffer(
                buffer, TimeSpan.FromTicks((long)(offsetUs * 10)));
            sample.KeyFrame = frame.IsKeyframe;
            sample.Discontinuous = FramesRendered == 0;

            args.Request.Sample = sample;
            FramesRendered++;
        }
        catch (Exception error) when (error is ObjectDisposedException or InvalidOperationException)
        {
            // The source was replaced while a request was in flight.
        }
        finally
        {
            deferral.Complete();
        }
    }

    private void OnClosed(MediaStreamSource sender, MediaStreamSourceClosedEventArgs args)
    {
        Log.Media.Info($"Decoder closed: {args.Request.Reason}");
    }

    public void Dispose()
    {
        Reset();
        _available.Dispose();
        _source = null;
        _descriptor = null;
    }
}
