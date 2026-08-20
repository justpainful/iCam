using System.Net;
using System.Net.Sockets;
using ICam.Core.Protocol;
using ICam.Core.Security;
using ICam.Core.Transport;

namespace ICam.App.Services;

/// <summary>
/// Accepts iPhones and advertises this computer on the local network.
///
/// The PC listens and the phone connects, deliberately: the PC is the
/// stationary device, far more likely to have a stable address and a firewall
/// profile the user actually controls.
/// </summary>
public sealed class ListenerService : IAsyncDisposable
{
    private readonly DeviceIdentity _identity;
    private readonly ITrustStore _trust;
    private readonly DnssdAdvertiser _advertiser = new();
    private readonly CancellationTokenSource _cancellation = new();

    private TcpListener? _listener;
    private Task? _acceptLoop;

    public ushort Port { get; private set; }
    public bool IsListening => _listener is not null;
    public string ComputerName { get; }

    /// <summary>Raised for each accepted connection, before the handshake runs.</summary>
    public event Action<PeerSession>? SessionAccepted;
    public event Action<string>? Failed;

    public ListenerService(DeviceIdentity identity, ITrustStore trust, string computerName)
    {
        _identity = identity;
        _trust = trust;
        ComputerName = computerName;
    }

    public Task StartAsync(ushort preferredPort = Wire.DefaultPort)
    {
        if (_listener is not null) return Task.CompletedTask;

        // The preferred port first, then whatever the system will give us. A
        // busy port is not an error worth showing anybody — the real port goes
        // into the advertisement, which is how the phone finds it.
        foreach (var candidate in new[] { preferredPort, (ushort)0 })
        {
            try
            {
                var listener = new TcpListener(IPAddress.IPv6Any, candidate);
                listener.Server.SetSocketOption(SocketOptionLevel.IPv6, SocketOptionName.IPv6Only, false);
                listener.Server.NoDelay = true;
                listener.Start();

                _listener = listener;
                Port = (ushort)((IPEndPoint)listener.LocalEndpoint).Port;
                break;
            }
            catch (SocketException error)
            {
                Log.Net.Warn($"Could not listen on port {candidate}: {error.SocketErrorCode}");
            }
        }

        if (_listener is null)
        {
            Failed?.Invoke("iCam could not open a network port. Another program may be using it.");
            return Task.CompletedTask;
        }

        Log.Net.Info($"Listening on port {Port}");
        _acceptLoop = Task.Run(() => AcceptLoopAsync(_cancellation.Token));

        _advertiser.Start(ComputerName, _identity.Fingerprint, Port);
        return Task.CompletedTask;
    }

    private async Task AcceptLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested && _listener is not null)
        {
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (SocketException error)
            {
                Log.Net.Warn($"Accept failed: {error.SocketErrorCode}");
                continue;
            }

            client.NoDelay = true;
            var info = new DeviceInfo
            {
                Name = ComputerName,
                Model = "Windows",
                Os = Environment.OSVersion.Version.ToString(),
                App = AppServices.VersionString,
                Id = _identity.Fingerprint,
            };

            var session = new PeerSession(client.GetStream(), _identity, info, _trust);
            SessionAccepted?.Invoke(session);

            _ = Task.Run(async () =>
            {
                try
                {
                    await session.RunAsync(token).ConfigureAwait(false);
                }
                finally
                {
                    await session.DisposeAsync().ConfigureAwait(false);
                    client.Dispose();
                }
            }, token);
        }
    }

    public async ValueTask DisposeAsync()
    {
        await _cancellation.CancelAsync().ConfigureAwait(false);
        _advertiser.Dispose();
        _listener?.Stop();
        _listener = null;
        if (_acceptLoop is not null)
        {
            try { await _acceptLoop.ConfigureAwait(false); } catch { /* shutting down */ }
        }
        _cancellation.Dispose();
    }
}
