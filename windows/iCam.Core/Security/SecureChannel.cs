using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using ICam.Core.Protocol;

namespace ICam.Core.Security;

/// <summary>Derived key material for one connection.</summary>
public sealed record SessionKeys(
    byte[] ClientToServerKey,
    byte[] ServerToClientKey,
    byte[] ClientToServerSalt,
    byte[] ServerToClientSalt,
    string PairingDigits)
{
    /// <summary>
    /// The key schedule from <c>docs/PROTOCOL.md</c> section 4.2. Every
    /// primitive here exists natively in both CryptoKit and .NET, which is why
    /// the two implementations need no shared library and no third-party
    /// dependency to agree.
    /// </summary>
    public static SessionKeys Derive(byte[] sharedSecret, byte[] clientRandom, byte[] serverRandom)
    {
        var salt = new byte[clientRandom.Length + serverRandom.Length];
        clientRandom.CopyTo(salt, 0);
        serverRandom.CopyTo(salt, clientRandom.Length);

        var prk = HKDF.Extract(HashAlgorithmName.SHA256, sharedSecret, salt);

        byte[] Expand(string info, int length) =>
            HKDF.Expand(HashAlgorithmName.SHA256, prk, length, Encoding.UTF8.GetBytes(info));

        var sasSeed = Expand("iCam/v1 sas", 8);
        var value = BinaryPrimitives.ReadUInt64BigEndian(sasSeed) % 1_000_000;

        return new SessionKeys(
            Expand("iCam/v1 c2s key", 32),
            Expand("iCam/v1 s2c key", 32),
            Expand("iCam/v1 c2s salt", 4),
            Expand("iCam/v1 s2c salt", 4),
            value.ToString("D6"));
    }
}

public enum ChannelRole
{
    /// <summary>The iPhone. Connects, and proves itself first.</summary>
    Initiator,
    /// <summary>The PC. Listens.</summary>
    Responder,
}

public sealed class SecureChannelException : Exception
{
    public SecureChannelException(string message) : base(message) { }
}

/// <summary>
/// AES-256-GCM record layer — <c>docs/PROTOCOL.md</c> section 4.4.
///
/// One instance per connection. The frame counter is shared across all channels
/// in each direction, so a reordered or replayed frame is detected immediately.
/// </summary>
public sealed class SecureChannel : IDisposable
{
    private readonly AesGcm _seal;
    private readonly AesGcm _open;
    private readonly byte[] _sealSalt;
    private readonly byte[] _openSalt;

    private ulong _sendCounter;
    private ulong _receiveCounter;

    private const int TagSize = 16;
    private const int NonceSize = 12;

    public SecureChannel(SessionKeys keys, ChannelRole role)
    {
        if (role == ChannelRole.Responder)
        {
            _seal = new AesGcm(keys.ServerToClientKey, TagSize);
            _open = new AesGcm(keys.ClientToServerKey, TagSize);
            _sealSalt = keys.ServerToClientSalt;
            _openSalt = keys.ClientToServerSalt;
        }
        else
        {
            _seal = new AesGcm(keys.ClientToServerKey, TagSize);
            _open = new AesGcm(keys.ServerToClientKey, TagSize);
            _sealSalt = keys.ClientToServerSalt;
            _openSalt = keys.ServerToClientSalt;
        }
    }

    public ulong FramesSent => _sendCounter;
    public ulong FramesReceived => _receiveCounter;

    private static void WriteNonce(Span<byte> nonce, ReadOnlySpan<byte> salt, ulong counter)
    {
        salt.CopyTo(nonce);
        BinaryPrimitives.WriteUInt64BigEndian(nonce[salt.Length..], counter);
    }

    /// <summary>Seals a payload and returns the complete frame, header included.</summary>
    public byte[] Seal(Channel channel, ReadOnlySpan<byte> plaintext,
                       FrameFlags flags = FrameFlags.EndOfMessage)
    {
        // The header has to exist before sealing, because it is the associated
        // data — and its length field already accounts for the tag.
        var header = Frame.Header(channel, flags, plaintext.Length + TagSize);

        var result = new byte[header.Length + plaintext.Length + TagSize];
        header.CopyTo(result, 0);

        Span<byte> nonce = stackalloc byte[NonceSize];
        WriteNonce(nonce, _sealSalt, _sendCounter);

        _seal.Encrypt(nonce, plaintext,
                      result.AsSpan(header.Length, plaintext.Length),
                      result.AsSpan(header.Length + plaintext.Length, TagSize),
                      header);
        _sendCounter++;
        return result;
    }

    /// <summary>Opens a received frame. <paramref name="header"/> is the raw eight bytes.</summary>
    public byte[] Open(ReadOnlySpan<byte> header, ReadOnlySpan<byte> payload)
    {
        if (payload.Length < TagSize)
        {
            throw new SecureChannelException("frame is too short to contain an authentication tag");
        }

        var ciphertext = payload[..^TagSize];
        var tag = payload[^TagSize..];
        var plaintext = new byte[ciphertext.Length];

        Span<byte> nonce = stackalloc byte[NonceSize];
        WriteNonce(nonce, _openSalt, _receiveCounter);

        try
        {
            _open.Decrypt(nonce, ciphertext, tag, plaintext, header);
        }
        catch (CryptographicException)
        {
            // A frame that fails authentication means the stream is no longer
            // trustworthy. There is no safe way to skip it and continue.
            throw new SecureChannelException("frame failed authentication");
        }

        _receiveCounter++;
        return plaintext;
    }

    public void Dispose()
    {
        _seal.Dispose();
        _open.Dispose();
    }
}
