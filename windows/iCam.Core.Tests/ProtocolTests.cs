using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using ICam.Core.Protocol;
using ICam.Core.Security;
using Xunit;

namespace ICam.Core.Tests;

public class FrameParserTests
{
    [Fact]
    public void RoundTripsASingleFrame()
    {
        var payload = Encoding.UTF8.GetBytes("hello");
        var parser = new FrameParser();
        parser.Append(new Frame(Channel.Control, payload).Encode());

        Assert.True(parser.TryRead(out var frame, out var header));
        Assert.Equal(Channel.Control, frame.Channel);
        Assert.Equal(payload, frame.Payload.ToArray());
        Assert.Equal(Wire.HeaderSize, header.Length);
        Assert.Equal(0, parser.PendingByteCount);
    }

    [Fact]
    public void HeaderIsExactlyTheAssociatedData()
    {
        var payload = new byte[40];
        Array.Fill(payload, (byte)7);
        var parser = new FrameParser();
        parser.Append(new Frame(Channel.Video, payload).Encode());

        Assert.True(parser.TryRead(out _, out var header));
        // Byte-identical to what the sender built, or AEAD fails on every frame.
        Assert.Equal(Frame.Header(Channel.Video, FrameFlags.EndOfMessage, payload.Length), header);
    }

    [Fact]
    public void WaitsForTheRestOfAFrame()
    {
        var encoded = new Frame(Channel.Control, new byte[100]).Encode();
        var parser = new FrameParser();

        parser.Append(encoded.AsSpan(0, 20));
        Assert.False(parser.TryRead(out _, out _));

        parser.Append(encoded.AsSpan(20));
        Assert.True(parser.TryRead(out var frame, out _));
        Assert.Equal(100, frame.Payload.Length);
    }

    [Fact]
    public void ParsesSeveralFramesFromOneRead()
    {
        var parser = new FrameParser();
        for (byte i = 0; i < 5; i++)
        {
            parser.Append(new Frame(Channel.Control, new[] { i }).Encode());
        }

        for (byte i = 0; i < 5; i++)
        {
            Assert.True(parser.TryRead(out var frame, out _));
            Assert.Equal(i, frame.Payload.Span[0]);
        }
        Assert.False(parser.TryRead(out _, out _));
    }

    [Fact]
    public void RejectsAnOversizedFrame()
    {
        var buffer = new byte[8];
        BinaryPrimitives.WriteUInt32BigEndian(buffer, (uint)Wire.MaxFrameLength + 1);
        buffer[4] = 1;
        buffer[5] = 1;

        var parser = new FrameParser();
        parser.Append(buffer);

        var error = Assert.Throws<FrameException>(() => parser.TryRead(out _, out _));
        Assert.Equal(FrameException.Reason.Oversized, error.Kind);
    }

    [Fact]
    public void SkipsAnUnknownChannelWithoutLosingTheStream()
    {
        var payload = Encoding.UTF8.GetBytes("skip me");
        var unknown = new byte[Wire.HeaderSize + payload.Length];
        BinaryPrimitives.WriteUInt32BigEndian(unknown, (uint)(payload.Length + 4));
        unknown[4] = 99;
        unknown[5] = 1;
        payload.CopyTo(unknown, Wire.HeaderSize);

        var parser = new FrameParser();
        parser.Append(unknown);
        parser.Append(new Frame(Channel.Control, Encoding.UTF8.GetBytes("keep me")).Encode());

        // Reported, but the bytes are consumed, so an older peer is not broken
        // by a newer one using a channel it has never heard of.
        Assert.Throws<FrameException>(() => parser.TryRead(out _, out _));
        Assert.True(parser.TryRead(out var frame, out _));
        Assert.Equal("keep me", Encoding.UTF8.GetString(frame.Payload.Span));
    }

    [Fact]
    public void RejectsANonZeroReservedField()
    {
        var buffer = new byte[8];
        BinaryPrimitives.WriteUInt32BigEndian(buffer, 4);
        buffer[4] = 1;
        buffer[5] = 1;
        buffer[7] = 9;

        var parser = new FrameParser();
        parser.Append(buffer);
        Assert.Throws<FrameException>(() => parser.TryRead(out _, out _));
    }
}

