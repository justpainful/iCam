using System.Buffers.Binary;

namespace ICam.Core.Media;

/// <summary>
/// Converts the AVCC access units the phone sends into the Annex-B byte stream
/// Media Foundation's decoders expect.
///
/// The phone sends AVCC because that is what VideoToolbox already produces —
/// asking it for Annex-B would mean a conversion pass on the phone, on battery,
/// on every frame. Doing it here instead puts the work on a machine that is
/// plugged into a wall, and it is only a memory copy: no parsing of the slice
/// data, no re-encoding, nothing that could alter the picture.
/// </summary>
public static class BitstreamConverter
{
    private static ReadOnlySpan<byte> StartCode => [0x00, 0x00, 0x00, 0x01];

    /// <summary>
    /// Rewrites length-prefixed NAL units as start-code-prefixed ones.
    /// </summary>
    /// <param name="avcc">One access unit, as the phone sent it.</param>
    /// <param name="nalLengthSize">
    /// From the codec configuration record; 4 in practice, but the format
    /// permits 1, 2 or 4 and a decoder that assumes 4 will produce garbage on
    /// the others.
    /// </param>
    public static byte[] AvccToAnnexB(ReadOnlySpan<byte> avcc, int nalLengthSize = 4)
    {
        if (nalLengthSize is not (1 or 2 or 4))
        {
            throw new ArgumentOutOfRangeException(nameof(nalLengthSize),
                "NAL length size must be 1, 2 or 4");
        }

        // One pass to size the output exactly, one to fill it. Two passes over
        // a few hundred kilobytes beats growing a list per frame at 60 fps.
        var count = 0;
        var offset = 0;
        while (offset + nalLengthSize <= avcc.Length)
        {
            var length = ReadLength(avcc[offset..], nalLengthSize);
            offset += nalLengthSize;
            if (length < 0 || offset + length > avcc.Length) break;
            offset += length;
            count++;
        }
        if (count == 0) return [];

        var output = new byte[avcc.Length + count * (4 - nalLengthSize)];
        var read = 0;
        var write = 0;
        while (read + nalLengthSize <= avcc.Length)
        {
            var length = ReadLength(avcc[read..], nalLengthSize);
            read += nalLengthSize;
            if (length < 0 || read + length > avcc.Length) break;

            StartCode.CopyTo(output.AsSpan(write));
            write += 4;
            avcc.Slice(read, length).CopyTo(output.AsSpan(write));
            write += length;
            read += length;
        }
        return write == output.Length ? output : output.AsSpan(0, write).ToArray();
    }

    private static int ReadLength(ReadOnlySpan<byte> span, int size) => size switch
    {
        1 => span[0],
        2 => BinaryPrimitives.ReadUInt16BigEndian(span),
        4 => (int)Math.Min(BinaryPrimitives.ReadUInt32BigEndian(span), int.MaxValue),
        _ => -1,
    };

    /// <summary>
    /// The parameter sets from an <c>avcC</c> or <c>hvcC</c> record, already in
    /// Annex-B form — which is exactly what Media Foundation wants as the
    /// sequence header.
    /// </summary>
    public sealed record CodecConfiguration(byte[] AnnexBParameterSets, int NalLengthSize)
    {
        public bool IsEmpty => AnnexBParameterSets.Length == 0;
    }

    /// <summary>Parses an <c>avcC</c> record (ISO/IEC 14496-15, section 5.2.4.1.1).</summary>
    public static CodecConfiguration? ParseAvcC(ReadOnlySpan<byte> avcC)
    {
        // configurationVersion(1) profile(1) compat(1) level(1) lengthSizeMinusOne(1) numSPS(1)
        if (avcC.Length < 7 || avcC[0] != 1) return null;

        var nalLengthSize = (avcC[4] & 0x03) + 1;
        var output = new List<byte>(avcC.Length + 32);
        var offset = 5;

        var spsCount = avcC[offset++] & 0x1F;
        if (!AppendSets(avcC, ref offset, spsCount, output)) return null;

        if (offset >= avcC.Length) return null;
        var ppsCount = avcC[offset++];
        if (!AppendSets(avcC, ref offset, ppsCount, output)) return null;

        return new CodecConfiguration(output.ToArray(), nalLengthSize);
    }

    /// <summary>Parses an <c>hvcC</c> record (ISO/IEC 14496-15, section 8.3.3.1.2).</summary>
    public static CodecConfiguration? ParseHvcC(ReadOnlySpan<byte> hvcC)
    {
        // The fixed part is 22 bytes, then numOfArrays.
        if (hvcC.Length < 23 || hvcC[0] != 1) return null;

        var nalLengthSize = (hvcC[21] & 0x03) + 1;
        var arrayCount = hvcC[22];
        var offset = 23;
        var output = new List<byte>(hvcC.Length + 64);

        for (var array = 0; array < arrayCount; array++)
        {
            // array_completeness(1) reserved(1) NAL_unit_type(6), then a count.
            if (offset + 3 > hvcC.Length) return null;
            offset += 1;
            var count = BinaryPrimitives.ReadUInt16BigEndian(hvcC[offset..]);
            offset += 2;
            if (!AppendSets(hvcC, ref offset, count, output)) return null;
        }

        return new CodecConfiguration(output.ToArray(), nalLengthSize);
    }

    private static bool AppendSets(ReadOnlySpan<byte> source, ref int offset, int count,
                                   List<byte> output)
    {
        for (var i = 0; i < count; i++)
        {
            if (offset + 2 > source.Length) return false;
            var length = BinaryPrimitives.ReadUInt16BigEndian(source[offset..]);
            offset += 2;
            if (offset + length > source.Length) return false;

            output.AddRange(StartCode);
            output.AddRange(source.Slice(offset, length));
            offset += length;
        }
        return true;
    }

    /// <summary>
    /// Picks the right parser for the codec the phone declared, so callers do
    /// not have to know which box name belongs to which codec.
    /// </summary>
    public static CodecConfiguration? ParseConfiguration(Protocol.VideoCodec codec,
                                                         ReadOnlySpan<byte> record) =>
        codec == Protocol.VideoCodec.Hevc ? ParseHvcC(record) : ParseAvcC(record);
}
