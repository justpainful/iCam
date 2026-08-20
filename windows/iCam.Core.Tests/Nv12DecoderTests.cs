using ICam.Core.Media;
using Xunit;

namespace ICam.Core.Tests;

public class Nv12DecoderTests
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

    private static byte[] RoundTrip(byte[] bgra, int width, int height)
    {
        var stride = Nv12Encoder.DefaultStride(width);
        var nv12 = new byte[Nv12Encoder.RequiredBytes(stride, height)];
        Nv12Encoder.Convert(bgra, width * 4, nv12, stride, width, height);

        var back = new byte[Nv12Decoder.RequiredBytes(width, height)];
        Nv12Decoder.Convert(nv12, stride, back, width * 4, width, height);
        return back;
    }

    [Theory]
    [InlineData(0, 0, 0)]
    [InlineData(255, 255, 255)]
    [InlineData(128, 128, 128)]
    [InlineData(0, 0, 255)]
    [InlineData(0, 255, 0)]
    [InlineData(255, 0, 0)]
    [InlineData(200, 100, 50)]
    public void ARoundTripLandsCloseToWhereItStarted(byte b, byte g, byte r)
    {
        var back = RoundTrip(SolidBgra(4, 4, b, g, r), 4, 4);

        // Not exact, and it should not be: the trip crosses BT.709 studio
        // swing, which discards the levels below 16 and above 235 on purpose.
        // What matters is that the two directions agree, because a mismatch
        // would make the preview a different picture from the one being sent.
        Assert.InRange(back[0], b - 4, b + 4);
        Assert.InRange(back[1], g - 4, g + 4);
        Assert.InRange(back[2], r - 4, r + 4);
        Assert.Equal(255, back[3]);
    }

    [Fact]
    public void GreyStaysGrey()
    {
        var back = RoundTrip(SolidBgra(4, 4, 128, 128, 128), 4, 4);

        // Any drift between the two colour matrices shows up first as a tint on
        // neutral grey, which is exactly where a viewer would notice it.
        Assert.InRange(back[0], back[1] - 2, back[1] + 2);
        Assert.InRange(back[1], back[2] - 2, back[2] + 2);
    }

    [Fact]
    public void EveryPixelIsWrittenIncludingTheAlpha()
    {
        const int width = 32;
        const int height = 16;
        var back = RoundTrip(SolidBgra(width, height, 90, 140, 210), width, height);

        // A row-offset mistake shows up as untouched zero bytes partway down,
        // which reads as a black band.
        for (var i = 3; i < back.Length; i += 4)
        {
            Assert.Equal(255, back[i]);
        }
        Assert.DoesNotContain(back.Where((_, i) => i % 4 != 3), value => value == 0);
    }

    [Fact]
    public void BothPixelsOfAChromaPairGetTheSameColour()
    {
        // Chroma is stored once per 2x2 block. Reading it at the odd column
        // would take the Cr byte as a Cb, tinting every other pixel.
        const int width = 4;
        const int height = 2;
        var bgra = SolidBgra(width, height, 0, 0, 255);
        var back = RoundTrip(bgra, width, height);

        for (var x = 1; x < width; x++)
        {
            Assert.Equal(back[0], back[x * 4]);
            Assert.Equal(back[2], back[x * 4 + 2]);
        }
    }

    [Fact]
    public void RespectsADestinationStrideWithPadding()
    {
        const int width = 4;
        const int height = 2;
        var padded = width * 4 + 12;

        var stride = Nv12Encoder.DefaultStride(width);
        var nv12 = new byte[Nv12Encoder.RequiredBytes(stride, height)];
        Nv12Encoder.Convert(SolidBgra(width, height, 255, 0, 0), width * 4,
                            nv12, stride, width, height);

        var destination = new byte[padded * height];
        Nv12Decoder.Convert(nv12, stride, destination, padded, width, height);

        // The padding must be left alone; writing into it would corrupt
        // whatever the surface keeps there.
        for (var y = 0; y < height; y++)
        {
            for (var i = width * 4; i < padded; i++)
            {
                Assert.Equal(0, destination[y * padded + i]);
            }
        }
        Assert.Equal(destination[0], destination[padded]);
    }

    [Fact]
    public void RefusesABufferItWouldOverrun()
    {
        var nv12 = new byte[Nv12Encoder.RequiredBytes(8, 8)];

        Assert.Throws<ArgumentException>(
            () => Nv12Decoder.Convert(nv12, 8, new byte[16], 32, 8, 8));
        Assert.Throws<ArgumentException>(
            () => Nv12Decoder.Convert(new byte[8], 8, new byte[8 * 8 * 4], 32, 8, 8));
    }
}
