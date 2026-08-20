using System.Buffers.Binary;

namespace ICam.Core.Protocol;

/// <summary>Constants shared by both halves of the protocol.</summary>
public static class Wire
{
    public const int ProtocolVersion = 1;
    public const ushort DefaultPort = 48213;
    public const string BonjourType = "_icam._tcp";

    public const int HeaderSize = 8;
    public const int MaxFrameLength = 16 * 1024 * 1024;
}

public enum Channel : byte
{
    Handshake = 0,
    Control = 1,
    Video = 2,
    Audio = 3,
    Bulk = 4,
}

[Flags]
public enum FrameFlags : byte
{
    None = 0,
    EndOfMessage = 1 << 0,
}

/// <summary>One frame, as described in <c>docs/PROTOCOL.md</c> section 3.</summary>
public readonly record struct Frame(Channel Channel, FrameFlags Flags, ReadOnlyMemory<byte> Payload)
{
    public Frame(Channel channel, ReadOnlyMemory<byte> payload)
        : this(channel, FrameFlags.EndOfMessage, payload) { }

    /// <summary>
    /// The eight bytes that prefix every frame. Built in one place because it
    /// is also the AEAD associated data — the sender and the receiver must
    /// produce byte-identical headers or every frame fails to open.
    /// </summary>
    public static byte[] Header(Channel channel, FrameFlags flags, int payloadCount)
    {
        var header = new byte[Wire.HeaderSize];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)(payloadCount + 4));
        header[4] = (byte)channel;
        header[5] = (byte)flags;
        header[6] = 0;
        header[7] = 0;
        return header;
    }

    public byte[] Encode()
    {
        var header = Header(Channel, Flags, Payload.Length);
        var result = new byte[header.Length + Payload.Length];
        header.CopyTo(result, 0);
        Payload.Span.CopyTo(result.AsSpan(header.Length));
        return result;
    }
}

public sealed class FrameException : Exception
{
    public enum Reason { Oversized, UnknownChannel, ReservedNotZero, Truncated }

    public Reason Kind { get; }
    public int Value { get; }

    public FrameException(Reason kind, int value, string message) : base(message)
    {
        Kind = kind;
        Value = value;
    }
}

/// <summary>
/// Incremental frame parser. Sockets hand it whatever arrived; it hands back
/// whole frames.
/// </summary>
public sealed class FrameParser
{
    private byte[] _buffer = new byte[64 * 1024];
    private int _length;

    public int PendingByteCount => _length;

    public void Append(ReadOnlySpan<byte> bytes)
    {
        EnsureCapacity(_length + bytes.Length);
        bytes.CopyTo(_buffer.AsSpan(_length));
        _length += bytes.Length;
    }

    /// <summary>
    /// Returns the next complete frame together with its raw header, or
    /// <c>false</c> when more bytes are needed.
    /// </summary>
    public bool TryRead(out Frame frame, out byte[] header)
    {
        frame = default;
        header = [];

        if (_length < Wire.HeaderSize) return false;

        var declared = BinaryPrimitives.ReadUInt32BigEndian(_buffer.AsSpan(0, 4));
        if (declared < 4)
        {
            throw new FrameException(FrameException.Reason.Truncated, (int)declared,
                "frame length is shorter than its own header");
        }
        if (declared > Wire.MaxFrameLength)
        {
            throw new FrameException(FrameException.Reason.Oversized, (int)declared,
                $"frame of {declared} bytes exceeds the {Wire.MaxFrameLength} byte limit");
        }

        var total = 4 + (int)declared;
        if (_length < total) return false;

        var rawChannel = _buffer[4];
        var rawFlags = _buffer[5];
        if (BinaryPrimitives.ReadUInt16BigEndian(_buffer.AsSpan(6, 2)) != 0)
        {
            throw new FrameException(FrameException.Reason.ReservedNotZero, 0,
                "reserved bytes must be zero");
        }

        if (!Enum.IsDefined(typeof(Channel), rawChannel))
        {
            // Unknown channels are skipped rather than fatal: a newer peer may
            // use one we do not implement yet. Consume the bytes first, so the
            // caller can carry on with the next frame.
            Consume(total);
            throw new FrameException(FrameException.Reason.UnknownChannel, rawChannel,
                $"unknown channel {rawChannel}");
        }

        header = _buffer.AsSpan(0, Wire.HeaderSize).ToArray();
        var payload = _buffer.AsSpan(Wire.HeaderSize, total - Wire.HeaderSize).ToArray();
        Consume(total);

        frame = new Frame((Channel)rawChannel, (FrameFlags)rawFlags, payload);
        return true;
    }

    public void Reset()
    {
        _length = 0;
        if (_buffer.Length > 1024 * 1024) _buffer = new byte[64 * 1024];
    }

    private void Consume(int count)
    {
        var remaining = _length - count;
        if (remaining > 0)
        {
            Buffer.BlockCopy(_buffer, count, _buffer, 0, remaining);
        }
        _length = remaining;
    }

    private void EnsureCapacity(int required)
    {
        if (_buffer.Length >= required) return;
        var capacity = _buffer.Length;
        while (capacity < required) capacity *= 2;
        var grown = new byte[capacity];
        Buffer.BlockCopy(_buffer, 0, grown, 0, _length);
        _buffer = grown;
    }
}
