using System.Buffers.Binary;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;

namespace ICam.App.Services;

/// <summary>
/// The server half of the link to <c>iCam Camera</c>.
///
/// iCam hosts the pipe and the DLL connects to it. That direction is
/// deliberate: the other way round, the pipe would only exist while the Frame
/// Server had the DLL loaded, and iCam would have nothing to connect to until
/// somebody opened a camera app. This way the DLL simply retries, and shows its
/// holding card until iCam answers.
///
/// See <c>docs/VIRTUAL-CAMERA.md</c> for the wire format and for why this is a
/// named pipe rather than the shared-memory ring anyone would reach for first.
/// </summary>
public sealed class VirtualCameraPipe : IAsyncDisposable
{
    private const string PipeName = "iCam.Camera.v1";
    private const uint RequestMagic = 0x4D414349;   // 'ICAM'
    private const uint FrameMagic = 0x52464349;     // 'ICFR'
    private const uint ProtocolVersion = 1;
    private const int RequestBytes = 24;
    private const int FrameHeaderBytes = 32;

    private readonly CancellationTokenSource _cancellation = new();
    private Task? _loop;

    private NamedPipeServerStream? _stream;
    private readonly Lock _writeLock = new();
    private readonly byte[] _header = new byte[FrameHeaderBytes];

    /// <summary>The format the Frame Server negotiated, once a client asks.</summary>
    public int RequestedWidth { get; private set; }
    public int RequestedHeight { get; private set; }
    public int RequestedFps { get; private set; }

    public bool IsConnected { get; private set; }
    public ulong FramesWritten { get; private set; }
    public ulong FramesDropped { get; private set; }

    /// <summary>Raised when a client connects and states the format it needs.</summary>
    public event Action<int, int, int>? FormatRequested;
    public event Action<bool>? ConnectionChanged;

    public void Start()
    {
        if (_loop is not null) return;
        _loop = Task.Run(() => AcceptLoopAsync(_cancellation.Token));
    }

