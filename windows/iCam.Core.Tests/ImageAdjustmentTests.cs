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

    // MARK: - Low light

    [Fact]
    public void LowLightLiftsTheShadows()
    {
        var frame = Frame(60, 128, 128); // a face in a dim room
        With(new ImageAdjustments { LowLight = 1 }).Apply(frame, Width, Height);
        Assert.True(Luma(frame, 0, 0) > 80,
            $"a shadow at 60 should be rescued, got {Luma(frame, 0, 0)}");
    }

    [Fact]
    public void LowLightLeavesBlackWhiteAndTheHighlightsAlone()
    {
        var black = Frame(16, 128, 128);
        var white = Frame(235, 128, 128);
        var highlight = Frame(220, 128, 128);

        var adjuster = With(new ImageAdjustments { LowLight = 1 });
        adjuster.Apply(black, Width, Height);
        adjuster.Apply(white, Width, Height);
        adjuster.Apply(highlight, Width, Height);

        // Black staying black is what keeps sensor noise dark instead of
        // grey, and the highlights barely moving is what makes this a rescue
        // rather than a second brightness slider.
        Assert.Equal(16, Luma(black, 0, 0));
        Assert.Equal(235, Luma(white, 0, 0));
        Assert.True(Math.Abs(Luma(highlight, 0, 0) - 220) <= 4,
            $"a highlight at 220 should barely move, got {Luma(highlight, 0, 0)}");
    }

    [Fact]
    public void LowLightIsNegativeProofAndNeverExceedsOne()
    {
        var negative = ImageAdjustments.From(new CameraState { LowLight = -3, Beauty = 7 });
        Assert.Equal(0, negative.LowLight);
        Assert.Equal(1, negative.Beauty);
    }

    // MARK: - Beauty

    // Beauty measures a pixel against a quarter-scale blur, so its tests need
    // room for that scale to exist.
    private const int SkinWidth = 64;
    private const int SkinHeight = 32;

    [Fact]
    public void BeautyFlattensPoreScaleTexture()
    {
        var frame = Frame(120, 128, 128, SkinWidth, SkinHeight);
        // Skin: a mid-tone with small-amplitude speckle.
        var noise = new Random(7);
        for (var y = 0; y < SkinHeight; y++)
        {
            for (var x = 0; x < SkinWidth; x++)
            {
                frame[y * SkinWidth + x] = (byte)(120 + noise.Next(-8, 9));
            }
        }

        var before = Deviation(frame);
        With(new ImageAdjustments { Beauty = 1 }).Apply(frame, SkinWidth, SkinHeight);
        var after = Deviation(frame);

        Assert.True(after < before * 0.5,
            $"speckle should at least halve, went from {before:0.0} to {after:0.0}");
    }

    [Fact]
    public void BeautyLeavesARealEdgeStanding()
    {
        var frame = Frame(0, 128, 128, SkinWidth, SkinHeight);
        for (var y = 0; y < SkinHeight; y++)
        {
            for (var x = 0; x < SkinWidth; x++)
            {
                frame[y * SkinWidth + x] = (byte)(x < SkinWidth / 2 ? 60 : 180);
            }
        }

        With(new ImageAdjustments { Beauty = 1 }).Apply(frame, SkinWidth, SkinHeight);

        // The step is 120 luma steps — far past the knee. The pixels near it
        // sit on the blur's flank, so a small pull toward the base is the
        // nature of the algorithm; what must not happen is the visible halo a
        // plain blur leaves. Three steps against a 120-step cliff is under
        // the noise floor of any real sensor.
        var left = Luma(frame, SkinWidth / 2 - 4, SkinHeight / 2, SkinWidth);
        var right = Luma(frame, SkinWidth / 2 + 3, SkinHeight / 2, SkinWidth);
        Assert.True(Math.Abs(left - 60) <= 3, $"left flank moved to {left}");
        Assert.True(Math.Abs(right - 180) <= 3, $"right flank moved to {right}");
    }

    [Fact]
    public void BeautyOnAFlatFieldIsTheIdentity()
    {
        var frame = Frame(120, 128, 128, SkinWidth, SkinHeight);
        var reference = (byte[])frame.Clone();
        With(new ImageAdjustments { Beauty = 1 }).Apply(frame, SkinWidth, SkinHeight);
        Assert.Equal(reference, frame);
    }

    [Fact]
    public void BeautySurvivesSizesThatDoNotDivideByFour()
    {
        // 22x14 quarter-scales to 6x4 with ragged edge blocks; the pass must
        // still touch every pixel and nothing beyond the picture.
        const int width = 22;
        const int height = 14;
        var frame = Frame(120, 128, 128, width, height, stride: 26);
        With(new ImageAdjustments { Beauty = 1 }).Apply(frame, width, height, stride: 26);

        // The padding between picture and stride is not the pass's to touch.
        Assert.Equal(Sentinel, frame[width]);
    }

    [Fact]
    public void BeautyOnFlatColourIsTheIdentity()
    {
        var frame = Frame(120, 90, 170, SkinWidth, SkinHeight);
        With(new ImageAdjustments { Beauty = 1 }).Apply(frame, SkinWidth, SkinHeight);
        Assert.Equal(90, frame[SkinWidth * SkinHeight]);
        Assert.Equal(170, frame[SkinWidth * SkinHeight + 1]);
    }

    [Fact]
    public void BeautyEvensOutABlotchOfColour()
    {
        // Skin-coloured chroma with one redder blotch: a blemish, as the
        // chroma plane sees it. Cr sits at 140, the blotch pushes it to 150.
        var frame = Frame(120, 110, 140, SkinWidth, SkinHeight);
        var chroma = SkinWidth * SkinHeight;
        var blotchAt = chroma + 6 * SkinWidth + 21; // a Cr sample mid-plane
        frame[blotchAt] = 150;

        With(new ImageAdjustments { Beauty = 1 }).Apply(frame, SkinWidth, SkinHeight);

        Assert.True(frame[blotchAt] < 148,
            $"a 10-step colour blotch should fade, still at {frame[blotchAt]}");
    }

    [Fact]
    public void BeautyLeavesLipsTheirColour()
    {
        // A hard colour boundary: skin chroma on the left, lip-red on the
        // right — a 40-step Cr edge, far past the chroma knee.
        var frame = Frame(120, 110, 130, SkinWidth, SkinHeight);
        var chroma = SkinWidth * SkinHeight;
        for (var y = 0; y < SkinHeight / 2; y++)
        {
            for (var x = SkinWidth / 2 + 1; x < SkinWidth; x += 2)
            {
                frame[chroma + y * SkinWidth + x] = 170;
            }
        }

        With(new ImageAdjustments { Beauty = 1 }).Apply(frame, SkinWidth, SkinHeight);

        var nearEdgeSkin = frame[chroma + 6 * SkinWidth + (SkinWidth / 2 - 5)];
        var nearEdgeLip = frame[chroma + 6 * SkinWidth + (SkinWidth / 2 + 5)];
        Assert.True(Math.Abs(nearEdgeSkin - 130) <= 3, $"skin side moved to {nearEdgeSkin}");
        Assert.True(Math.Abs(nearEdgeLip - 170) <= 3, $"lip side moved to {nearEdgeLip}");
    }

    private static double Deviation(byte[] frame)
    {
        double mean = 0;
        for (var i = 0; i < SkinWidth * SkinHeight; i++) mean += frame[i];
        mean /= SkinWidth * SkinHeight;

        double sum = 0;
        for (var i = 0; i < SkinWidth * SkinHeight; i++)
        {
            sum += (frame[i] - mean) * (frame[i] - mean);
        }
        return Math.Sqrt(sum / (SkinWidth * SkinHeight));
    }
}