public class SecureChannelTests
{
    private static (SecureChannel Initiator, SecureChannel Responder, SessionKeys Keys) MakePair()
    {
        using var a = new EphemeralKeyPair();
        using var b = new EphemeralKeyPair();
        var shared = a.SharedSecret(b.PublicKey);
        var keys = SessionKeys.Derive(shared,
                                      Enumerable.Repeat((byte)1, 32).ToArray(),
                                      Enumerable.Repeat((byte)2, 32).ToArray());
        return (new SecureChannel(keys, ChannelRole.Initiator),
                new SecureChannel(keys, ChannelRole.Responder),
                keys);
    }

    [Fact]
    public void SealAndOpen()
    {
        var (initiator, responder, _) = MakePair();
        using var _1 = initiator;
        using var _2 = responder;

        var plaintext = Encoding.UTF8.GetBytes("camera.state");
        var parser = new FrameParser();
        parser.Append(initiator.Seal(Channel.Control, plaintext));

        Assert.True(parser.TryRead(out var frame, out var header));
        Assert.Equal(plaintext, responder.Open(header, frame.Payload.Span));
    }

    [Fact]
    public void LengthAccountsForTheTag()
    {
        var (initiator, responder, _) = MakePair();
        using var _1 = initiator;
        using var _2 = responder;

        var plaintext = new byte[64];
        var wire = initiator.Seal(Channel.Video, plaintext);

        Assert.Equal(4 + plaintext.Length + 16,
                     (int)BinaryPrimitives.ReadUInt32BigEndian(wire));
        Assert.Equal(Wire.HeaderSize + plaintext.Length + 16, wire.Length);
    }

    [Fact]
    public void CounterAdvancesAcrossChannels()
    {
        var (initiator, responder, _) = MakePair();
        using var _1 = initiator;
        using var _2 = responder;

        Channel[] channels = [Channel.Control, Channel.Video, Channel.Audio, Channel.Control];
        var parser = new FrameParser();
        foreach (var channel in channels)
        {
            parser.Append(initiator.Seal(channel, Encoding.UTF8.GetBytes($"{(byte)channel}")));
        }

        foreach (var channel in channels)
        {
            Assert.True(parser.TryRead(out var frame, out var header));
            Assert.Equal($"{(byte)channel}",
                         Encoding.UTF8.GetString(responder.Open(header, frame.Payload.Span)));
        }
        Assert.Equal(4ul, initiator.FramesSent);
        Assert.Equal(4ul, responder.FramesReceived);
    }

    [Fact]
    public void AReorderedFrameFailsToOpen()
    {
        var (initiator, responder, _) = MakePair();
        using var _1 = initiator;
        using var _2 = responder;

        var parser = new FrameParser();
        parser.Append(initiator.Seal(Channel.Control, Encoding.UTF8.GetBytes("first")));
        parser.Append(initiator.Seal(Channel.Control, Encoding.UTF8.GetBytes("second")));

        Assert.True(parser.TryRead(out _, out _));
        Assert.True(parser.TryRead(out var second, out var secondHeader));

        // The nonce is bound to the counter, so a frame out of order cannot open.
        Assert.Throws<SecureChannelException>(
            () => responder.Open(secondHeader, second.Payload.Span));
    }

    [Fact]
    public void ATamperedHeaderFailsToOpen()
    {
        var (initiator, responder, _) = MakePair();
        using var _1 = initiator;
        using var _2 = responder;

        var parser = new FrameParser();
        parser.Append(initiator.Seal(Channel.Control, Encoding.UTF8.GetBytes("payload")));
        Assert.True(parser.TryRead(out var frame, out var header));

        header[4] = (byte)Channel.Video;
        Assert.Throws<SecureChannelException>(() => responder.Open(header, frame.Payload.Span));
    }

    [Fact]
    public void DirectionKeysDiffer()
    {
        var (initiator, responder, keys) = MakePair();
        using var _1 = initiator;
        using var _2 = responder;

        Assert.NotEqual(keys.ClientToServerKey, keys.ServerToClientKey);
        Assert.NotEqual(keys.ClientToServerSalt, keys.ServerToClientSalt);
        Assert.Equal(32, keys.ClientToServerKey.Length);
        Assert.Equal(4, keys.ClientToServerSalt.Length);
    }

