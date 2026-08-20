using System.Net;
using System.Net.Sockets;
using System.Text;
using ICam.Core.Protocol;
using ICam.Core.Security;
using ICam.Core.Transport;
using Xunit;

namespace ICam.Core.Tests;

/// <summary>
/// Drives a real <see cref="PeerSession"/> over a loopback socket with a
/// stand-in for the iPhone.
///
/// The stand-in follows <c>docs/PROTOCOL.md</c> step by step rather than
/// calling into the responder's own helpers, so a change that breaks the phone
/// shows up here instead of on a desk with two devices that will not pair.
/// </summary>
public class SessionTests
{
    private sealed class PhoneStandIn : IDisposable
    {
        private readonly DeviceIdentity _identity = DeviceIdentity.Create();
        private readonly EphemeralKeyPair _ephemeral = new();
        private readonly byte[] _clientRandom = Enumerable.Range(0, 32)
            .Select(i => (byte)(i * 5 + 1)).ToArray();
        private readonly FrameParser _parser = new();
        private readonly Stream _stream;

        private SecureChannel? _channel;

        public PhoneStandIn(Stream stream) => _stream = stream;

        public byte[] PublicKey => _identity.PublicKey;
        public SessionKeys? Keys { get; private set; }
        public bool WasTrustedOnConnect { get; private set; }

        public async Task<bool> HandshakeAsync(string name, CancellationToken token)
        {
            var hello = new ClientHello
            {
                Eph = _ephemeral.PublicKey,
                Idk = _identity.PublicKey,
                Rnd = _clientRandom,
                Dev = new DeviceInfo { Name = name, Model = "iPhone16,1", Os = "18.5", App = "1.0.0" },
            };
            var helloBytes = HandshakeCodec.Encode(hello);
            await WriteAsync(new Frame(Channel.Handshake, helloBytes).Encode(), token);

            var serverHelloBytes = await ReadHandshakeAsync(token);
            var serverHello = HandshakeCodec.Decode<ServerHello>(serverHelloBytes)!;

            var transcript = helloBytes.Concat(serverHello.TranscriptBytes()).ToArray();
            Assert.True(DeviceIdentity.Verify(
                serverHello.Sig!,
                Encoding.UTF8.GetBytes("iCam/v1/server").Concat(transcript).ToArray(),
                serverHello.Idk));

            Keys = SessionKeys.Derive(_ephemeral.SharedSecret(serverHello.Eph),
                                      _clientRandom, serverHello.Rnd);
            _channel = new SecureChannel(Keys, ChannelRole.Initiator);

            var auth = new ClientAuth
            {
                Sig = _identity.Sign(
                    Encoding.UTF8.GetBytes("iCam/v1/client").Concat(transcript).ToArray()),
            };
            await WriteAsync(new Frame(Channel.Handshake, HandshakeCodec.Encode(auth)).Encode(),
                             token);

            var readyBytes = await ReadHandshakeAsync(token);
            WasTrustedOnConnect = HandshakeCodec.Decode<HandshakeReady>(readyBytes)!.Trusted;
            return WasTrustedOnConnect;
        }

        /// <summary>Waits for the second `ready`, sent after the user confirms.</summary>
        public async Task<bool> AwaitTrustConfirmationAsync(CancellationToken token)
        {
            var bytes = await ReadHandshakeAsync(token);
            return HandshakeCodec.Decode<HandshakeReady>(bytes)!.Trusted;
        }

        public Task SendControlAsync<T>(string type, uint id, T payload, CancellationToken token)
        {
            var plaintext = ControlCodec.Encode(type, id, payload);
            return WriteAsync(_channel!.Seal(Channel.Control, plaintext), token);
        }

        public Task SendVideoAsync(VideoFrameHeader header, byte[] body, CancellationToken token)
        {
            var plaintext = header.Encode().Concat(body).ToArray();
            return WriteAsync(_channel!.Seal(Channel.Video, plaintext), token);
        }

        public async Task<ControlEnvelope> ReadControlAsync(CancellationToken token)
        {
            while (true)
            {
                var (frame, header) = await ReadFrameAsync(token);
                var plaintext = _channel!.Open(header, frame.Payload.Span);
                if (frame.Channel != Channel.Control) continue;
                return ControlCodec.DecodeEnvelope(plaintext)!;
            }
        }

        private async Task<byte[]> ReadHandshakeAsync(CancellationToken token)
        {
            var (frame, _) = await ReadFrameAsync(token);
            Assert.Equal(Channel.Handshake, frame.Channel);
            return frame.Payload.ToArray();
        }

        private async Task<(Frame Frame, byte[] Header)> ReadFrameAsync(CancellationToken token)
        {
            var buffer = new byte[16 * 1024];
            while (true)
            {
                if (_parser.TryRead(out var frame, out var header)) return (frame, header);
                var read = await _stream.ReadAsync(buffer, token);
                if (read <= 0) throw new IOException("the connection closed during the handshake");
                _parser.Append(buffer.AsSpan(0, read));
            }
        }

