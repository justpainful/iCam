using ICam.Core.Media;
using ICam.Core.Protocol;
using Windows.Foundation;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Security.Cryptography;

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

    private readonly FrameQueue _frames = new(MaxQueuedFrames);
    private readonly Lock _lock = new();

    private MediaStreamSource? _source;
    private VideoStreamDescriptor? _descriptor;
    private CancellationTokenSource? _sourceLifetime;
    private TypedEventHandler<MediaStreamSource,
        MediaStreamSourceSampleRequestedEventArgs>? _sampleRequested;
    private BitstreamConverter.CodecConfiguration? _configuration;
    private VideoCodec _codec = VideoCodec.H264;
    private uint _width;
    private uint _height;
    private ulong _firstPtsUs;
    private bool _hasFirstPts;
    private bool _awaitingKeyframe = true;

    public ulong FramesRendered { get; private set; }
    public ulong FramesDropped => _frames.Dropped;
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
            // The phone resends this before every IDR, so the common case is a
            // record identical to the one already in force. Rebuilding on it
            // would reset the player and throw away the picture several times a
            // minute, which is why only a real format change gets that far.
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
            _awaitingKeyframe = true;
            _frames.Clear();
        }

        BuildSource();
    }

    /// <summary>Queues one access unit. Called from the network thread.</summary>
    public void Enqueue(VideoFrameHeader header, ReadOnlyMemory<byte> avcc)
    {
        BitstreamConverter.CodecConfiguration configuration;
        lock (_lock)
        {
            // Before the first keyframe there is nothing a decoder can start
            // from, and feeding it inter frames only produces a smear.
            if (_configuration is null || (_awaitingKeyframe && !header.IsKeyframe)) return;
            configuration = _configuration;
            if (header.IsKeyframe) _awaitingKeyframe = false;
        }

        var annexB = BitstreamConverter.AvccToAnnexB(avcc.Span, configuration.NalLengthSize);
        if (annexB.Length == 0) return;

        if (header.IsKeyframe)
        {
            // The parameter sets already went out through SetFormatUserData,
            // and Media Foundation's H.264 decoder is markedly happier when it
            // finds them in the bitstream as well — particularly when it starts
            // mid-stream. Twice a second, a few dozen bytes: cheaper than the
            // black picture it prevents.
            annexB = [.. configuration.AnnexBParameterSets, .. annexB];
        }

        _frames.Enqueue(new QueuedFrame(annexB, header.PtsUs, header.IsKeyframe));
    }

    public void Reset()
    {
        lock (_lock)
        {
            _frames.Clear();
            _hasFirstPts = false;
            _awaitingKeyframe = true;
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

        var lifetime = new CancellationTokenSource();
        var token = lifetime.Token;

        var descriptor = new VideoStreamDescriptor(properties);
        var source = new MediaStreamSource(descriptor)
        {
            // Live, not a file. There is no duration, there is nothing to seek
            // to, and any buffering at all is latency the user will notice.
            BufferTime = TimeSpan.Zero,
            CanSeek = false,
        };

        // Each source carries its own cancellation, so that a request still
        // waiting on the source being replaced can be released without
        // touching the one taking over.
        TypedEventHandler<MediaStreamSource, MediaStreamSourceSampleRequestedEventArgs>
            sampleRequested = (_, args) => OnSampleRequested(args, token);

        source.Starting += OnStarting;
        source.SampleRequested += sampleRequested;
        source.Closed += OnClosed;

        var previous = _source;
        var previousHandler = _sampleRequested;
        var previousLifetime = _sourceLifetime;

        _source = source;
        _descriptor = descriptor;
        _sampleRequested = sampleRequested;
        _sourceLifetime = lifetime;

        if (previous is not null)
        {
            previous.Starting -= OnStarting;
            if (previousHandler is not null) previous.SampleRequested -= previousHandler;
            previous.Closed -= OnClosed;
        }

        // Whatever the old source was waiting for, it is not going to render
        // it. Releasing it here stops it taking the new source's first frame.
        previousLifetime?.Cancel();
        previousLifetime?.Dispose();

        Log.Media.Info($"Decoder ready: {_codec} {_width}x{_height}");
        SourceChanged?.Invoke(source);
    }

    private void OnStarting(MediaStreamSource sender, MediaStreamSourceStartingEventArgs args)
    {
        // A live source starts at zero and simply runs.
        args.Request.SetActualStartPosition(TimeSpan.Zero);
    }

    private async void OnSampleRequested(MediaStreamSourceSampleRequestedEventArgs args,
                                         CancellationToken token)
    {
        var deferral = args.Request.GetDeferral();
        try
        {
            // Leaving `Sample` unset does not mean "nothing this time", it means
            // end of stream: Media Foundation tears the stream down and never
            // asks again. So this waits for as long as the phone takes, and the
            // wait only ends empty when this source is being replaced or the
            // pipeline is closing — both of which really are the end of it.
            if (await _frames.DequeueAsync(token).ConfigureAwait(true) is not { } frame) return;

            ulong offsetUs;
            lock (_lock)
            {
                if (!_hasFirstPts)
                {
                    // Timestamps are relative to the first frame we actually
                    // show, so a session that starts hours into the phone's
                    // uptime does not begin with a huge presentation time.
                    _firstPtsUs = frame.PtsUs;
                    _hasFirstPts = true;
                }
                offsetUs = frame.PtsUs >= _firstPtsUs ? frame.PtsUs - _firstPtsUs : 0;
            }

            // `AsBuffer` is a .NET Framework era extension that modern .NET
            // does not carry; this is the projected equivalent.
            var buffer = CryptographicBuffer.CreateFromByteArray(frame.Data);
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
        _frames.Complete();
        _sourceLifetime?.Cancel();
        _sourceLifetime?.Dispose();
        _sourceLifetime = null;
        _source = null;
        _descriptor = null;
        _sampleRequested = null;
    }
}