    [Fact]
    public void PairingDigitsAreSixDigitsAndDeterministic()
    {
        using var a = new EphemeralKeyPair();
        using var b = new EphemeralKeyPair();
        var shared = a.SharedSecret(b.PublicKey);

        var first = SessionKeys.Derive(shared,
                                       Enumerable.Repeat((byte)9, 32).ToArray(),
                                       Enumerable.Repeat((byte)8, 32).ToArray());
        var second = SessionKeys.Derive(shared,
                                        Enumerable.Repeat((byte)9, 32).ToArray(),
                                        Enumerable.Repeat((byte)8, 32).ToArray());

        Assert.Equal(6, first.PairingDigits.Length);
        Assert.All(first.PairingDigits, c => Assert.True(char.IsDigit(c)));
        Assert.Equal(first.PairingDigits, second.PairingDigits);
        Assert.Equal(first.ClientToServerKey, second.ClientToServerKey);
    }

    [Fact]
    public void BothSidesOfAKeyAgreementReachTheSameSecret()
    {
        using var a = new EphemeralKeyPair();
        using var b = new EphemeralKeyPair();
        Assert.Equal(a.SharedSecret(b.PublicKey), b.SharedSecret(a.PublicKey));
    }
}

public class IdentityTests
{
    [Fact]
    public void PublicKeyIsAnUncompressedPoint()
    {
        using var identity = DeviceIdentity.Create();
        var key = identity.PublicKey;
        Assert.Equal(65, key.Length);
        Assert.Equal(0x04, key[0]);
    }

    [Fact]
    public void SignatureVerifies()
    {
        using var identity = DeviceIdentity.Create();
        var message = Encoding.UTF8.GetBytes("iCam/v1/server transcript");
        var signature = identity.Sign(message);

        Assert.True(DeviceIdentity.Verify(signature, message, identity.PublicKey));
        Assert.False(DeviceIdentity.Verify(signature, Encoding.UTF8.GetBytes("different"),
                                           identity.PublicKey));
    }

    [Fact]
    public void FingerprintIsStableAndShort()
    {
        using var identity = DeviceIdentity.Create();
        Assert.Equal(32, identity.Fingerprint.Length);
        Assert.Equal(identity.Fingerprint, DeviceIdentity.FingerprintOf(identity.PublicKey));
    }

    [Fact]
    public void SurvivesAnExportAndImport()
    {
        using var original = DeviceIdentity.Create();
        var exported = original.ExportPrivateKey();

        using var restored = DeviceIdentity.FromPrivateKey(exported);
        Assert.Equal(original.PublicKey, restored.PublicKey);
        Assert.Equal(original.Fingerprint, restored.Fingerprint);
    }

    [Fact]
    public void RejectsAMalformedPublicKey()
    {
        using var identity = DeviceIdentity.Create();
        var signature = identity.Sign(Encoding.UTF8.GetBytes("x"));
        Assert.False(DeviceIdentity.Verify(signature, Encoding.UTF8.GetBytes("x"), new byte[10]));
    }
}

public class HandshakeCodecTests
{
    [Fact]
    public void HandshakeJsonHasSortedKeysAndNoEscapedSlashes()
    {
        var hello = new ClientHello
        {
            Eph = [4, 1, 2],
            Idk = [4, 3, 4],
            Rnd = [5],
            Dev = new DeviceInfo { Name = "a/b", Model = "m", Os = "18.5", App = "1.0", Id = "ff" },
        };

        var text = Encoding.UTF8.GetString(HandshakeCodec.Encode(hello));

        Assert.DoesNotContain("\\/", text);
        // Sorted: dev, eph, idk, rnd, t, v — matching Swift's `.sortedKeys`.
        string[] order = ["\"dev\"", "\"eph\"", "\"idk\"", "\"rnd\"", "\"t\"", "\"v\""];
        var cursor = 0;
        foreach (var key in order)
        {
            var found = text.IndexOf(key, cursor, StringComparison.Ordinal);
            Assert.True(found >= 0, $"{key} missing or out of order in {text}");
            cursor = found + key.Length;
        }
    }

    [Fact]
    public void NonAsciiDeviceNamesAreWrittenAsUtf8()
    {
        // Swift writes these raw. If System.Text.Json escaped them as \uXXXX,
        // the transcripts would differ and every handshake would fail for
        // anyone whose phone is not named in English.
        var hello = new ClientHello
        {
            Dev = new DeviceInfo { Name = "آيفون راعد", Model = "iPhone16,1" },
        };
        var text = Encoding.UTF8.GetString(HandshakeCodec.Encode(hello));
        Assert.Contains("آيفون راعد", text);
        Assert.DoesNotContain("\\u", text);
    }

