using System.Text.Json.Serialization;

namespace ICam.Core.Protocol;

[JsonConverter(typeof(JsonStringEnumConverter<VideoCodec>))]
public enum VideoCodec { [JsonStringEnumMemberName("h264")] H264, [JsonStringEnumMemberName("hevc")] Hevc }

[JsonConverter(typeof(JsonStringEnumConverter<HdrMode>))]
public enum HdrMode { [JsonStringEnumMemberName("off")] Off, [JsonStringEnumMemberName("auto")] Auto, [JsonStringEnumMemberName("on")] On }

[JsonConverter(typeof(JsonStringEnumConverter<ExposureMode>))]
public enum ExposureMode { [JsonStringEnumMemberName("auto")] Auto, [JsonStringEnumMemberName("manual")] Manual }

[JsonConverter(typeof(JsonStringEnumConverter<WhiteBalanceMode>))]
public enum WhiteBalanceMode { [JsonStringEnumMemberName("auto")] Auto, [JsonStringEnumMemberName("manual")] Manual }

[JsonConverter(typeof(JsonStringEnumConverter<FocusMode>))]
public enum FocusMode
{
    [JsonStringEnumMemberName("continuous")] Continuous,
    [JsonStringEnumMemberName("single")] Single,
    [JsonStringEnumMemberName("manual")] Manual,
}

[JsonConverter(typeof(JsonStringEnumConverter<Stabilization>))]
public enum Stabilization
{
    [JsonStringEnumMemberName("off")] Off,
    [JsonStringEnumMemberName("standard")] Standard,
    [JsonStringEnumMemberName("cinematic")] Cinematic,
    [JsonStringEnumMemberName("cinematicExtended")] CinematicExtended,
    [JsonStringEnumMemberName("auto")] Auto,
}

[JsonConverter(typeof(JsonStringEnumConverter<TorchMode>))]
public enum TorchMode { [JsonStringEnumMemberName("off")] Off, [JsonStringEnumMemberName("on")] On, [JsonStringEnumMemberName("auto")] Auto }

[JsonConverter(typeof(JsonStringEnumConverter<OrientationLock>))]
public enum OrientationLock
{
    [JsonStringEnumMemberName("auto")] Auto,
    [JsonStringEnumMemberName("portrait")] Portrait,
    [JsonStringEnumMemberName("landscapeLeft")] LandscapeLeft,
    [JsonStringEnumMemberName("landscapeRight")] LandscapeRight,
}

[JsonConverter(typeof(JsonStringEnumConverter<CaptureTarget>))]
public enum CaptureTarget
{
    [JsonStringEnumMemberName("phone")] Phone,
    [JsonStringEnumMemberName("pc")] Pc,
    [JsonStringEnumMemberName("both")] Both,
}

[JsonConverter(typeof(JsonStringEnumConverter<WhiteBalancePreset>))]
public enum WhiteBalancePreset
{
    [JsonStringEnumMemberName("auto")] Auto,
    [JsonStringEnumMemberName("daylight")] Daylight,
    [JsonStringEnumMemberName("cloudy")] Cloudy,
    [JsonStringEnumMemberName("shade")] Shade,
    [JsonStringEnumMemberName("tungsten")] Tungsten,
    [JsonStringEnumMemberName("fluorescent")] Fluorescent,
    [JsonStringEnumMemberName("warm")] Warm,
    [JsonStringEnumMemberName("custom")] Custom,
}

/// <summary>
/// The camera state, as this computer last received it.
///
/// Windows renders this and sends mutations. It never treats its own copy as
/// authoritative — the phone owns the state, because only the phone can see
/// what the hardware actually accepted.
/// </summary>
public sealed record CameraState
{
    [JsonPropertyName("v")] public ulong Version { get; init; }

    [JsonPropertyName("lensId")] public string LensId { get; init; } = "";
    [JsonPropertyName("zoom")] public double Zoom { get; init; } = 1.0;
    [JsonPropertyName("lensLocked")] public bool LensLocked { get; init; }

