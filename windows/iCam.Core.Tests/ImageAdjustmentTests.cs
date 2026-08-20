using ICam.Core.Media;
using ICam.Core.Protocol;
using Xunit;

namespace ICam.Core.Tests;

public class ImageAdjustmentTests
{
    private const int Width = 8;
    private const int Height = 4;

    /// <summary>Anything that is neither picture nor padding, so a stray write shows.</summary>
    private const byte Sentinel = 0xEE;

    private static byte[] Frame(byte luma, byte cb, byte cr,
                                int width = Width, int height = Height, int stride = 0)
    {
        if (stride <= 0) stride = width;
        var frame = new byte[stride * height * 3 / 2];
        Array.Fill(frame, Sentinel);

        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++) frame[y * stride + x] = luma;
        }

        var chroma = stride * height;
        for (var y = 0; y < height / 2; y++)
        {
            for (var x = 0; x + 1 < width; x += 2)
            {
                frame[chroma + y * stride + x] = cb;
                frame[chroma + y * stride + x + 1] = cr;
            }
        }
        return frame;
    }

    private static byte Luma(byte[] frame, int x, int y, int stride = Width) =>
        frame[y * stride + x];

    private static byte Cb(byte[] frame, int height = Height, int stride = Width) =>
        frame[stride * height];

    private static byte Cr(byte[] frame, int height = Height, int stride = Width) =>
        frame[stride * height + 1];

    private static ImageAdjuster With(ImageAdjustments adjustments,
                                      VideoRange range = VideoRange.Limited) =>
        new(range) { Adjustments = adjustments };

    // MARK: - Identity

    [Fact]
    public void UntouchedControlsLeaveEveryByteAlone()
    {
        var random = new Random(1848);
        var frame = new byte[Width * Height * 3 / 2];
        random.NextBytes(frame);
        var original = (byte[])frame.Clone();

        With(ImageAdjustments.None).Apply(frame, Width, Height);

        Assert.Equal(original, frame);
    }

    [Fact]
    public void ADefaultAdjustmentIsTheIdentity()
    {
        Assert.True(ImageAdjustments.None.IsIdentity);
        Assert.True(default(ImageAdjustments).IsIdentity);
        Assert.False(new ImageAdjustments { Warmth = 0.05 }.IsIdentity);
    }

    [Fact]
    public void AToneControlNeverTouchesColour()
    {
        var frame = Frame(126, 160, 90);
        With(new ImageAdjustments { Brightness = 1, Contrast = -1 })
            .Apply(frame, Width, Height);

        Assert.Equal(160, Cb(frame));
        Assert.Equal(90, Cr(frame));
    }

    [Fact]
    public void AColourControlNeverTouchesLuma()
    {
        var frame = Frame(126, 160, 90);
        With(new ImageAdjustments { Saturation = 1, Warmth = -1 })
            .Apply(frame, Width, Height);

        Assert.Equal(126, Luma(frame, 0, 0));
        Assert.Equal(126, Luma(frame, Width - 1, Height - 1));
    }

    // MARK: - Brightness

    [Fact]
    public void BrightnessLiftsTheMidTones()
    {
        var frame = Frame(126, 128, 128);
        With(new ImageAdjustments { Brightness = 1 }).Apply(frame, Width, Height);

        // Mid-grey sits a quarter of the way up the range at full lift.
        Assert.Equal(181, Luma(frame, 0, 0));
    }

    [Fact]
    public void NegativeBrightnessLowersTheMidTones()
    {
        var frame = Frame(126, 128, 128);
        With(new ImageAdjustments { Brightness = -1 }).Apply(frame, Width, Height);

        Assert.Equal(71, Luma(frame, 0, 0));
    }

    [Fact]
    public void BrightnessLeavesBlackAtBlackAndWhiteAtWhite()
    {
        // The reason this is a mid-tone lift and not an offset: an offset would
        // raise black to a milky grey and clip white, and the picture would
        // look worse in exactly the way the user was trying to fix.
        foreach (var brightness in new[] { 1.0, -1.0, 0.4 })
        {
            var black = Frame(16, 128, 128);
            var white = Frame(235, 128, 128);
            var adjuster = With(new ImageAdjustments { Brightness = brightness });

            adjuster.Apply(black, Width, Height);
            adjuster.Apply(white, Width, Height);

            Assert.Equal(16, Luma(black, 0, 0));
            Assert.Equal(235, Luma(white, 0, 0));
        }
    }

    // MARK: - Contrast

    [Fact]
    public void ContrastPushesAwayFromMidGrey()
    {
        var dark = Frame(90, 128, 128);
        var light = Frame(160, 128, 128);
        var adjuster = With(new ImageAdjustments { Contrast = 1 });

        adjuster.Apply(dark, Width, Height);
        adjuster.Apply(light, Width, Height);

        Assert.InRange(Luma(dark, 0, 0), 50, 60);
        Assert.InRange(Luma(light, 0, 0), 190, 200);
    }

    [Fact]
    public void ContrastAtItsFloorCollapsesOntoMidGrey()
    {
        var dark = Frame(40, 128, 128);
        var light = Frame(220, 128, 128);
        var adjuster = With(new ImageAdjustments { Contrast = -1 });

        adjuster.Apply(dark, Width, Height);
        adjuster.Apply(light, Width, Height);

        Assert.Equal(Luma(dark, 0, 0), Luma(light, 0, 0));
        Assert.InRange(Luma(dark, 0, 0), 124, 127);
    }

    // MARK: - Saturation and warmth

    [Fact]
    public void SaturationScalesColourAboutNeutral()
    {
        var frame = Frame(126, 160, 96);
        With(new ImageAdjustments { Saturation = 1 }).Apply(frame, Width, Height);

        Assert.Equal(192, Cb(frame));
        Assert.Equal(64, Cr(frame));
    }

    [Fact]
    public void SaturationAtItsFloorIsMonochrome()
    {
        var frame = Frame(126, 200, 40);
        With(new ImageAdjustments { Saturation = -1 }).Apply(frame, Width, Height);

        Assert.Equal(128, Cb(frame));
        Assert.Equal(128, Cr(frame));
    }

    [Fact]
    public void WarmthTakesBlueOutAndPutsRedIn()
    {
        var warm = Frame(126, 128, 128);
        var cool = Frame(126, 128, 128);

        With(new ImageAdjustments { Warmth = 1 }).Apply(warm, Width, Height);
        With(new ImageAdjustments { Warmth = -1 }).Apply(cool, Width, Height);

        Assert.Equal(108, Cb(warm));
        Assert.Equal(148, Cr(warm));
        Assert.Equal(148, Cb(cool));
        Assert.Equal(108, Cr(cool));
    }

    [Fact]
    public void SaturationHasTheLastWordOnColour()
    {
        // Warmth runs first because it decides where neutral sits, and
        // saturation runs after because it is the creative grade. Ordered the
        // other way, a monochrome picture would come out sepia.
        var frame = Frame(126, 200, 40);
        With(new ImageAdjustments { Warmth = 1, Saturation = -1 })
            .Apply(frame, Width, Height);

        Assert.Equal(128, Cb(frame));
        Assert.Equal(128, Cr(frame));
    }

    // MARK: - Clamping

    [Fact]
    public void ToneClampsRatherThanWrapping()
    {
        // A wrap is a hard visible artefact — a blown highlight that comes back
        // as black. A clamp is not.
        const int width = 256;
        var frame = new byte[width * 2 * 3 / 2];
        for (var x = 0; x < width; x++) frame[x] = frame[width + x] = (byte)x;

        With(new ImageAdjustments { Brightness = 1, Contrast = 1 }).Apply(frame, width, 2);

        Assert.Equal(0, frame[0]);
        Assert.Equal(255, frame[width - 1]);
        for (var x = 1; x < width; x++) Assert.True(frame[x] >= frame[x - 1]);
    }

    [Fact]
    public void ColourClampsRatherThanWrapping()
    {
        var floor = Frame(126, 0, 0);
        var ceiling = Frame(126, 255, 255);
        var adjuster = With(new ImageAdjustments { Saturation = 1, Warmth = 1 });

        adjuster.Apply(floor, Width, Height);
        adjuster.Apply(ceiling, Width, Height);

        Assert.Equal(0, Cb(floor));
        Assert.Equal(255, Cr(ceiling));
    }

    [Fact]
    public void SharpeningClampsRatherThanWrapping()
    {
        var frame = Frame(250, 128, 128);
        for (var y = 0; y < Height; y++)
        {
            for (var x = 0; x < Width / 2; x++) frame[y * Width + x] = 10;
        }

        With(new ImageAdjustments { Sharpness = 1 }).Apply(frame, Width, Height);

        Assert.Equal(255, Luma(frame, Width / 2, 0));
        Assert.Equal(0, Luma(frame, Width / 2 - 1, 0));
    }

    // MARK: - Sharpness

    [Fact]
    public void SharpeningExaggeratesAnEdge()
    {
        var frame = Frame(200, 128, 128);
        for (var y = 0; y < Height; y++)
        {
            for (var x = 0; x < Width / 2; x++) frame[y * Width + x] = 100;
        }

        With(new ImageAdjustments { Sharpness = 1 }).Apply(frame, Width, Height);

        Assert.Equal(75, Luma(frame, 3, 1));
        Assert.Equal(225, Luma(frame, 4, 1));
        // Away from the edge there is nothing to sharpen.
        Assert.Equal(100, Luma(frame, 0, 1));
        Assert.Equal(200, Luma(frame, Width - 1, 1));
    }

    [Fact]
    public void SofteningBlursTheSameEdge()
    {
        var frame = Frame(200, 128, 128);
        for (var y = 0; y < Height; y++)
        {
            for (var x = 0; x < Width / 2; x++) frame[y * Width + x] = 100;
        }

        With(new ImageAdjustments { Sharpness = -1 }).Apply(frame, Width, Height);

        Assert.Equal(125, Luma(frame, 3, 1));
        Assert.Equal(175, Luma(frame, 4, 1));
    }

    [Fact]
    public void SharpeningIsTheSameArithmeticEitherSideOfAVectorBoundary()
    {
        // Forty samples is wider than one vector on every machine that has
        // one, and not a multiple of any of them, so this single row runs
        // through the vector body, the scalar tail and both replicated edges.
        const int width = 40;
        const int edge = 20;
        var frame = Frame(200, 128, 128, width, Height);
        for (var y = 0; y < Height; y++)
        {
            for (var x = 0; x < edge; x++) frame[y * width + x] = 100;
        }

        With(new ImageAdjustments { Sharpness = 1 }).Apply(frame, width, Height);

        for (var y = 0; y < Height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var expected = x switch
                {
                    edge - 1 => 75,
                    edge => 225,
                    _ => x < edge ? 100 : 200,
                };
                Assert.Equal(expected, Luma(frame, x, y, width));
            }
        }
    }

    [Fact]
    public void SharpeningLeavesAFlatFieldExactlyAsItWas()
    {
        // Which is also the proof that the edge rows and columns replicate: a
        // border read as black would darken the outside of the picture.
        var frame = Frame(120, 128, 128);
        var original = (byte[])frame.Clone();

        With(new ImageAdjustments { Sharpness = 1 }).Apply(frame, Width, Height);

        Assert.Equal(original, frame);
    }

    // MARK: - Geometry

    [Fact]
    public void PaddingBetweenRowsIsNeverTouched()
    {
        const int stride = Width + 5;
        var frame = Frame(126, 160, 90, Width, Height, stride);

        With(new ImageAdjustments
        {
            Brightness = 1,
            Contrast = 1,
            Saturation = 1,
            Warmth = 1,
            Sharpness = 1,
        }).Apply(frame, Width, Height, stride);

        for (var y = 0; y < Height * 3 / 2; y++)
        {
            for (var x = Width; x < stride; x++)
            {
                Assert.Equal(Sentinel, frame[y * stride + x]);
            }
        }
    }

    [Fact]
    public void TheRangeDecidesWhereMidGreyIs()
    {
        var limited = Frame(128, 128, 128);
        var full = Frame(128, 128, 128);

        With(new ImageAdjustments { Contrast = 1 }, VideoRange.Limited)
            .Apply(limited, Width, Height);
        With(new ImageAdjustments { Contrast = 1 }, VideoRange.Full)
            .Apply(full, Width, Height);

        Assert.Equal(131, Luma(limited, 0, 0));
        Assert.Equal(129, Luma(full, 0, 0));
    }

    [Fact]
    public void RejectsABufferShorterThanItsGeometry()
    {
        var adjuster = With(new ImageAdjustments { Brightness = 1 });
        var frame = new byte[Width * Height];

        Assert.Throws<ArgumentException>(() => adjuster.Apply(frame, Width, Height));
    }

    [Fact]
    public void RejectsDimensionsNv12CannotDescribe()
    {
        var adjuster = With(new ImageAdjustments { Brightness = 1 });
        var frame = new byte[1024];

        Assert.Throws<ArgumentException>(() => adjuster.Apply(frame, 7, 4));
        Assert.Throws<ArgumentException>(() => adjuster.Apply(frame, 8, 5));
    }

    [Fact]
    public void RejectsARowPitchNarrowerThanThePicture()
    {
        var adjuster = With(new ImageAdjustments { Brightness = 1 });
        var frame = new byte[1024];

        Assert.Throws<ArgumentOutOfRangeException>(
            () => adjuster.Apply(frame, Width, Height, Width - 2));
    }

    // MARK: - Coming off the wire

    [Fact]
    public void ValuesArrivingFromThePhoneArePinnedToTheirRange()
    {
        var adjustments = ImageAdjustments.From(new CameraState
        {
            Brightness = 5,
            Contrast = -9,
            Saturation = double.NaN,
            Warmth = 0.25,
            Sharpness = double.PositiveInfinity,
        });

        Assert.Equal(1, adjustments.Brightness);
        Assert.Equal(-1, adjustments.Contrast);
        Assert.Equal(0, adjustments.Saturation);
        Assert.Equal(0.25, adjustments.Warmth);
        Assert.Equal(1, adjustments.Sharpness);
    }

    [Fact]
    public void AnOutOfRangeSettingCannotReachTheTables()
    {
        var wild = Frame(126, 128, 128);
        var pinned = Frame(126, 128, 128);

        With(new ImageAdjustments { Brightness = 40 }).Apply(wild, Width, Height);
        With(new ImageAdjustments { Brightness = 1 }).Apply(pinned, Width, Height);

        Assert.Equal(Luma(pinned, 0, 0), Luma(wild, 0, 0));
    }
}