    [Fact]
    public void TranscriptBytesOmitTheSignature()
    {
        var hello = new ServerHello
        {
            Eph = [4], Idk = [4], Rnd = [1],
            Dev = new DeviceInfo { Name = "RAEID-PC", Model = "Windows 11" },
            Sig = [9, 9, 9],
        };

        var text = Encoding.UTF8.GetString(hello.TranscriptBytes());
        Assert.DoesNotContain("\"sig\"", text);
    }

    [Fact]
    public void MessageTypePeeksWithoutFullDecoding()
    {
        var bytes = HandshakeCodec.Encode(new ClientAuth { Sig = [1, 2, 3] });
        Assert.Equal("auth", HandshakeCodec.MessageType(bytes));
        Assert.Null(HandshakeCodec.MessageType("not json"u8));
    }
}

public class HandshakeFlowTests
{
    /// <summary>
    /// Plays the initiator's part exactly as the Swift side does, so this test
    /// covers the responder against the real message order rather than against
    /// a convenient stub.
    /// </summary>
    [Fact]
    public void CompletesAgainstAFaithfulInitiator()
    {
        using var phoneIdentity = DeviceIdentity.Create();
        using var pcIdentity = DeviceIdentity.Create();
        using var phoneEphemeral = new EphemeralKeyPair();

        var clientRandom = Enumerable.Repeat((byte)3, 32).ToArray();
        var hello = new ClientHello
        {
            Eph = phoneEphemeral.PublicKey,
            Idk = phoneIdentity.PublicKey,
            Rnd = clientRandom,
            Dev = new DeviceInfo { Name = "Raeid's iPhone", Model = "iPhone16,1" },
        };
        var helloBytes = HandshakeCodec.Encode(hello);

        using var responder = new ResponderHandshake(
            pcIdentity, new DeviceInfo { Name = "RAEID-PC", Model = "Windows 11" });
        var serverHelloBytes = responder.HandleClientHello(helloBytes);

        var serverHello = HandshakeCodec.Decode<ServerHello>(serverHelloBytes)!;
        Assert.NotNull(serverHello.Sig);

        // Rebuild the transcript the way the phone does, and check the PC's
        // signature over it.
        var transcript = helloBytes.Concat(serverHello.TranscriptBytes()).ToArray();
        Assert.True(DeviceIdentity.Verify(
            serverHello.Sig!,
            Encoding.UTF8.GetBytes("iCam/v1/server").Concat(transcript).ToArray(),
            serverHello.Idk));

        var auth = new ClientAuth
        {
            Sig = phoneIdentity.Sign(
                Encoding.UTF8.GetBytes("iCam/v1/client").Concat(transcript).ToArray()),
        };
        responder.HandleClientAuth(HandshakeCodec.Encode(auth));

        // Both sides must land on the same keys and the same six digits.
        var phoneKeys = SessionKeys.Derive(phoneEphemeral.SharedSecret(serverHello.Eph),
                                           clientRandom, serverHello.Rnd);
        Assert.Equal(phoneKeys.PairingDigits, responder.Keys!.PairingDigits);
        Assert.Equal(phoneKeys.ClientToServerKey, responder.Keys!.ClientToServerKey);
        Assert.Equal(phoneIdentity.PublicKey, responder.PeerIdentityKey);
    }

    [Fact]
    public void RejectsATamperedClientSignature()
    {
        using var phoneIdentity = DeviceIdentity.Create();
        using var pcIdentity = DeviceIdentity.Create();
        using var phoneEphemeral = new EphemeralKeyPair();

        var helloBytes = HandshakeCodec.Encode(new ClientHello
        {
            Eph = phoneEphemeral.PublicKey,
            Idk = phoneIdentity.PublicKey,
            Rnd = Enumerable.Repeat((byte)3, 32).ToArray(),
        });

        using var responder = new ResponderHandshake(pcIdentity, new DeviceInfo());
        responder.HandleClientHello(helloBytes);

        var auth = new ClientAuth { Sig = phoneIdentity.Sign("something else"u8) };
        var error = Assert.Throws<HandshakeException>(
            () => responder.HandleClientAuth(HandshakeCodec.Encode(auth)));
        Assert.Equal(HandshakeException.Reason.BadSignature, error.Kind);
    }

