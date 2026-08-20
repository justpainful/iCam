using ICam.Core.Protocol;

namespace ICam.Core.Media;

/// <summary>
/// Which byte values the decoded luma actually uses.
///
/// The phone's encoder emits BT.709 video range, where black is 16 and white
/// is 235. Treating that as 0–255 is the usual way this goes wrong: a mid-tone
/// lift computed against a black point of zero raises real black to a milky
/// grey, and the result looks washed out in exactly the way people blame on
/// their webcam.
/// </summary>
public enum VideoRange
{
    /// <summary>Luma 16–235. What arrives from the phone.</summary>
    Limited,

    /// <summary>Luma 0–255.</summary>
    Full,
}

/// <summary>
/// The five image controls, as the user left them.
///
/// Each is zero when untouched and reaches −1 and +1 at the ends of its
/// slider, so a default value means "leave the picture alone" and the type has
/// no invalid state a caller has to remember to avoid.
///
/// These apply to the derived outputs only — the preview and <c>iCam
/// Camera</c>. The master recording on the phone never sees them; see
/// <c>docs/ARCHITECTURE.md</c>.
/// </summary>
public readonly record struct ImageAdjustments
{
    /// <summary>Lifts or lowers the mid-tones, leaving black and white where they are.</summary>
    public double Brightness { get; init; }

    /// <summary>Expands or collapses the picture around mid-grey.</summary>
    public double Contrast { get; init; }

    /// <summary>Scales colour about neutral. At −1 the picture is monochrome.</summary>
    public double Saturation { get; init; }

    /// <summary>Moves neutral along the amber–blue axis. Positive is warmer.</summary>
    public double Warmth { get; init; }

    /// <summary>Positive sharpens, negative softens. At −1 the detail layer is gone.</summary>
    public double Sharpness { get; init; }

    public static ImageAdjustments None => default;

    public bool IsIdentity => !TouchesTone && !TouchesColour && !TouchesDetail;

    /// <summary>
    /// Which of the three passes have anything to do. A user who moved one
    /// slider should pay for one pass, not for all of them.
    /// </summary>
    internal bool TouchesTone => Brightness != 0 || Contrast != 0;

    internal bool TouchesColour => Saturation != 0 || Warmth != 0;

    internal bool TouchesDetail => Sharpness != 0;

    /// <summary>
    /// Pins every value into −1…+1, and reads a NaN as untouched. The values
    /// arrive over the wire from another implementation, so this is the
    /// boundary where a malformed number stops being able to blank a picture.
    /// </summary>
    public ImageAdjustments Clamped() => new()
    {
        Brightness = Pin(Brightness),
        Contrast = Pin(Contrast),
        Saturation = Pin(Saturation),
        Warmth = Pin(Warmth),
        Sharpness = Pin(Sharpness),
    };

    /// <summary>The image half of the camera state the phone published.</summary>
    public static ImageAdjustments From(CameraState state) => new ImageAdjustments
    {
        Brightness = state.Brightness,
        Contrast = state.Contrast,
        Saturation = state.Saturation,
        Warmth = state.Warmth,
        Sharpness = state.Sharpness,
    }.Clamped();

    private static double Pin(double value) =>
        double.IsNaN(value) ? 0 : Math.Clamp(value, -1, 1);
}
