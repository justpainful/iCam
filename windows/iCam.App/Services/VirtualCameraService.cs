using Windows.Media.Playback;

namespace ICam.App.Services;

/// <summary>
/// <c>iCam Camera</c> — the device other Windows applications see.
///
/// Three pieces, deliberately separate:
///
/// - <see cref="VirtualCameraHost"/> registers the camera with Windows and
///   holds it open.
/// - <see cref="VirtualCameraPipe"/> is the link to the DLL that Windows loads
///   into its Frame Server.
/// - <see cref="VirtualCameraFeed"/> turns decoded iPhone frames into NV12 and
///   pushes them down that pipe.
///
/// The important property is that they do not depend on each other's state. The
/// camera can be registered with no iPhone connected, the pipe can be open with
/// nothing to send, and in both cases the DLL draws its own holding card. A
/// consumer never sees a black frame or an error, only a picture that explains
/// itself. See <c>docs/VIRTUAL-CAMERA.md</c>.
/// </summary>
public sealed class VirtualCameraService : IAsyncDisposable
{
    private readonly VirtualCameraHost _host = new();
    private readonly VirtualCameraPipe _pipe = new();
    private readonly VirtualCameraFeed _feed;

    public VirtualCameraService()
    {
        _feed = new VirtualCameraFeed(_pipe);
        _host.StateChanged += () => StateChanged?.Invoke();
        _pipe.ConnectionChanged += _ => StateChanged?.Invoke();
    }

    public event Action? StateChanged;

    public bool IsRunning => _host.IsRunning;

    /// <summary>True once Windows has actually opened the camera in some app.</summary>
    public bool IsInUse => _pipe.IsConnected;

    public string? LastError => _host.LastError;

    public static VirtualCameraHost.InstallState Installation =>
        VirtualCameraHost.CheckInstallation();

    public static bool IsSupportedByThisWindows => VirtualCameraHost.IsSupportedByThisWindows;

    public ulong FramesDelivered => _feed.FramesDelivered;
    public ulong FramesSkipped => _feed.FramesSkipped;

    /// <summary>
    /// Makes iCam Camera available. Safe to call when it is not installed: it
    /// reports why through <see cref="LastError"/> rather than throwing.
    /// </summary>
    public bool Start()
    {
        _pipe.Start();
        return _host.Start();
    }

    public void Stop()
    {
        _feed.Attach(null);
        _host.Stop();
    }

    /// <summary>
    /// Points the camera at a decoded stream, with the image controls that
    /// belong to the iPhone it is coming from. <c>null</c> detaches, and the
    /// DLL falls back to its holding card — which is why losing the iPhone
    /// does not remove the camera from a call in progress.
    /// </summary>
    public void SetSource(MediaPlayer? player, ICam.Core.Media.ImageAdjuster? image = null)
    {
        // Set before attaching, so the very first frame out is already graded
        // rather than one frame of the raw picture slipping through.
        _feed.Image = image;
        _feed.Attach(player);
    }

    public async ValueTask DisposeAsync()
    {
        _feed.Dispose();
        _host.Dispose();
        await _pipe.DisposeAsync().ConfigureAwait(false);
    }
}