    [Fact]
    public void RejectsAMismatchedProtocolVersion()
    {
        using var pcIdentity = DeviceIdentity.Create();
        using var responder = new ResponderHandshake(pcIdentity, new DeviceInfo());

        var helloBytes = HandshakeCodec.Encode(new ClientHello { V = 99 });
        var error = Assert.Throws<HandshakeException>(
            () => responder.HandleClientHello(helloBytes));
        Assert.Equal(HandshakeException.Reason.VersionMismatch, error.Kind);
    }
}

public class MediaFrameTests
{
    [Fact]
    public void VideoHeaderRoundTrip()
    {
        var header = new VideoFrameHeader(VideoCodec.Hevc, true, false, false,
                                          1234, 987_654_321, 987_654_000);
        var encoded = header.Encode();
        Assert.Equal(VideoFrameHeader.Size, encoded.Length);

        var withBody = encoded.Concat<byte>([1, 2, 3, 4]).ToArray();
        Assert.True(VideoFrameHeader.TryDecode(withBody, out var decoded, out var body));
        Assert.Equal(header, decoded);
        Assert.Equal<byte>([1, 2, 3, 4], body.ToArray());
    }

    [Fact]
    public void AudioHeaderRoundTrip()
    {
        var header = new AudioFrameHeader(AudioCodec.PcmS16Le, 1, false, 48_000, 7, 42);
        var encoded = header.Encode();
        Assert.Equal(AudioFrameHeader.Size, encoded.Length);

        var withBody = encoded.Concat(new byte[8]).ToArray();
        Assert.True(AudioFrameHeader.TryDecode(withBody, out var decoded, out var body));
        Assert.Equal(header, decoded);
        Assert.Equal(8, body.Length);
    }

    [Fact]
    public void BulkHeaderRoundTrip()
    {
        var header = new BulkFrameHeader(BulkKind.Chunk, 3, 1_048_576);
        var encoded = header.Encode();
        Assert.Equal(BulkFrameHeader.Size, encoded.Length);

        var withBody = encoded.Concat<byte>([0xAB]).ToArray();
        Assert.True(BulkFrameHeader.TryDecode(withBody, out var decoded, out var body));
        Assert.Equal(header, decoded);
        Assert.Equal<byte>([0xAB], body.ToArray());
    }

    [Fact]
    public void RejectsAnUnknownVideoCodec()
    {
        var buffer = new byte[VideoFrameHeader.Size];
        buffer[0] = 9;
        Assert.False(VideoFrameHeader.TryDecode(buffer, out _, out _));
    }
}

public class ControlCodecTests
{
    [Fact]
    public void EnvelopeRoundTrip()
    {
        var profile = StreamProfile.Webcam1080p30;
        var data = ControlCodec.Encode(ControlType.StreamStart, 9,
                                       new StreamStartPayload { Profile = profile });

        var envelope = ControlCodec.DecodeEnvelope(data)!;
        Assert.Equal(ControlType.StreamStart, envelope.T);
        Assert.Equal(9u, envelope.Id);
        Assert.Null(envelope.R);

        var payload = ControlCodec.Payload<StreamStartPayload>(envelope)!;
        Assert.Equal(profile, payload.Profile);
    }

    [Fact]
    public void EnumsCrossTheWireAsTheStringsTheSpecNames()
    {
        var state = new CameraState
        {
            Codec = VideoCodec.Hevc,
            Hdr = HdrMode.Auto,
            FocusMode = FocusMode.Continuous,
            Stabilization = Stabilization.CinematicExtended,
        };
        var text = JsonSerializer.Serialize(state, ControlCodec.Options);

        Assert.Contains("\"codec\":\"hevc\"", text);
        Assert.Contains("\"hdr\":\"auto\"", text);
        Assert.Contains("\"focusMode\":\"continuous\"", text);
        Assert.Contains("\"stabilization\":\"cinematicExtended\"", text);
    }

    [Fact]
    public void AMutationOnlySerialisesWhatWasTouched()
    {
        var mutation = new CameraMutation { Iso = 400, ExposureMode = ExposureMode.Manual };
        var text = JsonSerializer.Serialize(mutation, ControlCodec.Options);

        Assert.Contains("\"iso\":400", text);
        Assert.Contains("\"exposureMode\":\"manual\"", text);
        // Absent keys are what stop a stale slider from reverting an unrelated
        // setting the user just changed on the phone.
        Assert.DoesNotContain("temperature", text);
        Assert.DoesNotContain("lensId", text);
    }

