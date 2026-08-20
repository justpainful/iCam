using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace ICam.Core.Protocol;

/// <summary>Message type names — <c>docs/PROTOCOL.md</c> section 5.1.</summary>
public static class ControlType
{
    public const string DeviceInfo = "device.info";
    public const string Capabilities = "camera.capabilities";
    public const string CameraState = "camera.state";
    public const string CameraCommand = "camera.command";
    public const string CameraCommandResult = "camera.command.result";

    public const string StreamStart = "stream.start";
    public const string StreamStop = "stream.stop";
    public const string StreamConfig = "stream.config";
    public const string StreamStatus = "stream.status";
    /// <summary>PC → phone: the decoder lost its place; send an IDR now.</summary>
    public const string StreamKeyframe = "stream.keyframe";

    public const string RecordStart = "record.start";
    public const string RecordStop = "record.stop";
    public const string RecordState = "record.state";
    public const string PhotoCapture = "photo.capture";
    public const string PhotoResult = "photo.result";

    public const string Telemetry = "telemetry";
    public const string TimePing = "time.ping";
    public const string TimePong = "time.pong";
    public const string Error = "error";
}

/// <summary>The control envelope. Deliberately tiny.</summary>
public sealed class ControlEnvelope
{
    [JsonPropertyName("id")] public uint Id { get; set; }
    [JsonPropertyName("p")] public JsonNode? P { get; set; }
    [JsonPropertyName("r")] public uint? R { get; set; }
    [JsonPropertyName("t")] public string T { get; set; } = "";
}

