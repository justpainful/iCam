using System.Buffers.Binary;
using System.Text.Json.Serialization;

namespace ICam.Core.Protocol;

/// <summary>Video channel header — <c>docs/PROTOCOL.md</c> section 6.</summary>
public readonly record struct VideoFrameHeader(
    VideoCodec Codec,
    bool IsKeyframe,
    bool IsParameterSets,
    bool IsEndOfStream,
    uint Sequence,
    ulong PtsUs,
    ulong DtsUs)
{
    public const int Size = 24;

    private const byte KeyframeFlag = 0x01;
    private const byte ParameterSetsFlag = 0x02;
    private const byte EndOfStreamFlag = 0x04;

    public byte[] Encode()
    {
        var buffer = new byte[Size];
        buffer[0] = Codec == VideoCodec.H264 ? (byte)1 : (byte)2;
        byte flags = 0;
        if (IsKeyframe) flags |= KeyframeFlag;
        if (IsParameterSets) flags |= ParameterSetsFlag;
        if (IsEndOfStream) flags |= EndOfStreamFlag;
        buffer[1] = flags;
        BinaryPrimitives.WriteUInt32BigEndian(buffer.AsSpan(4, 4), Sequence);
        BinaryPrimitives.WriteUInt64BigEndian(buffer.AsSpan(8, 8), PtsUs);
        BinaryPrimitives.WriteUInt64BigEndian(buffer.AsSpan(16, 8), DtsUs);
        return buffer;
    }

    public static bool TryDecode(ReadOnlySpan<byte> data, out VideoFrameHeader header,
                                 out ReadOnlySpan<byte> body)
    {
        header = default;
        body = default;
        if (data.Length < Size) return false;

        var codec = data[0] switch
        {
            1 => VideoCodec.H264,
            2 => VideoCodec.Hevc,
            _ => (VideoCodec?)null,
        };
        if (codec is null) return false;

        var flags = data[1];
        header = new VideoFrameHeader(
            codec.Value,
            (flags & KeyframeFlag) != 0,
            (flags & ParameterSetsFlag) != 0,
            (flags & EndOfStreamFlag) != 0,
            BinaryPrimitives.ReadUInt32BigEndian(data.Slice(4, 4)),
            BinaryPrimitives.ReadUInt64BigEndian(data.Slice(8, 8)),
            BinaryPrimitives.ReadUInt64BigEndian(data.Slice(16, 8)));
        body = data[Size..];
        return true;
    }
}

public enum AudioCodec : byte { AacLc = 1, PcmS16Le = 2 }

/// <summary>Audio channel header — <c>docs/PROTOCOL.md</c> section 7.</summary>
public readonly record struct AudioFrameHeader(
    AudioCodec Codec,
    byte Channels,
    bool IsParameterSets,
    uint SampleRate,
    uint Sequence,
    ulong PtsUs)
{
    public const int Size = 20;

    public byte[] Encode()
    {
        var buffer = new byte[Size];
        buffer[0] = (byte)Codec;
        buffer[1] = Channels;
        buffer[2] = IsParameterSets ? (byte)0x02 : (byte)0x00;
        BinaryPrimitives.WriteUInt32BigEndian(buffer.AsSpan(4, 4), SampleRate);
        BinaryPrimitives.WriteUInt32BigEndian(buffer.AsSpan(8, 4), Sequence);
        BinaryPrimitives.WriteUInt64BigEndian(buffer.AsSpan(12, 8), PtsUs);
        return buffer;
    }

    public static bool TryDecode(ReadOnlySpan<byte> data, out AudioFrameHeader header,
                                 out ReadOnlySpan<byte> body)
    {
        header = default;
        body = default;
        if (data.Length < Size) return false;
        if (!Enum.IsDefined(typeof(AudioCodec), data[0])) return false;

        header = new AudioFrameHeader(
            (AudioCodec)data[0],
            data[1],
            (data[2] & 0x02) != 0,
            BinaryPrimitives.ReadUInt32BigEndian(data.Slice(4, 4)),
            BinaryPrimitives.ReadUInt32BigEndian(data.Slice(8, 4)),
            BinaryPrimitives.ReadUInt64BigEndian(data.Slice(12, 8)));
        body = data[Size..];
        return true;
    }
}

/// <summary>Bulk channel header — <c>docs/PROTOCOL.md</c> section 8.</summary>
public readonly record struct BulkFrameHeader(BulkKind Kind, uint TransferId, ulong Offset)
{
    public const int Size = 16;
    public const int MaxChunkBytes = 256 * 1024;
    public const ulong AckIntervalBytes = 4UL * 1024 * 1024;

    public byte[] Encode()
    {
        var buffer = new byte[Size];
        buffer[0] = (byte)Kind;
        BinaryPrimitives.WriteUInt32BigEndian(buffer.AsSpan(4, 4), TransferId);
        BinaryPrimitives.WriteUInt64BigEndian(buffer.AsSpan(8, 8), Offset);
        return buffer;
    }

    public static bool TryDecode(ReadOnlySpan<byte> data, out BulkFrameHeader header,
                                 out ReadOnlySpan<byte> body)
    {
        header = default;
        body = default;
        if (data.Length < Size || !Enum.IsDefined(typeof(BulkKind), data[0])) return false;

        header = new BulkFrameHeader(
            (BulkKind)data[0],
            BinaryPrimitives.ReadUInt32BigEndian(data.Slice(4, 4)),
            BinaryPrimitives.ReadUInt64BigEndian(data.Slice(8, 8)));
        body = data[Size..];
        return true;
    }
}

public enum BulkKind : byte { Offer = 1, Chunk = 2, Ack = 3, Done = 4, Cancel = 5 }

public sealed class BulkOffer
{
    [JsonPropertyName("bytes")] public ulong Bytes { get; set; }
    [JsonPropertyName("kind")] public string Kind { get; set; } = "photo";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("rangeUs")] public List<ulong>? RangeUs { get; set; }
    [JsonPropertyName("sessionId")] public string? SessionId { get; set; }
    [JsonPropertyName("sha256")] public string Sha256 { get; set; } = "";
}
