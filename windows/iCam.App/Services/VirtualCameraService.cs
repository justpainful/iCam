using ICam.Core.Protocol;

namespace ICam.App.Services;

/// <summary>
/// <c>iCam Camera</c> — the device other Windows applications see.
///
/// The design that matters is the decoupling. The virtual camera is a separate
/// out-of-process COM server registered through <c>MFCreateVirtualCamera</c>,
/// and it reads frames from a named shared-memory ring that iCam writes into.
/// That is why closing the iCam window does not make the camera vanish from the
/// middle of a Zoom call — the two are not the same process, and the camera
/// does not depend on the window existing.
///
/// This class is the managed half: it owns the ring, reports what is installed,
/// and drives registration. The frame source itself is native, in
/// <c>windows/iCam.VirtualCamera</c>.
/// </summary>
public sealed class VirtualCameraService : IDisposable
{
    public enum InstallState
    {
        /// <summary>Not registered on this computer yet.</summary>
        NotInstalled,
        /// <summary>Registered and available to other applications.</summary>
        Installed,
        /// <summary>Registration needs elevation the user has not granted.</summary>
        NeedsElevation,
        /// <summary>This build of Windows does not offer the virtual camera API.</summary>
        Unsupported,
    }

    /// <summary>
    /// <c>MFCreateVirtualCamera</c> arrived in Windows 11 21H2. On anything
    /// older iCam still works as a camera and as a remote control; only the
    /// virtual device is unavailable, and the interface says so plainly rather
    /// than offering a button that cannot work.
    /// </summary>
    public static bool IsSupportedByThisWindows =>
        OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000);

    private readonly FrameRing _ring = new();

    public InstallState State { get; private set; } =
        IsSupportedByThisWindows ? InstallState.NotInstalled : InstallState.Unsupported;

    public bool IsRunning { get; private set; }
    public ulong FramesPublished { get; private set; }

    public event Action? StateChanged;

    /// <summary>
    /// Hands one decoded frame to whatever is consuming <c>iCam Camera</c>.
    /// Frames are dropped rather than queued when the consumer is behind: a
    /// conferencing app would rather skip a frame than fall behind the audio.
    /// </summary>
    public void Publish(ReadOnlySpan<byte> nv12, int width, int height, ulong ptsUs)
    {
        if (!IsRunning) return;
        if (_ring.TryWrite(nv12, width, height, ptsUs)) FramesPublished++;
    }

    public void Start(StreamProfile profile)
    {
        if (State != InstallState.Installed) return;
        _ring.Open(profile.Width, profile.Height);
        IsRunning = true;
        Log.Media.Info($"iCam Camera publishing {profile.Width}x{profile.Height}");
        StateChanged?.Invoke();
    }

    public void Stop()
    {
        if (!IsRunning) return;
        IsRunning = false;
        _ring.Close();
        StateChanged?.Invoke();
    }

    public void Dispose()
    {
        Stop();
        _ring.Dispose();
    }
}

/// <summary>
/// The shared-memory ring between iCam and the virtual camera process.
///
/// Kept to a handful of NV12 frames. A ring that grows would only add latency
/// to a live camera, and a ring that blocks would let a stuck consumer stall
/// the whole media path.
/// </summary>
internal sealed class FrameRing : IDisposable
{
    private const int SlotCount = 3;

    private System.IO.MemoryMappedFiles.MemoryMappedFile? _file;
    private System.IO.MemoryMappedFiles.MemoryMappedViewAccessor? _view;
    private EventWaitHandle? _frameReady;
    private int _slotBytes;
    private long _sequence;

    public string Name { get; } = "Local\\iCam.Camera.Frames";

    public void Open(int width, int height)
    {
        Close();

        // NV12: one luma plane plus a half-height interleaved chroma plane.
        _slotBytes = width * height * 3 / 2;
        var total = HeaderBytes + (long)_slotBytes * SlotCount;

        _file = System.IO.MemoryMappedFiles.MemoryMappedFile.CreateOrOpen(Name, total);
        _view = _file.CreateViewAccessor(0, total);
        _frameReady = new EventWaitHandle(false, EventResetMode.AutoReset,
                                          "Local\\iCam.Camera.FrameReady");

        _view.Write(0, width);
        _view.Write(4, height);
        _view.Write(8, SlotCount);
        _view.Write(12, _slotBytes);
    }

    private const int HeaderBytes = 64;

    public bool TryWrite(ReadOnlySpan<byte> nv12, int width, int height, ulong ptsUs)
    {
        if (_view is null || nv12.Length > _slotBytes) return false;

        var slot = (int)(Interlocked.Increment(ref _sequence) % SlotCount);
        var offset = HeaderBytes + (long)slot * _slotBytes;

        _view.WriteArray(offset, nv12.ToArray(), 0, nv12.Length);
        _view.Write(16, slot);
        _view.Write(24, (long)ptsUs);
        _view.Write(32, Interlocked.Read(ref _sequence));

        _frameReady?.Set();
        return true;
    }

    public void Close()
    {
        _view?.Dispose();
        _view = null;
        _file?.Dispose();
        _file = null;
        _frameReady?.Dispose();
        _frameReady = null;
    }

    public void Dispose() => Close();
}
