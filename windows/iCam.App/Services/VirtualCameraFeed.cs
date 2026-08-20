using ICam.Core.Media;
using Microsoft.Graphics.Canvas;
using Windows.Graphics.Imaging;
using Windows.Media.Playback;

namespace ICam.App.Services;

/// <summary>
/// Carries decoded iPhone frames to <c>iCam Camera</c>.
///
/// It reads from the same <see cref="MediaPlayer"/> that draws the preview,
/// through frame-server mode. That matters: the phone's stream is decoded
/// **once**, on the GPU, and both the window and the virtual camera are fed
/// from it. Decoding twice would double the cost of the one part of this
/// pipeline that is genuinely expensive.
///
/// The frame is copied into a render target sized to exactly what the Frame
/// Server asked for, so Direct2D does the scaling on the GPU and the NV12
/// conversion never has to resample.
/// </summary>
public sealed class VirtualCameraFeed : IDisposable
{
    private readonly VirtualCameraPipe _pipe;
    private readonly Lock _lock = new();

    private MediaPlayer? _player;
    private CanvasDevice? _device;
    private CanvasRenderTarget? _target;
    private byte[] _nv12 = [];

    private int _width;
    private int _height;
    private int _stride;

    public ulong FramesDelivered { get; private set; }
    public ulong FramesSkipped { get; private set; }

    /// <summary>
    /// The image controls to apply on the way out, or <c>null</c> for the
    /// picture exactly as the phone sent it. It belongs to the iPhone the
    /// frames are coming from, so it is set alongside the player.
    /// </summary>
    public ImageAdjuster? Image { get; set; }

    public VirtualCameraFeed(VirtualCameraPipe pipe)
    {
        _pipe = pipe;
        _pipe.FormatRequested += OnFormatRequested;
    }

    /// <summary>
    /// Starts reading from a player. Passing <c>null</c> detaches, which is
    /// what happens when the iPhone goes away: the virtual camera keeps
    /// running and falls back to its own holding card.
    /// </summary>
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

            // Frame-server mode hands us each decoded frame instead of drawing
            // it. The MediaPlayerElement still renders, because it draws from
            // the same player.
            _player.IsVideoFrameServerEnabled = true;
            _player.VideoFrameAvailable += OnVideoFrameAvailable;
        }
    }

    private void OnFormatRequested(int width, int height, int fps)
    {
        lock (_lock)
        {
            if (_width == width && _height == height) return;

            _width = width;
            _height = height;
            _stride = Nv12Encoder.DefaultStride(width);
            _nv12 = new byte[Nv12Encoder.RequiredBytes(_stride, height)];

            _target?.Dispose();
            _target = null;
            Log.Media.Info($"iCam Camera wants {width}x{height} at {fps}");
        }
    }

    private void OnVideoFrameAvailable(MediaPlayer sender, object args)
    {
        // Never block the decoder. A frame that cannot be delivered right now
        // is dropped: a call would rather skip a frame than fall behind its
        // own audio, and the next one is thirty milliseconds away.
        if (!Monitor.TryEnter(_lock))
        {
            FramesSkipped++;
            return;
        }

        try
        {
            if (!_pipe.IsConnected || _width == 0 || _height == 0) return;

            _device ??= CanvasDevice.GetSharedDevice();
            _target ??= new CanvasRenderTarget(_device, _width, _height, 96,
                                               Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized,
                                               CanvasAlphaMode.Ignore);

            // Scaling happens here, on the GPU, as part of the copy.
            sender.CopyFrameToVideoSurface(_target);

            var bgra = _target.GetPixelBytes();
            Nv12Encoder.Convert(bgra, _width * 4, _nv12, _stride, _width, _height);

            // Last thing before the frame leaves the computer. Brightness and
            // the rest belong to the derived outputs and to nothing else — the
            // recording on the iPhone was written long before this point and
            // has never heard of them.
            Image?.Apply(_nv12, _width, _height, _stride);

            if (_pipe.TryWriteFrame(_nv12, _width, _height, _stride,
                                    MonotonicMicroseconds()))
            {
                FramesDelivered++;
            }
            else
            {
                FramesSkipped++;
            }
        }
        catch (Exception error) when (error is ObjectDisposedException
                                            or ArgumentException
                                            or System.Runtime.InteropServices.COMException)
        {
            // The device was lost, or the player was torn down mid-frame.
            // Rebuilt on the next frame rather than taking the app down.
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

    private static ulong MonotonicMicroseconds() =>
        (ulong)(System.Diagnostics.Stopwatch.GetTimestamp()
                / (double)System.Diagnostics.Stopwatch.Frequency * 1_000_000);

    public void Dispose()
    {
        _pipe.FormatRequested -= OnFormatRequested;
        Attach(null);
        lock (_lock)
        {
            _target?.Dispose();
            _target = null;
            _device = null;
        }
    }
}