    [JsonPropertyName("width")] public int Width { get; init; } = 1920;
    [JsonPropertyName("height")] public int Height { get; init; } = 1080;
    [JsonPropertyName("fps")] public int Fps { get; init; } = 30;
    [JsonPropertyName("codec")] public VideoCodec Codec { get; init; } = VideoCodec.Hevc;
    [JsonPropertyName("hdr")] public HdrMode Hdr { get; init; } = HdrMode.Auto;
    [JsonPropertyName("stabilization")] public Stabilization Stabilization { get; init; } = Stabilization.Auto;

    [JsonPropertyName("exposureMode")] public ExposureMode ExposureMode { get; init; } = ExposureMode.Auto;
    [JsonPropertyName("iso")] public double Iso { get; init; } = 100;
    [JsonPropertyName("exposureDurationUs")] public int ExposureDurationUs { get; init; } = 8333;
    [JsonPropertyName("ev")] public double Ev { get; init; }
    [JsonPropertyName("exposureLocked")] public bool ExposureLocked { get; init; }

    [JsonPropertyName("whiteBalanceMode")] public WhiteBalanceMode WhiteBalanceMode { get; init; } = WhiteBalanceMode.Auto;
    [JsonPropertyName("whiteBalancePreset")] public WhiteBalancePreset WhiteBalancePreset { get; init; } = WhiteBalancePreset.Auto;
    [JsonPropertyName("temperature")] public double Temperature { get; init; } = 5000;
    [JsonPropertyName("tint")] public double Tint { get; init; }

    [JsonPropertyName("focusMode")] public FocusMode FocusMode { get; init; } = FocusMode.Continuous;
    [JsonPropertyName("focusPosition")] public double FocusPosition { get; init; } = 0.5;
    [JsonPropertyName("focusLocked")] public bool FocusLocked { get; init; }
    [JsonPropertyName("faceDrivenFocus")] public bool FaceDrivenFocus { get; init; } = true;

    [JsonPropertyName("torch")] public TorchMode Torch { get; init; } = TorchMode.Off;
    [JsonPropertyName("torchLevel")] public double TorchLevel { get; init; } = 1.0;
    [JsonPropertyName("mirrored")] public bool Mirrored { get; init; }
    [JsonPropertyName("orientation")] public OrientationLock Orientation { get; init; } = OrientationLock.Auto;

    // Applied to the derived outputs on the PC, never to the master recording.
    // Each runs -1 to +1 and means "leave it alone" at 0, except lowLight and
    // beauty, which only have one direction to go and run 0 to 1.
    [JsonPropertyName("brightness")] public double Brightness { get; init; }
    [JsonPropertyName("contrast")] public double Contrast { get; init; }
    [JsonPropertyName("saturation")] public double Saturation { get; init; }
    [JsonPropertyName("warmth")] public double Warmth { get; init; }
    [JsonPropertyName("sharpness")] public double Sharpness { get; init; }
    [JsonPropertyName("lowLight")] public double LowLight { get; init; }
    [JsonPropertyName("beauty")] public double Beauty { get; init; }

    /// <summary>8333 µs reads as 1/120.</summary>
    [JsonIgnore]
    public int ShutterDenominator =>
        ExposureDurationUs > 0 ? (int)Math.Round(1_000_000.0 / ExposureDurationUs) : 0;
}

/// <summary>
/// A partial change. Only the properties the sender actually touched are
/// serialised, which is what makes concurrent edits from the phone and the PC
/// safe: a stale ISO slider cannot revert an unrelated setting.
/// </summary>
public sealed class CameraMutation
{
    [JsonPropertyName("lensId")] public string? LensId { get; set; }
    [JsonPropertyName("zoom")] public double? Zoom { get; set; }
    [JsonPropertyName("lensLocked")] public bool? LensLocked { get; set; }