    [Fact]
    public void APayloadOfTheWrongShapeReturnsNullRatherThanThrowing()
    {
        // A malformed message must never take the connection down. Anything
        // the receiver cannot read is dropped, and the sender's request simply
        // times out into a real error.
        var data = ControlCodec.Encode("record.start", 1, new { sessionId = 12345 });
        var envelope = ControlCodec.DecodeEnvelope(data)!;
        Assert.Null(ControlCodec.Payload<RecordStartPayload>(envelope));
    }

    [Fact]
    public void UnknownPropertiesAreIgnoredRatherThanRejected()
    {
        // The other direction of the same rule: a newer peer adding a field
        // must not break an older one that has never heard of it.
        var data = ControlCodec.Encode("record.start", 1,
            new { sessionId = "20260820-120000", target = "both",
                  startedAtUs = 42UL, somethingNewer = true });
        var envelope = ControlCodec.DecodeEnvelope(data)!;

        var payload = ControlCodec.Payload<RecordStartPayload>(envelope)!;
        Assert.Equal("20260820-120000", payload.SessionId);
        Assert.Equal(CaptureTarget.Both, payload.Target);
    }

    [Fact]
    public void CameraStateDecodesWhatThePhoneWouldSend()
    {
        // Written the way the Swift encoder emits it, keys and all.
        const string json = """
        {"v":184,"lensId":"back.wide","zoom":1.0,"lensLocked":false,
         "width":1920,"height":1080,"fps":30,"codec":"hevc","hdr":"auto",
         "stabilization":"standard","exposureMode":"manual","iso":80,
         "exposureDurationUs":8333,"ev":0.0,"exposureLocked":false,
         "whiteBalanceMode":"auto","whiteBalancePreset":"auto","temperature":4800,
         "tint":0,"focusMode":"continuous","focusPosition":0.42,"focusLocked":false,
         "faceDrivenFocus":true,"torch":"off","torchLevel":1.0,"mirrored":false,
         "orientation":"auto","brightness":0,"contrast":0,"saturation":0,"sharpness":0}
        """;

        var state = JsonSerializer.Deserialize<CameraState>(json, ControlCodec.Options)!;
        Assert.Equal(184ul, state.Version);
        Assert.Equal("back.wide", state.LensId);
        Assert.Equal(VideoCodec.Hevc, state.Codec);
        Assert.Equal(ExposureMode.Manual, state.ExposureMode);
        Assert.Equal(120, state.ShutterDenominator);
    }
}

public class CapabilityTests
{
    private static CameraCapabilities Make() => new()
    {
        Lenses =
        [
            new LensCapability { Id = "back.wide", Label = "1", Position = "back",
                                 MinZoom = 1, MaxZoom = 3 },
        ],
        Formats =
        [
            new FormatCapability
            {
                LensId = "back.wide", Width = 1920, Height = 1080,
                FpsRanges = [[1, 60]], Hdr = true,
            },
            new FormatCapability
            {
                LensId = "back.wide", Width = 3840, Height = 2160,
                FpsRanges = [[1, 30]], Hdr = true,
            },
        ],
    };

    [Fact]
    public void ResolutionsAreLargestFirst()
    {
        var resolutions = Make().ResolutionsFor("back.wide");
        Assert.Equal((3840, 2160), resolutions[0]);
        Assert.Equal(2, resolutions.Count);
    }

    [Fact]
    public void FrameRatesAreNotAssumedUniformAcrossResolutions()
    {
        var caps = Make();
        Assert.Contains(60, caps.FrameRatesFor("back.wide", 1920, 1080));
        // 4K tops out at 30 on this device. Offering 60 would be a lie.
        Assert.DoesNotContain(60, caps.FrameRatesFor("back.wide", 3840, 2160));
    }

    [Fact]
    public void AnUnknownLensYieldsNothingRatherThanADefault()
    {
        var caps = Make();
        Assert.Empty(caps.ResolutionsFor("back.periscope"));
        Assert.Empty(caps.FrameRatesFor("back.periscope", 1920, 1080));
    }
}
