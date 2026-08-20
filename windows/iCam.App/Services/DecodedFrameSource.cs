using ICam.Core.Media;
using Microsoft.Graphics.Canvas;
using Windows.Media.Playback;

namespace ICam.App.Services;

/// <summary>
/// One decode, one grade, two consumers.
///
/// Frames arrive from the player in frame-server mode, are scaled on the GPU to
/// the working size, converted to NV12, and graded once. Both the window and
/// <c>iCam Camera</c> then read that same result — which is why the preview
/// shows what the people on the call see rather than a prettier picture that
/// only exists locally, down to the chroma subsampling they receive.
///
/// It also means the expensive part happens once. Decoding, scaling and grading
/// separately for the window and the camera would double the only genuinely
/// costly step in this pipeline.
/// </summary>
public sealed class DecodedFrameSource : IDisposable
{
    /// <summary>What the preview falls back to when no consumer has asked.</summary>
    private const int FallbackWidth = 1280;
    private const int FallbackHeight = 720;

    private readonly Lock _lock = new();

    private MediaPlayer? _player;
    private CanvasDevice? _device;
    private CanvasRenderTarget? _target;

    private byte[] _nv12 = [];
    private byte[] _display = [];
    private int _width;
    private int _height;
    private int _stride;

    public ImageAdjuster? Image { get; set; }

    public ulong FramesProduced { get; private set; }
    public ulong FramesSkipped { get; private set; }

    public int Width => _width;
    public int Height => _height;
    public int Stride => _stride;

    /// <summary>
    /// A finished frame: NV12 as the camera will receive it, and the same
    /// picture as BGRA for drawing. Raised on the decoder's thread, never the
    /// interface thread.
    /// </summary>
    public event Action<ReadOnlyMemory<byte>, ReadOnlyMemory<byte>>? FrameReady;

    public void Attach(MediaPlayer? player)
    {
        lock (_lock)
        {
            if (_player is not null)
            {
                _player.VideoFrameAvailable -= OnVideoFrameAvailable;
                _player.IsVideoFrameServerEnabled = false;
            }

            _player = player;
            if (_player is null) return;

            // Frame-server mode hands each decoded frame to the application
            // instead of presenting it. That is exactly what is wanted here:
            // the window draws the frame itself, from this, so nothing depends
            // on the player's own presentation.
            _player.IsVideoFrameServerEnabled = true;
            _player.VideoFrameAvailable += OnVideoFrameAvailable;
        }
    }

    /// <summary>
    /// Sets the geometry every consumer works in. <c>iCam Camera</c> calls this
    /// with whatever Windows negotiated; the preview simply follows, so the two
    /// can never drift apart.
    /// </summary>
    public void SetWorkingSize(int width, int height)
    {
        if (width <= 1 || height <= 1) return;

        lock (_lock)
        {
            if (_width == width && _height == height) return;

            _width = width;
            _height = height;
            _stride = Nv12Encoder.DefaultStride(width);
            _nv12 = new byte[Nv12Encoder.RequiredBytes(_stride, height)];
            _display = new byte[Nv12Decoder.RequiredBytes(width, height)];

            _target?.Dispose();
            _target = null;
            Log.Media.Info($"Working size is now {width}x{height}");
        }
    }

    private void OnVideoFrameAvailable(MediaPlayer sender, object args)
    {
        // Never block the decoder. A frame that cannot be handled right now is
        // dropped: the next one is thirty milliseconds away, and a call would
        // rather skip a frame than fall behind its own audio.
        if (!Monitor.TryEnter(_lock))
        {
            FramesSkipped++;
            return;
        }

        try
        {
            if (_width == 0) SetWorkingSizeLocked(FallbackWidth, FallbackHeight);

            _device ??= CanvasDevice.GetSharedDevice();
            _target ??= new CanvasRenderTarget(
                _device, _width, _height, 96,
                Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized,
                CanvasAlphaMode.Ignore);

            // Scaling happens here, on the GPU, as part of the copy.
            sender.CopyFrameToVideoSurface(_target);

            var bgra = _target.GetPixelBytes();
            Nv12Encoder.Convert(bgra, _width * 4, _nv12, _stride, _width, _height);

            // Graded once, before either consumer sees it. The recording on the
            // iPhone was written long before this point and has never heard of
            // any of these controls.
            Image?.Apply(_nv12, _width, _height, _stride);

            Nv12Decoder.Convert(_nv12, _stride, _display, _width * 4, _width, _height);

            FramesProduced++;
            FrameReady?.Invoke(_nv12, _display);
        }
        catch (Exception error) when (error is ObjectDisposedException
                                            or ArgumentException
                                            or System.Runtime.InteropServices.COMException)
        {
            // The device was lost, or the player was torn down mid-frame.
            // Rebuilt on the next frame rather than taking the application down.
            _target?.Dispose();
            _target = null;
            _device = null;
            FramesSkipped++;
        }
        finally
        {
            Monitor.Exit(_lock);
        }
    }

    private void SetWorkingSizeLocked(int width, int height)
    {
        _width = width;
        _height = height;
        _stride = Nv12Encoder.DefaultStride(width);
        _nv12 = new byte[Nv12Encoder.RequiredBytes(_stride, height)];
        _display = new byte[Nv12Decoder.RequiredBytes(width, height)];
    }

    public void Dispose()
    {
        Attach(null);
        lock (_lock)
        {
            _target?.Dispose();
            _target = null;
            _device = null;
        }
    }
}
