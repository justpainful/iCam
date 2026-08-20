namespace ICam.Core.Media;

/// <summary>
/// Turns an NV12 frame back into BGRA for display.
///
/// The preview draws the very same buffer that goes to <c>iCam Camera</c>,
/// after the image adjustments have been applied to it. That is the whole
/// point: the window shows what the people on the call see, including the
/// 4:2:0 chroma subsampling they receive, rather than a prettier picture that
/// only exists locally.
/// </summary>
public static class Nv12Decoder
{
    /// <summary>Bytes a BGRA frame of this geometry occupies.</summary>
    public static int RequiredBytes(int width, int height) => width * height * 4;

    /// <summary>
    /// Converts <paramref name="nv12"/> into top-down BGRA8.
    /// </summary>
    /// <param name="nv12">The frame, luma plane then interleaved chroma.</param>
    /// <param name="stride">Row pitch of the luma plane; chroma reuses it.</param>
    /// <param name="destination">Receives BGRA8, four bytes per pixel.</param>
    /// <param name="destinationStride">Row pitch of the destination, in bytes.</param>
    /// <param name="width">Frame width in pixels.</param>
    /// <param name="height">Frame height in pixels.</param>
    public static void Convert(ReadOnlySpan<byte> nv12, int stride,
                               Span<byte> destination, int destinationStride,
                               int width, int height)
    {
        if (width <= 0 || height <= 0) return;
        if (nv12.Length < Nv12Encoder.RequiredBytes(stride, height))
        {
            throw new ArgumentException("source is shorter than its own geometry",
                                        nameof(nv12));
        }
        if (destination.Length < destinationStride * height)
        {
            throw new ArgumentException("destination is too small for this frame",
                                        nameof(destination));
        }

        var chromaPlane = nv12[(stride * height)..];

        for (var y = 0; y < height; y++)
        {
            var luma = nv12.Slice(y * stride, width);
            // Two luma rows share one chroma row, which is what 4:2:0 means.
            var chroma = chromaPlane.Slice(y / 2 * stride, width);
            var row = destination.Slice(y * destinationStride, width * 4);

            for (var x = 0; x < width; x++)
            {
                // The chroma pair sits at the even column of each 2x2 block.
                var pair = x & ~1;
                var (b, g, r) = ToBgr(luma[x], chroma[pair], chroma[pair + 1]);

                var offset = x * 4;
                row[offset] = b;
                row[offset + 1] = g;
                row[offset + 2] = r;
                row[offset + 3] = 255;
            }
        }
    }

    // The exact inverse of Nv12Encoder's BT.709 studio swing. Using anything
    // else here would make the preview disagree with the picture actually being
    // sent, which is the one thing this path exists to prevent.
    private static (byte B, byte G, byte R) ToBgr(byte y, byte cb, byte cr)
    {
        var luma = 1.1644 * (y - 16);
        var blueDiff = cb - 128.0;
        var redDiff = cr - 128.0;

        return (Clamp(luma + 2.1124 * blueDiff),
                Clamp(luma - 0.2132 * blueDiff - 0.5329 * redDiff),
                Clamp(luma + 1.7927 * redDiff));
    }

    private static byte Clamp(double value) =>
        (byte)(value < 0 ? 0 : value > 255 ? 255 : value);
}
