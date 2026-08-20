using System.Text.Json;
using ICam.Core.Protocol;
using ICam.Core.Security;

namespace ICam.Core.Transport;

/// <summary>
/// One connected iPhone, with meaning attached.
///
/// Deliberately built on a plain <see cref="Stream"/> rather than on a socket
/// type: the handshake, the record layer, framing and dispatch are all
/// testable over a loopback pair with no network, no WinRT and no phone. The
/// platform layer's only job is to hand this class a connected stream.
/// </summary>
public sealed class PeerSession : IAsyncDisposable
{
    public enum SessionState
    {
        Handshaking,
        /// <summary>Waiting for the user to confirm the pairing digits.</summary>
        AwaitingTrust,
        Ready,
        Closed,
    }

    private readonly Stream _stream;
    private readonly DeviceIdentity _identity;
    private readonly DeviceInfo _deviceInfo;
    private readonly ITrustStore _trust;
    private readonly CancellationTokenSource _cancellation = new();

    private readonly FrameParser _parser = new();
    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private readonly System.Threading.Channels.Channel<byte[]> _mediaQueue =
        System.Threading.Channels.Channel.CreateBounded<byte[]>(
            new System.Threading.Channels.BoundedChannelOptions(64)
        {
            // Video is dropped, never queued, when the link is behind. Timing is
            // worth more than completeness on a live camera feed.
            FullMode = System.Threading.Channels.BoundedChannelFullMode.DropOldest,
        });

    private ResponderHandshake? _handshake;
    private SecureChannel? _channel;
    private uint _nextMessageId = 1;

    public SessionState State { get; private set; } = SessionState.Handshaking;
    public DeviceInfo? PeerDevice { get; private set; }
    public string? PeerFingerprint { get; private set; }

    /// <summary>The six digits to show while <see cref="SessionState.AwaitingTrust"/>.</summary>
    public string? PairingDigits { get; private set; }

    public ulong BytesSent { get; private set; }
    public ulong BytesReceived { get; private set; }
    public ulong DroppedMediaFrames { get; private set; }

    // Events. All raised from the read loop, never from a UI thread — the
    // caller marshals.
    public event Action<ControlEnvelope>? ControlReceived;
    public event Action<VideoFrameHeader, ReadOnlyMemory<byte>>? VideoReceived;
    public event Action<AudioFrameHeader, ReadOnlyMemory<byte>>? AudioReceived;
    public event Action<BulkFrameHeader, ReadOnlyMemory<byte>>? BulkReceived;
    public event Action<SessionState>? StateChanged;
    public event Action<string?>? Closed;

    public PeerSession(Stream stream, DeviceIdentity identity, DeviceInfo deviceInfo,
                       ITrustStore trust)
    {
        _stream = stream;
        _identity = identity;
        _deviceInfo = deviceInfo;
        _trust = trust;
    }

    /// <summary>
    /// Runs the session until the peer goes away or the token is cancelled.
    /// Never throws for an ordinary disconnection: that is expected, not
    /// exceptional.
    /// </summary>
    public async Task RunAsync(CancellationToken cancellationToken = default)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(
            _cancellation.Token, cancellationToken);
        var token = linked.Token;

        var sender = Task.Run(() => PumpMediaAsync(token), token);
        string? reason = null;