public static class ControlCodec
{
    public static readonly JsonSerializerOptions Options = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = false,
    };

    public static byte[] Encode<T>(string type, uint id, T payload, uint? replyTo = null)
    {
        var envelope = new ControlEnvelope
        {
            T = type,
            Id = id,
            R = replyTo,
            P = JsonSerializer.SerializeToNode(payload, Options),
        };
        return JsonSerializer.SerializeToUtf8Bytes(envelope, Options);
    }

    public static byte[] EncodeEmpty(string type, uint id, uint? replyTo = null)
    {
        var envelope = new ControlEnvelope
        {
            T = type, Id = id, R = replyTo, P = new JsonObject(),
        };
        return JsonSerializer.SerializeToUtf8Bytes(envelope, Options);
    }

    public static ControlEnvelope? DecodeEnvelope(ReadOnlySpan<byte> data) =>
        JsonSerializer.Deserialize<ControlEnvelope>(data, Options);

    /// <summary>
    /// Reads a typed payload. Returns <c>null</c> rather than throwing when the
    /// payload does not match: an unrecognised or malformed message must never
    /// take the connection down.
    /// </summary>
    public static T? Payload<T>(ControlEnvelope envelope) where T : class
    {
        if (envelope.P is null) return null;
        try
        {
            return envelope.P.Deserialize<T>(Options);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

// MARK: - Payloads

public sealed class CameraCommandPayload
{
    [JsonPropertyName("base")] public ulong Base { get; set; }
    [JsonPropertyName("set")] public CameraMutation Set { get; set; } = new();
}

public sealed class CameraCommandResult
{
    [JsonPropertyName("appliedVersion")] public ulong AppliedVersion { get; set; }
    [JsonPropertyName("error")] public ProtocolError? Error { get; set; }
    [JsonPropertyName("ok")] public bool Ok { get; set; }
}

public sealed class StreamStartPayload
{
    [JsonPropertyName("profile")] public StreamProfile Profile { get; set; } = new();
}

public sealed class StreamStatusPayload
{
    [JsonPropertyName("active")] public bool Active { get; set; }
    [JsonPropertyName("actual")] public StreamProfile Actual { get; set; } = new();
    [JsonPropertyName("reason")] public string? Reason { get; set; }
}

public sealed class RecordStartPayload
{
    [JsonPropertyName("sessionId")] public string SessionId { get; set; } = "";
    [JsonPropertyName("startedAtUs")] public ulong StartedAtUs { get; set; }
    [JsonPropertyName("target")] public CaptureTarget Target { get; set; }
}

public sealed class RecordStopPayload
{
    [JsonPropertyName("sessionId")] public string SessionId { get; set; } = "";
}

public sealed class RecordStatePayload
{
    [JsonPropertyName("elapsedUs")] public ulong ElapsedUs { get; set; }
    [JsonPropertyName("pcOk")] public bool PcOk { get; set; }
    [JsonPropertyName("phoneOk")] public bool PhoneOk { get; set; }
    [JsonPropertyName("recording")] public bool Recording { get; set; }
    [JsonPropertyName("sessionId")] public string? SessionId { get; set; }
    [JsonPropertyName("target")] public CaptureTarget Target { get; set; }
}

public sealed class PhotoCapturePayload
{
    [JsonPropertyName("requestId")] public uint RequestId { get; set; }
    [JsonPropertyName("target")] public CaptureTarget Target { get; set; }
}

public sealed class PhotoResultPayload
{
    [JsonPropertyName("assetId")] public string? AssetId { get; set; }
    [JsonPropertyName("error")] public ProtocolError? Error { get; set; }
    [JsonPropertyName("ok")] public bool Ok { get; set; }
    [JsonPropertyName("requestId")] public uint RequestId { get; set; }
    [JsonPropertyName("transferId")] public uint? TransferId { get; set; }
}

public sealed class TelemetryPayload
{
    [JsonPropertyName("battery")] public double Battery { get; set; }
    [JsonPropertyName("capture")] public CaptureStats Capture { get; set; } = new();
    [JsonPropertyName("encoder")] public EncoderStats Encoder { get; set; } = new();
    [JsonPropertyName("power")] public string Power { get; set; } = "battery";
    [JsonPropertyName("pressure")] public string Pressure { get; set; } = "nominal";
    [JsonPropertyName("storageFreeBytes")] public ulong StorageFreeBytes { get; set; }

    /// <summary>
    /// One of <c>normal</c>, <c>elevated</c>, <c>high</c>, <c>critical</c>.
    /// Never a temperature: iOS publishes no sensor for one, so iCam does not
    /// invent a number to display.
    /// </summary>
    [JsonPropertyName("thermal")] public string Thermal { get; set; } = "normal";

    public sealed class CaptureStats
    {
        [JsonPropertyName("dropped")] public ulong Dropped { get; set; }
        [JsonPropertyName("fps")] public double Fps { get; set; }
    }

    public sealed class EncoderStats
    {
        [JsonPropertyName("bitrate")] public int Bitrate { get; set; }
        [JsonPropertyName("fps")] public double Fps { get; set; }
        [JsonPropertyName("latencyUs")] public ulong LatencyUs { get; set; }
    }
}

public sealed class TimePingPayload
{
    [JsonPropertyName("t1")] public ulong T1 { get; set; }
}

public sealed class TimePongPayload
{
    [JsonPropertyName("t1")] public ulong T1 { get; set; }
    [JsonPropertyName("t2")] public ulong T2 { get; set; }
    [JsonPropertyName("t3")] public ulong T3 { get; set; }
}

public sealed class ProtocolError
{
    [JsonPropertyName("code")] public string Code { get; set; } = "";
    [JsonPropertyName("detail")] public string? Detail { get; set; }

    /// <summary>Already-localised, human text. The receiving interface shows it as-is.</summary>
    [JsonPropertyName("message")] public string Message { get; set; } = "";
}

// MARK: - Capabilities

public sealed class CameraCapabilities
{
    [JsonPropertyName("focus")] public FocusCapability Focus { get; set; } = new();
    [JsonPropertyName("formats")] public List<FormatCapability> Formats { get; set; } = [];
    [JsonPropertyName("lenses")] public List<LensCapability> Lenses { get; set; } = [];
    [JsonPropertyName("multiCam")] public MultiCamCapability MultiCam { get; set; } = new();
    [JsonPropertyName("torch")] public TorchCapability Torch { get; set; } = new();
    [JsonPropertyName("whiteBalance")] public WhiteBalanceCapability WhiteBalance { get; set; } = new();

    public IEnumerable<FormatCapability> FormatsFor(string lensId) =>
        Formats.Where(f => f.LensId == lensId);

    /// <summary>Distinct resolutions on a lens, largest first.</summary>
    public List<(int Width, int Height)> ResolutionsFor(string lensId) =>
        FormatsFor(lensId)
            .Select(f => (f.Width, f.Height))
            .Distinct()
            .OrderByDescending(r => r.Width * r.Height)
            .ToList();

    /// <summary>
    /// Frame rates available at one resolution. Never assume every resolution
    /// supports every rate — on most iPhones, 4K does not reach 120.
    /// </summary>
    public List<int> FrameRatesFor(string lensId, int width, int height)
    {
        int[] candidates = [24, 25, 30, 50, 60, 120, 240];
        var matching = FormatsFor(lensId).Where(f => f.Width == width && f.Height == height).ToList();
        return candidates
            .Where(rate => matching.Any(f => f.FpsRanges.Any(
                r => r.Count == 2 && rate >= r[0] - 0.01 && rate <= r[1] + 0.01)))
            .ToList();
    }
}

public sealed class LensCapability
{
    [JsonPropertyName("baseZoom")] public double BaseZoom { get; set; } = 1;
    [JsonPropertyName("deviceType")] public string DeviceType { get; set; } = "";
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("label")] public string Label { get; set; } = "";
    [JsonPropertyName("maxZoom")] public double MaxZoom { get; set; }
    [JsonPropertyName("minZoom")] public double MinZoom { get; set; }
    [JsonPropertyName("position")] public string Position { get; set; } = "back";
    [JsonPropertyName("supportsMultiCam")] public bool SupportsMultiCam { get; set; }
    [JsonPropertyName("switchOverZoom")] public List<double> SwitchOverZoom { get; set; } = [];
}

public sealed class FormatCapability
{
    [JsonPropertyName("codecs")] public List<VideoCodec> Codecs { get; set; } = [];
    [JsonPropertyName("exposureDurationUsRange")] public List<int> ExposureDurationUsRange { get; set; } = [];
    [JsonPropertyName("fpsRanges")] public List<List<double>> FpsRanges { get; set; } = [];
    [JsonPropertyName("hdr")] public bool Hdr { get; set; }
    [JsonPropertyName("height")] public int Height { get; set; }
    [JsonPropertyName("isMultiCamSupported")] public bool IsMultiCamSupported { get; set; }
    [JsonPropertyName("isoRange")] public List<double> IsoRange { get; set; } = [];
    [JsonPropertyName("lensId")] public string LensId { get; set; } = "";
    [JsonPropertyName("maxPhotoDimensions")] public List<int> MaxPhotoDimensions { get; set; } = [];
    [JsonPropertyName("stabilization")] public List<Stabilization> Stabilization { get; set; } = [];
    [JsonPropertyName("supportsRaw")] public bool SupportsRaw { get; set; }
    [JsonPropertyName("width")] public int Width { get; set; }
}

public sealed class TorchCapability
{
    [JsonPropertyName("levelAdjustable")] public bool LevelAdjustable { get; set; }
    [JsonPropertyName("supported")] public bool Supported { get; set; }
}

public sealed class WhiteBalanceCapability
{
    [JsonPropertyName("supported")] public bool Supported { get; set; }
    [JsonPropertyName("temperatureRange")] public List<double> TemperatureRange { get; set; } = [2000, 10000];
    [JsonPropertyName("tintRange")] public List<double> TintRange { get; set; } = [-150, 150];
}

public sealed class FocusCapability
{
    [JsonPropertyName("faceDriven")] public bool FaceDriven { get; set; }
    [JsonPropertyName("manual")] public bool Manual { get; set; }
    [JsonPropertyName("pointOfInterest")] public bool PointOfInterest { get; set; }
}

public sealed class MultiCamCapability
{
    [JsonPropertyName("combinations")] public List<List<string>> Combinations { get; set; } = [];
    [JsonPropertyName("supported")] public bool Supported { get; set; }
}
