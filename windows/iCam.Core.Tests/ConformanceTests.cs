using System.Text;
using System.Text.Json;
using ICam.Core.Protocol;
using ICam.Core.Security;
using Xunit;

namespace ICam.Core.Tests;

/// <summary>
/// Verifies this implementation against <c>protocol/vectors/v1.json</c>.
///
/// The vectors are generated from this code, so on their own these tests only
/// prove the file is current. Their real value is the pair: the Swift tests run
/// the same file, so a change here that the phone would not accept shows up as
/// a red iOS build rather than as two devices that will not pair.
/// </summary>
public class ConformanceTests
{
    private static readonly JsonDocument Vectors = LoadVectors();

    private static JsonDocument LoadVectors()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, "protocol", "vectors", "v1.json");
            if (File.Exists(candidate))
            {
                return JsonDocument.Parse(File.ReadAllBytes(candidate));
            }
            directory = directory.Parent;
        }
        throw new FileNotFoundException(
            "protocol/vectors/v1.json not found. Run: dotnet run --project tools/ProtocolVectors");
    }

    private static JsonElement Section(string name) => Vectors.RootElement.GetProperty(name);

    [Fact]
    public void FramingMatchesTheVectors()
    {
        foreach (var testCase in Section("framing").EnumerateArray())
        {
            var channel = (Channel)testCase.GetProperty("channel").GetInt32();
            var flags = (FrameFlags)testCase.GetProperty("flags").GetInt32();
            var payload = Convert.FromHexString(testCase.GetProperty("payloadHex").GetString()!);
            var expected = Convert.FromHexString(testCase.GetProperty("frameHex").GetString()!);

            Assert.Equal(expected, new Frame(channel, flags, payload).Encode());

            var parser = new FrameParser();
            parser.Append(expected);
            Assert.True(parser.TryRead(out var frame, out _));
            Assert.Equal(channel, frame.Channel);
            Assert.Equal(payload, frame.Payload.ToArray());
        }
    }

    [Fact]
    public void KeyScheduleMatchesTheVectors()
    {
        var vector = Section("keySchedule");
        var keys = SessionKeys.Derive(
            Convert.FromHexString(vector.GetProperty("sharedSecretHex").GetString()!),
            Convert.FromHexString(vector.GetProperty("clientRandomHex").GetString()!),
            Convert.FromHexString(vector.GetProperty("serverRandomHex").GetString()!));

        Assert.Equal(vector.GetProperty("c2sKeyHex").GetString(),
                     Convert.ToHexStringLower(keys.ClientToServerKey));
        Assert.Equal(vector.GetProperty("s2cKeyHex").GetString(),
                     Convert.ToHexStringLower(keys.ServerToClientKey));
        Assert.Equal(vector.GetProperty("c2sSaltHex").GetString(),
                     Convert.ToHexStringLower(keys.ClientToServerSalt));
        Assert.Equal(vector.GetProperty("s2cSaltHex").GetString(),
                     Convert.ToHexStringLower(keys.ServerToClientSalt));
        Assert.Equal(vector.GetProperty("pairingDigits").GetString(), keys.PairingDigits);
    }

    [Fact]
    public void AeadMatchesTheVectors()
    {
        var schedule = Section("keySchedule");
        var keys = SessionKeys.Derive(
            Convert.FromHexString(schedule.GetProperty("sharedSecretHex").GetString()!),
            Convert.FromHexString(schedule.GetProperty("clientRandomHex").GetString()!),
            Convert.FromHexString(schedule.GetProperty("serverRandomHex").GetString()!));

        using var sender = new SecureChannel(keys, ChannelRole.Initiator);
        foreach (var testCase in Section("aead").EnumerateArray())
        {
            var channel = (Channel)testCase.GetProperty("channel").GetInt32();
            var plaintext = Convert.FromHexString(testCase.GetProperty("plaintextHex").GetString()!);
            var expected = Convert.FromHexString(testCase.GetProperty("frameHex").GetString()!);
            Assert.Equal(expected, sender.Seal(channel, plaintext));
        }
    }

    [Fact]
    public void TheResponderDirectionOpensWhatTheVectorsSealed()
    {
        var schedule = Section("keySchedule");
        var keys = SessionKeys.Derive(
            Convert.FromHexString(schedule.GetProperty("sharedSecretHex").GetString()!),
            Convert.FromHexString(schedule.GetProperty("clientRandomHex").GetString()!),
            Convert.FromHexString(schedule.GetProperty("serverRandomHex").GetString()!));

        using var receiver = new SecureChannel(keys, ChannelRole.Responder);
        var parser = new FrameParser();

        foreach (var testCase in Section("aead").EnumerateArray())
        {
            parser.Append(Convert.FromHexString(testCase.GetProperty("frameHex").GetString()!));
            Assert.True(parser.TryRead(out var frame, out var header));
            var opened = receiver.Open(header, frame.Payload.Span);
            Assert.Equal(testCase.GetProperty("plaintextHex").GetString(),
                         Convert.ToHexStringLower(opened));
        }
    }

    [Fact]
    public void ClientHelloIsByteIdenticalToTheVector()
    {
        var vector = Section("handshakeJson").EnumerateArray()
            .First(c => c.GetProperty("name").GetString() == "client hello");
        var expected = Convert.FromHexString(vector.GetProperty("encodedUtf8Hex").GetString()!);

        var hello = new ClientHello
        {
            Eph = Enumerable.Range(0, 65).Select(i => (byte)(i == 0 ? 0x04 : i)).ToArray(),
            Idk = Enumerable.Range(0, 65).Select(i => (byte)(i == 0 ? 0x04 : 200 - i)).ToArray(),
            Rnd = Enumerable.Range(0, 32).Select(i => (byte)(0xA0 + i)).ToArray(),
            Dev = new DeviceInfo
            {
                App = "1.0.0",
                Id = "0123456789abcdef0123456789abcdef",
                Model = "iPhone16,1",
                Name = "آيفون Raeid a/b",
                Os = "18.5",
            },
        };

        Assert.Equal(Encoding.UTF8.GetString(expected),
                     Encoding.UTF8.GetString(HandshakeCodec.Encode(hello)));
    }

    [Fact]
    public void ServerHelloTranscriptBytesAreByteIdenticalToTheVector()
    {
        var vector = Section("handshakeJson").EnumerateArray()
            .First(c => c.GetProperty("name").GetString() == "server hello transcript bytes");
        var expected = Convert.FromHexString(vector.GetProperty("encodedUtf8Hex").GetString()!);

        var hello = new ServerHello
        {
            Eph = Enumerable.Range(0, 65).Select(i => (byte)(i == 0 ? 0x04 : i + 3)).ToArray(),
            Idk = Enumerable.Range(0, 65).Select(i => (byte)(i == 0 ? 0x04 : i + 9)).ToArray(),
            Rnd = Enumerable.Range(0, 32).Select(i => (byte)(0x10 + i * 3)).ToArray(),
            Dev = new DeviceInfo
            {
                App = "1.0.0",
                Id = "fedcba9876543210fedcba9876543210",
                Model = "Windows 11 Pro",
                Name = "RAEID-PC",
                Os = "10.0.26200",
            },
            Sig = [1, 2, 3, 4],
        };

        Assert.Equal(expected, hello.TranscriptBytes());
    }

    [Fact]
    public void MediaHeadersMatchTheVectors()
    {
        foreach (var testCase in Section("mediaHeaders").EnumerateArray())
        {
            var expected = Convert.FromHexString(testCase.GetProperty("headerHex").GetString()!);

            switch (testCase.GetProperty("kind").GetString())
            {
                case "video":
                    var video = new VideoFrameHeader(
                        testCase.GetProperty("codec").GetString() == "hevc"
                            ? VideoCodec.Hevc : VideoCodec.H264,
                        testCase.GetProperty("isKeyframe").GetBoolean(),
                        testCase.GetProperty("isParameterSets").GetBoolean(),
                        false,
                        testCase.GetProperty("sequence").GetUInt32(),
                        testCase.GetProperty("ptsUs").GetUInt64(),
                        testCase.GetProperty("dtsUs").GetUInt64());
                    Assert.Equal(expected, video.Encode());
                    break;

                case "audio":
                    var audio = new AudioFrameHeader(
                        AudioCodec.PcmS16Le,
                        (byte)testCase.GetProperty("channels").GetInt32(),
                        false,
                        testCase.GetProperty("sampleRate").GetUInt32(),
                        testCase.GetProperty("sequence").GetUInt32(),
                        testCase.GetProperty("ptsUs").GetUInt64());
                    Assert.Equal(expected, audio.Encode());
                    break;

                case "bulk":
                    var bulk = new BulkFrameHeader(
                        BulkKind.Chunk,
                        testCase.GetProperty("transferId").GetUInt32(),
                        testCase.GetProperty("offset").GetUInt64());
                    Assert.Equal(expected, bulk.Encode());
                    break;

                default:
                    Assert.Fail("unknown media header kind");
                    break;
            }
        }
    }

    [Fact]
    public void ControlPayloadsRoundTripThroughTheVectors()
    {
        foreach (var testCase in Section("controlJson").EnumerateArray())
        {
            var json = testCase.GetProperty("json").GetRawText();

            switch (testCase.GetProperty("name").GetString())
            {
                case "camera.state":
                    var state = JsonSerializer.Deserialize<CameraState>(json, ControlCodec.Options)!;
                    Assert.Equal(184ul, state.Version);
                    Assert.Equal(VideoCodec.Hevc, state.Codec);
                    Assert.Equal(120, state.ShutterDenominator);
                    Assert.Equal(0.25, state.Brightness);
                    Assert.Equal(0.35, state.Warmth);
                    Assert.Equal(-0.2, state.Sharpness);
                    Assert.Equal(0.6, state.LowLight);
                    Assert.Equal(0.4, state.Beauty);
                    // Re-encoding must produce the same tree, so the phone can
                    // echo a state without altering it.
                    Assert.Equal(
                        JsonSerializer.Serialize(
                            JsonSerializer.Deserialize<CameraState>(json, ControlCodec.Options),
                            ControlCodec.Options),
                        JsonSerializer.Serialize(state, ControlCodec.Options));
                    break;

                case "camera.command":
                    var command = JsonSerializer.Deserialize<CameraCommandPayload>(
                        json, ControlCodec.Options)!;
                    Assert.Equal(184ul, command.Base);
                    Assert.Equal(200, command.Set.Iso);
                    Assert.Null(command.Set.Temperature);
                    break;

                case "telemetry":
                    var telemetry = JsonSerializer.Deserialize<TelemetryPayload>(
                        json, ControlCodec.Options)!;
                    Assert.Equal("elevated", telemetry.Thermal);
                    Assert.Equal("usb", telemetry.Power);
                    // There is no temperature in the protocol, and there must
                    // not be: iOS publishes no sensor for one.
                    Assert.DoesNotContain("temp", json, StringComparison.OrdinalIgnoreCase);
                    break;
            }
        }
    }
}
