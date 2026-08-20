namespace ICam.Core.Media;

/// <summary>
/// Converts a decoded BGRA frame into the NV12 that `iCam Camera` sends on to
/// Windows.
///
/// NV12 is not an arbitrary choice: it is what Media Foundation and every
/// consumer of a webcam already expect, so nothing downstream has to convert
/// again. A full-resolution luma plane, then one interleaved Cb/Cr plane at
/// half height.
/// </summary>
public static class Nv12Encoder
{
    /// <summary>Bytes an NV12 frame of this geometry occupies.</summary>
    public static int RequiredBytes(int stride, int height) => stride * height * 3 / 2;

    /// <summary>NV12 rows are padded to an even width.</summary>
    public static int DefaultStride(int width) => (width + 1) & ~1;

    /// <summary>
    /// Converts <paramref name="bgra"/> into <paramref name="destination"/>.
    /// </summary>
    /// <param name="bgra">Top-down BGRA8, four bytes per pixel.</param>
    /// <param name="sourceStride">Row pitch of the source, in bytes.</param>
    /// <param name="destination">Receives the NV12 frame.</param>
    /// <param name="stride">Row pitch of the luma plane; chroma reuses it.</param>
    /// <param name="width">Frame width in pixels.</param>
    /// <param name="height">Frame height in pixels.</param>
    public static void Convert(ReadOnlySpan<byte> bgra, int sourceStride,
                               Span<byte> destination, int stride,
                               int width, int height)
    {
        if (width <= 0 || height <= 0) return;
        if (destination.Length < RequiredBytes(stride, height))
        {
            throw new ArgumentException("destination is too small for this frame",
                                        nameof(destination));
        }
        if (bgra.Length < sourceStride * height)
        {
            throw new ArgumentException("source is shorter than its own geometry",
                                        nameof(bgra));
        }

        for (var y = 0; y < height; y++)
        {
            var source = bgra.Slice(y * sourceStride, width * 4);
            var luma = destination.Slice(y * stride, width);
            for (var x = 0; x < width; x++)
            {
                var offset = x * 4;
                luma[x] = Luma(source[offset + 2], source[offset + 1], source[offset]);
            }
        }

        var chromaPlane = destination[(stride * height)..];
        for (var y = 0; y + 1 < height; y += 2)
        {
            var top = bgra.Slice(y * sourceStride, width * 4);
            var bottom = bgra.Slice((y + 1) * sourceStride, width * 4);
            var row = chromaPlane.Slice(y / 2 * stride, width);

            for (var x = 0; x + 1 < width; x += 2)
            {
                // Averaged over the 2x2 block rather than point sampled.
                // Point sampling throws away three quarters of the colour
                // information and puts visible fringes on hard edges.
                var blue = 0;
                var green = 0;
                var red = 0;
                for (var dx = 0; dx < 2; dx++)
                {
                    var offset = (x + dx) * 4;
                    blue += top[offset] + bottom[offset];
                    green += top[offset + 1] + bottom[offset + 1];
                    red += top[offset + 2] + bottom[offset + 2];
                }

                var (cb, cr) = Chroma((byte)(red / 4), (byte)(green / 4), (byte)(blue / 4));
                row[x] = cb;
                row[x + 1] = cr;
            }
        }
    }

    // BT.709 studio swing. HD video in an NV12 format is expected to be BT.709
    // limited range; handing a consumer full-range values in a limited-range
    // format shows up as crushed blacks and clipped highlights. These match the
    // coefficients the virtual camera DLL uses for its own card, so there is no
    // colour shift between the holding frame and live video.
    private static byte Luma(byte r, byte g, byte b) =>
        Clamp(16.0 + 0.1826 * r + 0.6142 * g + 0.0620 * b, 16, 235);

    private static (byte Cb, byte Cr) Chroma(byte r, byte g, byte b) =>
        (Clamp(128.0 - 0.1006 * r - 0.3386 * g + 0.4392 * b, 16, 240),
         Clamp(128.0 + 0.4392 * r - 0.3989 * g - 0.0403 * b, 16, 240));

    private static byte Clamp(double value, double low, double high) =>
        (byte)(value < low ? low : value > high ? high : value);
}
