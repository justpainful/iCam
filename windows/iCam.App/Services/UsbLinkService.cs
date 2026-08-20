using ICam.Core.Protocol;
using ICam.Core.Security;
using ICam.Core.Transport;

namespace ICam.App.Services;

/// <summary>
/// Direct USB: plug the iPhone in with a cable and it connects, no Wi-Fi
/// involved.
///
/// Built on Apple's own USB service (installed with iTunes), which multiplexes
/// TCP-like tunnels over the cable. When a phone appears, iCam opens a tunnel
/// to the phone's iCam listener and runs the *identical* session over it —
/// same handshake, same trust, same encryption. The transport is not allowed
/// to change the security story; a cable is convenient, not trusted.
///
/// Retries exist because the phone appears on the cable well before iCam is
/// open on it. Every quiet failure here is a phone that is attached but not
/// ready, which resolves itself the moment the app opens.
/// </summary>
public sealed class UsbLinkService : IAsyncDisposable
{
    private static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(3);

    private readonly DeviceIdentity _identity;
    private readonly ITrustStore _trust;
    private readonly string _computerName;
    private readonly CancellationTokenSource _cancellation = new();
    private readonly Dictionary<ulong, CancellationTokenSource> _perDevice = [];
    private readonly Lock _lock = new();

    private Task? _watchLoop;

    /// <summary>Raised for each session established over the cable.</summary>
    public event Action<PeerSession>? SessionAccepted;

    /// <summary>Null until known; then whether Apple's USB service is present.</summary>
    public bool? IsServiceAvailable { get; private set; }

    public UsbLinkService(DeviceIdentity identity, ITrustStore trust, string computerName)
    {
        _identity = identity;
        _trust = trust;
        _computerName = computerName;
    }

    public void Start() => _watchLoop ??= Task.Run(() => WatchLoopAsync(_cancellation.Token));

    private async Task WatchLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                await foreach (var (device, attached) in Usbmux.WatchAsync(token)
                                   .ConfigureAwait(false))
                {
                    IsServiceAvailable = true;
                    if (attached)
                    {
                        Log.Net.Info($"iPhone on USB ({device.Serial}); reaching for iCam");
                        BeginSessions(device.Id, token);
                    }
                    else
                    {
                        EndSessions(device.Id);
                    }
                }
            }
            catch (Exception error) when (error is System.Net.Sockets.SocketException)
            {
                // No Apple USB service — no iTunes on this machine. Said once,
                // then checked again occasionally in case it gets installed.
                if (IsServiceAvailable is null)
                {
                    Log.Net.Info("USB connections need Apple's device support " +
                                 "(installed with iTunes); not found, using Wi-Fi only");
                }
                IsServiceAvailable = false;
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception error) when (error is IOException)
            {
                Log.Net.Warn($"The USB watch dropped: {error.Message}");
            }

            try
            {
                await Task.Delay(TimeSpan.FromSeconds(15), token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private void BeginSessions(ulong deviceId, CancellationToken parent)
    {
        var lifetime = CancellationTokenSource.CreateLinkedTokenSource(parent);
        lock (_lock)
        {
            if (_perDevice.Remove(deviceId, out var previous)) previous.Cancel();
            _perDevice[deviceId] = lifetime;
        }

        _ = Task.Run(async () =>
        {
            var token = lifetime.Token;
            while (!token.IsCancellationRequested)
            {
                Stream? tunnel = null;
                try
                {
                    tunnel = await Usbmux.ConnectAsync(deviceId, Usbmux.PhonePort, token)
                                         .ConfigureAwait(false);

                    var info = new DeviceInfo
                    {
                        Name = _computerName,
                        Model = "Windows",
                        Os = Environment.OSVersion.Version.ToString(),
                        App = AppServices.VersionString,
                        Id = _identity.Fingerprint,
                    };

                    var session = new PeerSession(tunnel, _identity, info, _trust);
                    SessionAccepted?.Invoke(session);
                    try
                    {
                        // Runs for the life of the connection; returning means
                        // the phone closed iCam or the cable came out.
                        await session.RunAsync(token).ConfigureAwait(false);
                    }
                    finally
                    {
                        await session.DisposeAsync().ConfigureAwait(false);
                    }
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (Exception error) when (error is IOException
                                                    or System.Net.Sockets.SocketException)
                {
                    // Usually "iCam is not open on the phone yet". Quietly
                    // again in a moment.
                }
                finally
                {
                    tunnel?.Dispose();
                }

                try
                {
                    await Task.Delay(RetryDelay, token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }, lifetime.Token);
    }

    private void EndSessions(ulong deviceId)
    {
        lock (_lock)
        {
            if (_perDevice.Remove(deviceId, out var lifetime)) lifetime.Cancel();
        }
    }

    public async ValueTask DisposeAsync()
    {
        await _cancellation.CancelAsync().ConfigureAwait(false);
        lock (_lock)
        {
            foreach (var lifetime in _perDevice.Values) lifetime.Cancel();
            _perDevice.Clear();
        }
        if (_watchLoop is not null)
        {
            try { await _watchLoop.ConfigureAwait(false); } catch { /* shutting down */ }
        }
    }
}