        private async Task WriteAsync(byte[] bytes, CancellationToken token)
        {
            await _stream.WriteAsync(bytes, token);
            await _stream.FlushAsync(token);
        }

        public void Dispose()
        {
            _identity.Dispose();
            _ephemeral.Dispose();
            _channel?.Dispose();
        }
    }

    private static async Task<(NetworkStream Server, NetworkStream Client, IDisposable Cleanup)>
        LoopbackPairAsync()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;

        var clientTask = Task.Run(async () =>
        {
            var client = new TcpClient();
            await client.ConnectAsync(IPAddress.Loopback, port);
            return client;
        });

        var accepted = await listener.AcceptTcpClientAsync();
        var client = await clientTask;
        listener.Stop();

        var cleanup = new Disposer(() =>
        {
            accepted.Dispose();
            client.Dispose();
        });
        return (accepted.GetStream(), client.GetStream(), cleanup);
    }

    private sealed class Disposer(Action action) : IDisposable
    {
        public void Dispose() => action();
    }

    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);

    [Fact]
    public async Task FirstConnectionAsksForPairingAndThenBecomesReady()
    {
        using var cancellation = new CancellationTokenSource(Timeout);
        var token = cancellation.Token;

        var (serverStream, clientStream, cleanup) = await LoopbackPairAsync();
        using var _ = cleanup;
        using var identity = DeviceIdentity.Create();
        var trust = new InMemoryTrustStore();

        await using var session = new PeerSession(
            serverStream, identity,
            new DeviceInfo { Name = "RAEID-PC", Model = "Windows 11" }, trust);
        var run = session.RunAsync(token);

        using var phone = new PhoneStandIn(clientStream);
        var trusted = await phone.HandshakeAsync("Raeid's iPhone", token);

        // An iPhone this computer has never seen must not be trusted on the
        // strength of the handshake alone.
        Assert.False(trusted);
        await WaitForStateAsync(session, PeerSession.SessionState.AwaitingTrust, token);
        Assert.Equal(6, session.PairingDigits!.Length);
        Assert.Equal(phone.Keys!.PairingDigits, session.PairingDigits);
        Assert.Equal("Raeid's iPhone", session.PeerDevice!.Name);

        // The user compares the digits and confirms on this computer.
        await session.ConfirmPairingAsync(token);
        Assert.True(await phone.AwaitTrustConfirmationAsync(token));
        Assert.Equal(PeerSession.SessionState.Ready, session.State);
        Assert.True(trust.IsTrusted(phone.PublicKey));

        cancellation.Cancel();
        await run;
    }

    [Fact]
    public async Task AnAlreadyTrustediPhoneConnectsWithoutAsking()
    {
        using var cancellation = new CancellationTokenSource(Timeout);
        var token = cancellation.Token;

        var (serverStream, clientStream, cleanup) = await LoopbackPairAsync();
        using var _ = cleanup;
        using var identity = DeviceIdentity.Create();
        var trust = new InMemoryTrustStore();

        using var phone = new PhoneStandIn(clientStream);
        trust.Trust(phone.PublicKey, "Raeid's iPhone");

        await using var session = new PeerSession(
            serverStream, identity, new DeviceInfo { Name = "RAEID-PC" }, trust);
        var run = session.RunAsync(token);

        Assert.True(await phone.HandshakeAsync("Raeid's iPhone", token));
        await WaitForStateAsync(session, PeerSession.SessionState.Ready, token);

        // And the computer introduces itself straight away.
        var envelope = await phone.ReadControlAsync(token);
        Assert.Equal(ControlType.DeviceInfo, envelope.T);
        Assert.Equal("RAEID-PC", ControlCodec.Payload<DeviceInfo>(envelope)!.Name);

        cancellation.Cancel();
        await run;
    }

    [Fact]
    public async Task CameraStateAndVideoArriveAfterPairing()
    {
        using var cancellation = new CancellationTokenSource(Timeout);
        var token = cancellation.Token;

        var (serverStream, clientStream, cleanup) = await LoopbackPairAsync();
        using var _ = cleanup;
        using var identity = DeviceIdentity.Create();
        var trust = new InMemoryTrustStore();

        using var phone = new PhoneStandIn(clientStream);
        trust.Trust(phone.PublicKey, "Raeid's iPhone");

        await using var session = new PeerSession(
            serverStream, identity, new DeviceInfo { Name = "RAEID-PC" }, trust);

        var states = new List<CameraState>();
        var videos = new List<(VideoFrameHeader Header, byte[] Body)>();
        session.ControlReceived += envelope =>
        {
            if (envelope.T != ControlType.CameraState) return;
            var state = ControlCodec.Payload<CameraState>(envelope);
            if (state is not null) lock (states) states.Add(state);
        };
        session.VideoReceived += (header, body) =>
        {
            lock (videos) videos.Add((header, body.ToArray()));
        };

        var run = session.RunAsync(token);
        await phone.HandshakeAsync("Raeid's iPhone", token);
        await WaitForStateAsync(session, PeerSession.SessionState.Ready, token);

        await phone.SendControlAsync(ControlType.CameraState, 1,
            new CameraState { Version = 7, LensId = "back.wide", Iso = 250 }, token);

        var parameterSets = new VideoFrameHeader(VideoCodec.H264, true, true, false, 1, 0, 0);
        await phone.SendVideoAsync(parameterSets, [0x01, 0x64, 0x00, 0x28], token);
        var keyframe = new VideoFrameHeader(VideoCodec.H264, true, false, false, 2, 1000, 1000);
        await phone.SendVideoAsync(keyframe, Enumerable.Range(0, 64).Select(i => (byte)i).ToArray(),
                                   token);

        await WaitUntilAsync(() =>
        {
            lock (states) lock (videos) return states.Count >= 1 && videos.Count >= 2;
        }, token);

        Assert.Equal(7ul, states[0].Version);
        Assert.Equal(250, states[0].Iso);
        Assert.True(videos[0].Header.IsParameterSets);
        Assert.False(videos[1].Header.IsParameterSets);
        Assert.Equal(64, videos[1].Body.Length);
        Assert.Equal(1000ul, videos[1].Header.PtsUs);

        cancellation.Cancel();
        await run;
    }

    [Fact]
    public async Task ATimePingIsAnsweredWithBothTimestamps()
    {
        using var cancellation = new CancellationTokenSource(Timeout);
        var token = cancellation.Token;

        var (serverStream, clientStream, cleanup) = await LoopbackPairAsync();
        using var _ = cleanup;
        using var identity = DeviceIdentity.Create();
        var trust = new InMemoryTrustStore();

        using var phone = new PhoneStandIn(clientStream);
        trust.Trust(phone.PublicKey, "Raeid's iPhone");

        await using var session = new PeerSession(
            serverStream, identity, new DeviceInfo { Name = "RAEID-PC" }, trust);
        var run = session.RunAsync(token);

        await phone.HandshakeAsync("Raeid's iPhone", token);
        await WaitForStateAsync(session, PeerSession.SessionState.Ready, token);
        await phone.ReadControlAsync(token);   // the device.info greeting

        await phone.SendControlAsync(ControlType.TimePing, 42,
                                     new TimePingPayload { T1 = 123456 }, token);

        var pong = await phone.ReadControlAsync(token);
        Assert.Equal(ControlType.TimePong, pong.T);
        Assert.Equal(42u, pong.R);

        var payload = ControlCodec.Payload<TimePongPayload>(pong)!;
        Assert.Equal(123456ul, payload.T1);
        Assert.True(payload.T2 > 0);
        Assert.True(payload.T3 >= payload.T2);

        cancellation.Cancel();
        await run;
    }

    [Fact]
    public async Task NothingIsDeliveredBeforeTheUserConfirmsPairing()
    {
        using var cancellation = new CancellationTokenSource(Timeout);
        var token = cancellation.Token;

        var (serverStream, clientStream, cleanup) = await LoopbackPairAsync();
        using var _ = cleanup;
        using var identity = DeviceIdentity.Create();
        var trust = new InMemoryTrustStore();

        await using var session = new PeerSession(
            serverStream, identity, new DeviceInfo { Name = "RAEID-PC" }, trust);

        var delivered = 0;
        session.ControlReceived += _ => Interlocked.Increment(ref delivered);

        var run = session.RunAsync(token);
        using var phone = new PhoneStandIn(clientStream);
        await phone.HandshakeAsync("Unknown iPhone", token);
        await WaitForStateAsync(session, PeerSession.SessionState.AwaitingTrust, token);

        // An unconfirmed peer can put bytes on the wire. None of them may reach
        // the application.
        await phone.SendControlAsync(ControlType.CameraState, 1,
                                     new CameraState { Version = 1 }, token);
        await Task.Delay(150, token);
        Assert.Equal(0, delivered);

        cancellation.Cancel();
        await run;
    }

    [Fact]
    public async Task ClosingTheSocketEndsTheSessionWithoutThrowing()
    {
        using var cancellation = new CancellationTokenSource(Timeout);
        var token = cancellation.Token;

        var (serverStream, clientStream, cleanup) = await LoopbackPairAsync();
        using var identity = DeviceIdentity.Create();

        await using var session = new PeerSession(
            serverStream, identity, new DeviceInfo(), new InMemoryTrustStore());

        var closedReasons = new List<string?>();
        session.Closed += reason => closedReasons.Add(reason);

        var run = session.RunAsync(token);
        clientStream.Dispose();
        cleanup.Dispose();

        // A disconnection is expected, not exceptional.
        await run;
        Assert.Equal(PeerSession.SessionState.Closed, session.State);
        Assert.Single(closedReasons);
    }

    private static Task WaitForStateAsync(PeerSession session, PeerSession.SessionState state,
                                          CancellationToken token) =>
        WaitUntilAsync(() => session.State == state, token);

    private static async Task WaitUntilAsync(Func<bool> condition, CancellationToken token)
    {
        while (!condition())
        {
            token.ThrowIfCancellationRequested();
            await Task.Delay(10, token);
        }
    }
}