        try
        {
            var buffer = new byte[64 * 1024];
            while (!token.IsCancellationRequested)
            {
                var read = await _stream.ReadAsync(buffer, token).ConfigureAwait(false);
                if (read <= 0) break;

                BytesReceived += (ulong)read;
                _parser.Append(buffer.AsSpan(0, read));

                while (true)
                {
                    Frame frame;
                    byte[] header;
                    try
                    {
                        if (!_parser.TryRead(out frame, out header)) break;
                    }
                    catch (FrameException error)
                        when (error.Kind == FrameException.Reason.UnknownChannel)
                    {
                        // A newer peer using a channel we do not implement is
                        // not an error. The bytes are already consumed.
                        continue;
                    }

                    await RouteAsync(frame, header, token).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Ordinary shutdown.
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException)
        {
            reason = "The connection to your iPhone ended.";
        }
        catch (HandshakeException error)
        {
            reason = error.Kind switch
            {
                HandshakeException.Reason.VersionMismatch =>
                    "iCam on this iPhone is a different version. Update both to continue.",
                HandshakeException.Reason.BadSignature =>
                    "iCam could not verify this iPhone. Pair the devices again.",
                _ => "This iPhone did not complete the connection.",
            };
        }
        catch (SecureChannelException)
        {
            reason = "The secure connection to your iPhone failed.";
        }
        finally
        {
            _mediaQueue.Writer.TryComplete();
            _cancellation.Cancel();
            try { await sender.ConfigureAwait(false); } catch { /* already closing */ }
            SetState(SessionState.Closed);
            Closed?.Invoke(reason);
        }
    }

    // MARK: - Trust

    /// <summary>The user confirmed the pairing digits on this computer.</summary>
    public async Task ConfirmPairingAsync(CancellationToken cancellationToken = default)
    {
        if (State != SessionState.AwaitingTrust || _handshake is null) return;

        _trust.Trust(_handshake.PeerIdentityKey, PeerDevice?.Name ?? "iPhone");
        await SendRawAsync(new Frame(Channel.Handshake, _handshake.Ready(true)).Encode(),
                           cancellationToken).ConfigureAwait(false);
        SetState(SessionState.Ready);
    }

    public void RejectPairing() => _cancellation.Cancel();

    // MARK: - Sending

    public ValueTask SendControlAsync<T>(string type, T payload, uint? replyTo = null,
                                         CancellationToken cancellationToken = default)
    {
        var id = _nextMessageId == uint.MaxValue ? _nextMessageId = 1 : _nextMessageId++;
        return SendSealedAsync(Channel.Control, ControlCodec.Encode(type, id, payload, replyTo),
                               media: false, cancellationToken);
    }

    public ValueTask SendCameraCommandAsync(ulong baseVersion, CameraMutation mutation,
                                            CancellationToken cancellationToken = default) =>
        SendControlAsync(ControlType.CameraCommand,
                         new CameraCommandPayload { Base = baseVersion, Set = mutation },
                         cancellationToken: cancellationToken);

    public ValueTask StartStreamAsync(StreamProfile profile,
                                      CancellationToken cancellationToken = default) =>
        SendControlAsync(ControlType.StreamStart, new StreamStartPayload { Profile = profile },
                         cancellationToken: cancellationToken);

    public ValueTask StopStreamAsync(CancellationToken cancellationToken = default) =>
        SendControlAsync(ControlType.StreamStop, new { }, cancellationToken: cancellationToken);

    // MARK: - Routing

    private async ValueTask RouteAsync(Frame frame, byte[] header, CancellationToken token)
    {
        if (frame.Channel == Channel.Handshake)
        {
            await HandleHandshakeAsync(frame.Payload, token).ConfigureAwait(false);
            return;
        }

        if (_channel is null || State == SessionState.Handshaking)
        {
            throw new SecureChannelException("data arrived before the handshake completed");
        }
        if (State == SessionState.AwaitingTrust)
        {
            // Nothing is accepted until the user has confirmed the digits. The
            // frame is opened so the counter stays in step, then discarded.
            _channel.Open(header, frame.Payload.Span);
            return;
        }

        var plaintext = _channel.Open(header, frame.Payload.Span);

        switch (frame.Channel)
        {
            case Channel.Control:
                var envelope = ControlCodec.DecodeEnvelope(plaintext);
                if (envelope is null) return;
                if (envelope.T == ControlType.TimePing)
                {
                    await AnswerTimePingAsync(envelope, token).ConfigureAwait(false);
                    return;
                }
                ControlReceived?.Invoke(envelope);
                break;

            case Channel.Video:
                if (VideoFrameHeader.TryDecode(plaintext, out var videoHeader, out var videoBody))
                {
                    VideoReceived?.Invoke(videoHeader, videoBody.ToArray());
                }
                break;

            case Channel.Audio:
                if (AudioFrameHeader.TryDecode(plaintext, out var audioHeader, out var audioBody))
                {
                    AudioReceived?.Invoke(audioHeader, audioBody.ToArray());
                }
                break;

            case Channel.Bulk:
                if (BulkFrameHeader.TryDecode(plaintext, out var bulkHeader, out var bulkBody))
                {
                    BulkReceived?.Invoke(bulkHeader, bulkBody.ToArray());
                }
                break;
        }
    }

    private async ValueTask HandleHandshakeAsync(ReadOnlyMemory<byte> payload,
                                                 CancellationToken token)
    {
        switch (HandshakeCodec.MessageType(payload.Span))
        {
            case "hello":
                _handshake = new ResponderHandshake(_identity, _deviceInfo);
                var response = _handshake.HandleClientHello(payload.Span);
                PeerDevice = _handshake.PeerDevice;
                PeerFingerprint = DeviceIdentity.FingerprintOf(_handshake.PeerIdentityKey);
                await SendRawAsync(new Frame(Channel.Handshake, response).Encode(), token)
                    .ConfigureAwait(false);
                break;

            case "auth":
                if (_handshake is null || _handshake.Keys is null)
                {
                    throw new HandshakeException(HandshakeException.Reason.WrongMessage,
                                                 "auth arrived before hello");
                }
                _handshake.HandleClientAuth(payload.Span);
                _channel = new SecureChannel(_handshake.Keys, ChannelRole.Responder);
                PairingDigits = _handshake.Keys.PairingDigits;

                var trusted = _trust.IsTrusted(_handshake.PeerIdentityKey);
                await SendRawAsync(new Frame(Channel.Handshake, _handshake.Ready(trusted)).Encode(),
                                   token).ConfigureAwait(false);

                if (trusted)
                {
                    _trust.NoteSeen(PeerFingerprint!);
                    SetState(SessionState.Ready);
                    await SendControlAsync(ControlType.DeviceInfo, _deviceInfo,
                                           cancellationToken: token).ConfigureAwait(false);
                }
                else
                {
                    // First pairing. Both devices show the same six digits,
                    // derived from the handshake transcript; matching digits
                    // prove there is nobody in the middle.
                    SetState(SessionState.AwaitingTrust);
                }
                break;

            default:
                throw new HandshakeException(HandshakeException.Reason.WrongMessage,
                                             "unexpected handshake message");
        }
    }

    private ValueTask AnswerTimePingAsync(ControlEnvelope envelope, CancellationToken token)
    {
        var ping = ControlCodec.Payload<TimePingPayload>(envelope);
        if (ping is null) return ValueTask.CompletedTask;

        var received = MonotonicClock.NowUs();
        return SendControlAsync(ControlType.TimePong,
                                new TimePongPayload
                                {
                                    T1 = ping.T1,
                                    T2 = received,
                                    T3 = MonotonicClock.NowUs(),
                                },
                                envelope.Id, token);
    }

    // MARK: - Writing

    private async ValueTask SendSealedAsync(Channel channel, byte[] plaintext, bool media,
                                            CancellationToken token)
    {
        if (_channel is null || State == SessionState.Closed) return;

        byte[] sealedFrame;
        await _writeLock.WaitAsync(token).ConfigureAwait(false);
        try
        {
            sealedFrame = _channel.Seal(channel, plaintext);
        }
        finally
        {
            _writeLock.Release();
        }

        if (media)
        {
            if (!_mediaQueue.Writer.TryWrite(sealedFrame)) DroppedMediaFrames++;
            return;
        }
        await SendRawAsync(sealedFrame, token).ConfigureAwait(false);
    }

    private async ValueTask SendRawAsync(byte[] bytes, CancellationToken token)
    {
        await _writeLock.WaitAsync(token).ConfigureAwait(false);
        try
        {
            await _stream.WriteAsync(bytes, token).ConfigureAwait(false);
            await _stream.FlushAsync(token).ConfigureAwait(false);
            BytesSent += (ulong)bytes.Length;
        }
        finally
        {
            _writeLock.Release();
        }
    }

    /// <summary>
    /// Media leaves through its own queue so a slow socket applies back
    /// pressure by dropping frames rather than by blocking the read loop —
    /// which would also stall control, and with it the user's ability to stop.
    /// </summary>
    private async Task PumpMediaAsync(CancellationToken token)
    {
        try
        {
            await foreach (var frame in _mediaQueue.Reader.ReadAllAsync(token)
                               .ConfigureAwait(false))
            {
                await SendRawAsync(frame, token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is IOException or ObjectDisposedException) { }
    }

    private void SetState(SessionState state)
    {
        if (State == state) return;
        State = state;
        StateChanged?.Invoke(state);
    }

    public async ValueTask DisposeAsync()
    {
        await _cancellation.CancelAsync().ConfigureAwait(false);
        _channel?.Dispose();
        _handshake?.Dispose();
        _writeLock.Dispose();
        _cancellation.Dispose();
    }
}

/// <summary>Which iPhones this computer trusts.</summary>
public interface ITrustStore
{
    bool IsTrusted(ReadOnlySpan<byte> publicKey);
    void Trust(byte[] publicKey, string name);
    void NoteSeen(string fingerprint);
    void Forget(string fingerprint);
    IReadOnlyList<TrustedPeer> Peers { get; }
}

public sealed record TrustedPeer(string Id, string Name, byte[] PublicKey,
                                 DateTimeOffset PairedAt, DateTimeOffset? LastSeenAt);

/// <summary>
/// One monotonic time base for the whole application, in microseconds.
///
/// <c>DateTime</c> is never used for timing: it jumps when the clock changes,
/// when NTP corrects, and across daylight saving.
/// </summary>
public static class MonotonicClock
{
    public static ulong NowUs() =>
        (ulong)(System.Diagnostics.Stopwatch.GetTimestamp()
                / (double)System.Diagnostics.Stopwatch.Frequency * 1_000_000);
}