    private async Task AcceptLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            NamedPipeServerStream? server = null;
            try
            {
                server = CreateServer();
                await server.WaitForConnectionAsync(token).ConfigureAwait(false);

                var request = new byte[RequestBytes];
                await server.ReadExactlyAsync(request, token).ConfigureAwait(false);

                var magic = BinaryPrimitives.ReadUInt32LittleEndian(request);
                var version = BinaryPrimitives.ReadUInt32LittleEndian(request.AsSpan(4));
                if (magic != RequestMagic || version != ProtocolVersion)
                {
                    Log.Media.Warn($"iCam Camera sent an unrecognised request "
                                   + $"(magic 0x{magic:X8}, version {version})");
                    server.Dispose();
                    continue;
                }

                RequestedWidth = (int)BinaryPrimitives.ReadUInt32LittleEndian(request.AsSpan(8));
                RequestedHeight = (int)BinaryPrimitives.ReadUInt32LittleEndian(request.AsSpan(12));
                RequestedFps = (int)BinaryPrimitives.ReadUInt32LittleEndian(request.AsSpan(16));

                lock (_writeLock)
                {
                    _stream?.Dispose();
                    _stream = server;
                }
                IsConnected = true;
                server = null;   // ownership moved

                Log.Media.Info($"iCam Camera connected, asking for "
                               + $"{RequestedWidth}x{RequestedHeight} at {RequestedFps}");
                FormatRequested?.Invoke(RequestedWidth, RequestedHeight, RequestedFps);
                ConnectionChanged?.Invoke(true);

                // The client never speaks again; it only reads. Waiting for it
                // to disappear is how this loop learns to accept the next one.
                await WaitForDisconnectAsync(token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                server?.Dispose();
                return;
            }
            catch (Exception error) when (error is IOException or EndOfStreamException
                                                or UnauthorizedAccessException)
            {
                Log.Media.Warn($"iCam Camera pipe: {error.Message}");
                server?.Dispose();
                await Task.Delay(500, token).ConfigureAwait(false);
            }
        }
    }

    private async Task WaitForDisconnectAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            NamedPipeServerStream? current;
            lock (_writeLock) current = _stream;
            if (current is null || !current.IsConnected) break;
            await Task.Delay(250, token).ConfigureAwait(false);
        }

        lock (_writeLock)
        {
            _stream?.Dispose();
            _stream = null;
        }
        if (IsConnected)
        {
            IsConnected = false;
            Log.Media.Info("iCam Camera disconnected");
            ConnectionChanged?.Invoke(false);
        }
    }

    /// <summary>
    /// Sends one NV12 frame. Returns false when there is no client, or when the
    /// previous write is still in flight — a frame is dropped rather than
    /// queued, because a call would rather skip a frame than drift behind its
    /// own audio.
    /// </summary>
    public bool TryWriteFrame(ReadOnlySpan<byte> nv12, int width, int height, int stride,
                              ulong ptsUs, bool isHoldingPattern = false)
    {
        NamedPipeServerStream? stream;
        lock (_writeLock) stream = _stream;
        if (stream is null || !stream.IsConnected) return false;

        var expected = stride * height * 3 / 2;
        if (nv12.Length < expected) return false;

        if (!Monitor.TryEnter(_writeLock))
        {
            FramesDropped++;
            return false;
        }
        try
        {
            BinaryPrimitives.WriteUInt32LittleEndian(_header, FrameMagic);
            BinaryPrimitives.WriteUInt32LittleEndian(_header.AsSpan(4), (uint)width);
            BinaryPrimitives.WriteUInt32LittleEndian(_header.AsSpan(8), (uint)height);
            BinaryPrimitives.WriteUInt32LittleEndian(_header.AsSpan(12), (uint)stride);
            BinaryPrimitives.WriteUInt32LittleEndian(_header.AsSpan(16), (uint)expected);
            BinaryPrimitives.WriteUInt32LittleEndian(_header.AsSpan(20),
                                                     isHoldingPattern ? 1u : 0u);
            BinaryPrimitives.WriteUInt64LittleEndian(_header.AsSpan(24), ptsUs);

            stream.Write(_header);
            stream.Write(nv12[..expected]);
            FramesWritten++;
            return true;
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException)
        {
            // The Frame Server let go mid-write. The accept loop will notice
            // and take the next client.
            lock (_writeLock)
            {
                _stream?.Dispose();
                _stream = null;
            }
            IsConnected = false;
            ConnectionChanged?.Invoke(false);
            return false;
        }
        finally
        {
            Monitor.Exit(_writeLock);
        }
    }

    /// <summary>
    /// The pipe has to be reachable from the Frame Server, which runs as a
    /// service in another session and another account. Without an explicit
    /// ACL the default only admits the creating user, and the DLL's connect
    /// fails with access denied — which looks exactly like iCam not running.
    /// </summary>
    private static NamedPipeServerStream CreateServer()
    {
        var security = new PipeSecurity();

        var authenticated = new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null);
        security.AddAccessRule(new PipeAccessRule(
            authenticated, PipeAccessRights.ReadWrite, AccessControlType.Allow));

        var localService = new SecurityIdentifier(WellKnownSidType.LocalServiceSid, null);
        security.AddAccessRule(new PipeAccessRule(
            localService, PipeAccessRights.ReadWrite, AccessControlType.Allow));

        var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        security.AddAccessRule(new PipeAccessRule(
            system, PipeAccessRights.ReadWrite, AccessControlType.Allow));

        return NamedPipeServerStreamAcl.Create(
            PipeName,
            PipeDirection.InOut,
            maxNumberOfServerInstances: 1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.WriteThrough,
            inBufferSize: 64 * 1024,
            // Sized for one 1080p NV12 frame, so a write never blocks waiting
            // for the reader to drain a partial frame.
            outBufferSize: 1920 * 1080 * 3 / 2 + 64 * 1024,
            security);
    }

    public async ValueTask DisposeAsync()
    {
        await _cancellation.CancelAsync().ConfigureAwait(false);
        lock (_writeLock)
        {
            _stream?.Dispose();
            _stream = null;
        }
        if (_loop is not null)
        {
            try { await _loop.ConfigureAwait(false); } catch { /* shutting down */ }
        }
        _cancellation.Dispose();
    }
}
