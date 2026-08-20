using ICam.Core.Media;
using Xunit;

namespace ICam.Core.Tests;

public class Nv12EncoderTests
{
    private static byte[] SolidBgra(int width, int height, byte b, byte g, byte r)
    {
        var pixels = new byte[width * height * 4];
        for (var i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = b;
            pixels[i + 1] = g;
            pixels[i + 2] = r;
            pixels[i + 3] = 255;
        }
        return pixels;
    }

    private static byte[] Encode(byte[] bgra, int width, int height)
    {
        var stride = Nv12Encoder.DefaultStride(width);
        var output = new byte[Nv12Encoder.RequiredBytes(stride, height)];
        Nv12Encoder.Convert(bgra, width * 4, output, stride, width, height);
        return output;
    }

    [Fact]
    public void GeometryMatchesTheNv12Layout()
    {
        // A full luma plane plus a half-height interleaved chroma plane.
        Assert.Equal(1280 * 720 * 3 / 2, Nv12Encoder.RequiredBytes(1280, 720));
        Assert.Equal(1280, Nv12Encoder.DefaultStride(1280));
        Assert.Equal(642, Nv12Encoder.DefaultStride(641));
    }

    [Fact]
    public void BlackAndWhiteLandOnTheStudioSwingLimits()
    {
        var black = Encode(SolidBgra(4, 4, 0, 0, 0), 4, 4);
        var white = Encode(SolidBgra(4, 4, 255, 255, 255), 4, 4);

        // 16 and 235, not 0 and 255. Handing a consumer full-range values in a
        // limited-range format is what crushes blacks and clips highlights.
        Assert.Equal(16, black[0]);
        Assert.InRange(white[0], 233, 235);
    }

    [Fact]
    public void GreyIsColourless()
    {
        var grey = Encode(SolidBgra(4, 4, 128, 128, 128), 4, 4);
        var chroma = 4 * 4;   // stride * height

        // Neutral grey must sit at 128 in both chroma channels, or every
        // greyscale scene picks up a tint.
        Assert.InRange(grey[chroma], 127, 129);
        Assert.InRange(grey[chroma + 1], 127, 129);
    }

    [Fact]
    public void PrimariesPushChromaInTheRightDirection()
    {
        var chroma = 4 * 4;

        var red = Encode(SolidBgra(4, 4, 0, 0, 255), 4, 4);
        var blue = Encode(SolidBgra(4, 4, 255, 0, 0), 4, 4);

        // Cr carries red, Cb carries blue. Getting these the wrong way round
        // swaps the two channels and nothing downstream would report it.
        Assert.True(red[chroma + 1] > 200, $"red should raise Cr, got {red[chroma + 1]}");
        Assert.True(red[chroma] < 128, $"red should lower Cb, got {red[chroma]}");
        Assert.True(blue[chroma] > 200, $"blue should raise Cb, got {blue[chroma]}");
        Assert.True(blue[chroma + 1] < 128, $"blue should lower Cr, got {blue[chroma + 1]}");
    }

    [Fact]
    public void GreenIsTheBrightestPrimary()
    {
        // BT.709 weights green at 0.7152. If luma ever came out with green
        // dimmer than red or blue, the coefficients have been transposed.
        var red = Encode(SolidBgra(2, 2, 0, 0, 255), 2, 2)[0];
        var green = Encode(SolidBgra(2, 2, 0, 255, 0), 2, 2)[0];
        var blue = Encode(SolidBgra(2, 2, 255, 0, 0), 2, 2)[0];

        Assert.True(green > red, $"green {green} should exceed red {red}");
        Assert.True(red > blue, $"red {red} should exceed blue {blue}");
    }

    [Fact]
    public void EveryLumaSampleIsWrittenAcrossThePlane()
    {
        const int width = 64;
        const int height = 32;
        var output = Encode(SolidBgra(width, height, 200, 100, 50), width, height);

        // A stride or row-offset mistake shows up as untouched zero bytes
        // partway down the image, which reads as a black band.
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                Assert.True(output[y * width + x] >= 16,
                            $"luma at {x},{y} was never written");
            }
        }
    }

    [Fact]
    public void ChromaIsAveragedOverEachBlockRatherThanPointSampled()
    {
        // A 2x2 block of one red pixel and three black ones. Point sampling
        // the top-left would give full red; averaging gives a quarter of it.
        const int width = 2;
        const int height = 2;
        var pixels = new byte[width * height * 4];
        pixels[2] = 255;   // red, top-left only
        pixels[3] = 255;

        var stride = Nv12Encoder.DefaultStride(width);
        var output = new byte[Nv12Encoder.RequiredBytes(stride, height)];
        Nv12Encoder.Convert(pixels, width * 4, output, stride, width, height);

        var pureRed = Encode(SolidBgra(2, 2, 0, 0, 255), 2, 2);
        var chroma = stride * height;

        Assert.True(output[chroma + 1] < pureRed[chroma + 1],
                    "one red pixel in four must not produce a fully red block");
        Assert.True(output[chroma + 1] > 128,
                    "it must still lean red rather than being discarded");
    }

    [Fact]
    public void RespectsASourceStrideWithPadding()
    {
        const int width = 4;
        const int height = 2;
        var padded = 4 * 4 + 16;   // sixteen bytes of row padding

        var pixels = new byte[padded * height];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var offset = y * padded + x * 4;
                pixels[offset] = 255;      // blue
                pixels[offset + 3] = 255;
            }
            // Padding left as zero: reading it as pixels would darken the row.
        }

        var stride = Nv12Encoder.DefaultStride(width);
        var output = new byte[Nv12Encoder.RequiredBytes(stride, height)];
        Nv12Encoder.Convert(pixels, padded, output, stride, width, height);

        var expected = Encode(SolidBgra(width, height, 255, 0, 0), width, height);
        Assert.Equal(expected[0], output[0]);
        Assert.Equal(expected[stride * height], output[stride * height]);
    }

    [Fact]
    public void RefusesABufferItWouldOverrun()
    {
        var pixels = SolidBgra(8, 8, 0, 0, 0);
        var tooSmall = new byte[10];

        Assert.Throws<ArgumentException>(
            () => Nv12Encoder.Convert(pixels, 32, tooSmall, 8, 8, 8));
        Assert.Throws<ArgumentException>(
            () => Nv12Encoder.Convert(new byte[4], 32, new byte[8 * 8 * 3 / 2], 8, 8, 8));
    }
}
