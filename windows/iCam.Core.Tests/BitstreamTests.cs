using ICam.Core.Media;
using ICam.Core.Protocol;
using Xunit;

namespace ICam.Core.Tests;

public class BitstreamTests
{
    private static byte[] Avcc(params byte[][] nalUnits)
    {
        var output = new List<byte>();
        foreach (var nal in nalUnits)
        {
            output.Add((byte)(nal.Length >> 24));
            output.Add((byte)(nal.Length >> 16));
            output.Add((byte)(nal.Length >> 8));
            output.Add((byte)nal.Length);
            output.AddRange(nal);
        }
        return output.ToArray();
    }

    [Fact]
    public void ConvertsOneNalUnit()
    {
        var payload = new byte[] { 0x65, 0xAA, 0xBB };
        var result = BitstreamConverter.AvccToAnnexB(Avcc(payload));

        Assert.Equal<byte>([0x00, 0x00, 0x00, 0x01, 0x65, 0xAA, 0xBB], result);
    }

    [Fact]
    public void ConvertsSeveralNalUnitsInOrder()
    {
        var result = BitstreamConverter.AvccToAnnexB(
            Avcc([0x67, 0x01], [0x68, 0x02], [0x65, 0x03, 0x04]));

        Assert.Equal<byte>(
        [
            0x00, 0x00, 0x00, 0x01, 0x67, 0x01,
            0x00, 0x00, 0x00, 0x01, 0x68, 0x02,
            0x00, 0x00, 0x00, 0x01, 0x65, 0x03, 0x04,
        ], result);
    }

    [Fact]
    public void HandlesATwoByteLengthPrefix()
    {
        // The format permits 1, 2 or 4. A decoder that assumes 4 produces
        // garbage on the others, so the size comes from the config record.
        byte[] avcc = [0x00, 0x03, 0x65, 0xAA, 0xBB];
        var result = BitstreamConverter.AvccToAnnexB(avcc, nalLengthSize: 2);
        Assert.Equal<byte>([0x00, 0x00, 0x00, 0x01, 0x65, 0xAA, 0xBB], result);
    }

    [Fact]
    public void RejectsAnUnsupportedLengthPrefix()
    {
        Assert.Throws<ArgumentOutOfRangeException>(
            () => BitstreamConverter.AvccToAnnexB([1, 2, 3], nalLengthSize: 3));
    }

    [Fact]
    public void StopsCleanlyOnATruncatedAccessUnit()
    {
        // A frame cut short by a dropped connection must not read past its own
        // buffer, and must still yield the units that did arrive.
        var complete = Avcc([0x67, 0x01]);
        var truncated = complete.Concat<byte>([0x00, 0x00, 0x00, 0x40, 0x65]).ToArray();

        var result = BitstreamConverter.AvccToAnnexB(truncated);
        Assert.Equal<byte>([0x00, 0x00, 0x00, 0x01, 0x67, 0x01], result);
    }

    [Fact]
    public void EmptyInputYieldsEmptyOutput()
    {
        Assert.Empty(BitstreamConverter.AvccToAnnexB([]));
        Assert.Empty(BitstreamConverter.AvccToAnnexB([0x00, 0x00]));
    }

    [Fact]
    public void ParsesAnAvcCRecord()
    {
        byte[] sps = [0x67, 0x64, 0x00, 0x28];
        byte[] pps = [0x68, 0xEE, 0x3C, 0x80];

        List<byte> record =
        [
            0x01,                   // configurationVersion
            0x64, 0x00, 0x28,       // profile, compatibility, level
            0xFF,                   // lengthSizeMinusOne = 3, so four-byte lengths
            0xE1,                   // reserved bits + one SPS
            0x00, (byte)sps.Length,
        ];
        record.AddRange(sps);
        record.Add(0x01);           // one PPS
        record.AddRange([0x00, (byte)pps.Length]);
        record.AddRange(pps);

        var configuration = BitstreamConverter.ParseAvcC(record.ToArray());

        Assert.NotNull(configuration);
        Assert.Equal(4, configuration!.NalLengthSize);
        Assert.Equal<byte>(
        [
            0x00, 0x00, 0x00, 0x01, .. sps,
            0x00, 0x00, 0x00, 0x01, .. pps,
        ], configuration.AnnexBParameterSets);
    }

    [Fact]
    public void RejectsAnAvcCRecordOfTheWrongVersion()
    {
        byte[] record = [0x02, 0x64, 0x00, 0x28, 0xFF, 0xE1, 0x00];
        Assert.Null(BitstreamConverter.ParseAvcC(record));
    }

    [Fact]
    public void RejectsAnAvcCRecordThatLiesAboutItsLengths()
    {
        byte[] record = [0x01, 0x64, 0x00, 0x28, 0xFF, 0xE1, 0x00, 0x40, 0x67];
        Assert.Null(BitstreamConverter.ParseAvcC(record));
    }

    [Fact]
    public void ParsesAnHvcCRecord()
    {
        byte[] vps = [0x40, 0x01, 0x0C];
        byte[] sps = [0x42, 0x01, 0x01];
        byte[] pps = [0x44, 0x01, 0xC0];

        var record = new List<byte>(new byte[21]);
        record[0] = 0x01;                     // configurationVersion
        record.Add(0xF3);                     // lengthSizeMinusOne = 3
        record.Add(0x03);                     // three arrays

        void AddArray(byte nalType, byte[] payload)
        {
            record.Add(nalType);
            record.AddRange([0x00, 0x01]);    // one NAL unit in this array
            record.AddRange([0x00, (byte)payload.Length]);
            record.AddRange(payload);
        }

        AddArray(0x20, vps);
        AddArray(0x21, sps);
        AddArray(0x22, pps);

        var configuration = BitstreamConverter.ParseHvcC(record.ToArray());

        Assert.NotNull(configuration);
        Assert.Equal(4, configuration!.NalLengthSize);
        Assert.Equal<byte>(
        [
            0x00, 0x00, 0x00, 0x01, .. vps,
            0x00, 0x00, 0x00, 0x01, .. sps,
            0x00, 0x00, 0x00, 0x01, .. pps,
        ], configuration.AnnexBParameterSets);
    }

    [Fact]
    public void PicksTheParserFromTheCodecTheProtocolDeclared()
    {
        byte[] avcC = [0x01, 0x64, 0x00, 0x28, 0xFF, 0xE0, 0x00];
        Assert.NotNull(BitstreamConverter.ParseConfiguration(VideoCodec.H264, avcC));
        // The same bytes are not a valid hvcC, and must not be read as one.
        Assert.Null(BitstreamConverter.ParseConfiguration(VideoCodec.Hevc, avcC));
    }

    [Fact]
    public void ConversionDoesNotAlterThePayload()
    {
        // The whole point of doing this on the PC is that it is a memory copy:
        // no parsing of slice data, nothing that could change the picture.
        var payload = Enumerable.Range(0, 512).Select(i => (byte)(i * 31 % 251)).ToArray();
        var result = BitstreamConverter.AvccToAnnexB(Avcc(payload));

        Assert.Equal(payload.Length + 4, result.Length);
        Assert.Equal(payload, result[4..]);
    }
}