    [JsonPropertyName("width")] public int? Width { get; set; }
    [JsonPropertyName("height")] public int? Height { get; set; }
    [JsonPropertyName("fps")] public int? Fps { get; set; }
    [JsonPropertyName("codec")] public VideoCodec? Codec { get; set; }
    [JsonPropertyName("hdr")] public HdrMode? Hdr { get; set; }
    [JsonPropertyName("stabilization")] public Stabilization? Stabilization { get; set; }

    [JsonPropertyName("exposureMode")] public ExposureMode? ExposureMode { get; set; }
    [JsonPropertyName("iso")] public double? Iso { get; set; }
    [JsonPropertyName("exposureDurationUs")] public int? ExposureDurationUs { get; set; }
    [JsonPropertyName("ev")] public double? Ev { get; set; }
    [JsonPropertyName("exposureLocked")] public bool? ExposureLocked { get; set; }

    [JsonPropertyName("whiteBalanceMode")] public WhiteBalanceMode? WhiteBalanceMode { get; set; }
    [JsonPropertyName("whiteBalancePreset")] public WhiteBalancePreset? WhiteBalancePreset { get; set; }
    [JsonPropertyName("temperature")] public double? Temperature { get; set; }
    [JsonPropertyName("tint")] public double? Tint { get; set; }

    [JsonPropertyName("focusMode")] public FocusMode? FocusMode { get; set; }
    [JsonPropertyName("focusPosition")] public double? FocusPosition { get; set; }
    [JsonPropertyName("focusLocked")] public bool? FocusLocked { get; set; }
    [JsonPropertyName("faceDrivenFocus")] public bool? FaceDrivenFocus { get; set; }

    [JsonPropertyName("torch")] public TorchMode? Torch { get; set; }
    [JsonPropertyName("torchLevel")] public double? TorchLevel { get; set; }
    [JsonPropertyName("mirrored")] public bool? Mirrored { get; set; }
    [JsonPropertyName("orientation")] public OrientationLock? Orientation { get; set; }

    [JsonPropertyName("brightness")] public double? Brightness { get; set; }
    [JsonPropertyName("contrast")] public double? Contrast { get; set; }
    [JsonPropertyName("saturation")] public double? Saturation { get; set; }
    [JsonPropertyName("warmth")] public double? Warmth { get; set; }
    [JsonPropertyName("sharpness")] public double? Sharpness { get; set; }
    [JsonPropertyName("lowLight")] public double? LowLight { get; set; }
    [JsonPropertyName("beauty")] public double? Beauty { get; set; }
}

/// <summary>What this computer receives. Unrelated to what the phone records.</summary>
public sealed record StreamProfile
{
    [JsonPropertyName("width")] public int Width { get; init; } = 1280;
    [JsonPropertyName("height")] public int Height { get; init; } = 720;
    [JsonPropertyName("fps")] public int Fps { get; init; } = 30;
    [JsonPropertyName("codec")] public VideoCodec Codec { get; init; } = VideoCodec.H264;
    [JsonPropertyName("bitrate")] public int Bitrate { get; init; } = 6_000_000;
    [JsonPropertyName("keyframeIntervalSeconds")] public double KeyframeIntervalSeconds { get; init; } = 2;

    public static StreamProfile Webcam720p30 => new()
    { Width = 1280, Height = 720, Fps = 30, Codec = VideoCodec.H264, Bitrate = 4_000_000 };

    public static StreamProfile Webcam1080p30 => new()
    { Width = 1920, Height = 1080, Fps = 30, Codec = VideoCodec.H264, Bitrate = 8_000_000 };

    public static StreamProfile Webcam1080p60 => new()
    { Width = 1920, Height = 1080, Fps = 60, Codec = VideoCodec.H264, Bitrate = 12_000_000 };

    /// <summary>
    /// H.264 rather than HEVC, deliberately: HEVC decode on Windows depends on
    /// a store extension half the machines do not have, and a webcam that
    /// only works on some computers is not a webcam.
    /// </summary>
    public static StreamProfile Webcam2160p30 => new()
    { Width = 3840, Height = 2160, Fps = 30, Codec = VideoCodec.H264, Bitrate = 20_000_000 };
}
