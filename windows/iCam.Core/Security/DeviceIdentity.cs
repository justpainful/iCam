using System.Security.Cryptography;

namespace ICam.Core.Security;

/// <summary>
/// This computer's long-lived cryptographic identity.
///
/// Trust is bound to this key, never to an IP address, a hostname, or a shared
/// password. An attacker who takes over a paired iPhone's address still fails
/// the handshake, because the signature will not verify.
/// </summary>
public sealed class DeviceIdentity : IDisposable
{
    private readonly ECDsa _key;

    private DeviceIdentity(ECDsa key) => _key = key;

    public static DeviceIdentity Create() =>
        new(ECDsa.Create(ECCurve.NamedCurves.nistP256));

    public static DeviceIdentity FromPrivateKey(ReadOnlySpan<byte> pkcs8)
    {
        var key = ECDsa.Create();
        key.ImportPkcs8PrivateKey(pkcs8, out _);
        return new DeviceIdentity(key);
    }

    public byte[] ExportPrivateKey() => _key.ExportPkcs8PrivateKey();

    /// <summary>X9.63 uncompressed point, 65 bytes, first byte 0x04.</summary>
    public byte[] PublicKey
    {
        get
        {
            var parameters = _key.ExportParameters(false);
            var x = Pad(parameters.Q.X!, 32);
            var y = Pad(parameters.Q.Y!, 32);
            var result = new byte[65];
            result[0] = 0x04;
            x.CopyTo(result, 1);
            y.CopyTo(result, 33);
            return result;
        }
    }

    /// <summary>First 16 bytes of SHA-256 over the public key, lowercase hex.</summary>
    public string Fingerprint => FingerprintOf(PublicKey);

    public static string FingerprintOf(ReadOnlySpan<byte> publicKey)
    {
        Span<byte> digest = stackalloc byte[32];
        SHA256.HashData(publicKey, digest);
        return Convert.ToHexStringLower(digest[..16]);
    }

    public byte[] Sign(ReadOnlySpan<byte> message) =>
        _key.SignData(message, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);

    public static bool Verify(ReadOnlySpan<byte> signature, ReadOnlySpan<byte> message,
                              ReadOnlySpan<byte> publicKey)
    {
        if (publicKey.Length != 65 || publicKey[0] != 0x04) return false;
        try
        {
            using var key = ECDsa.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint
                {
                    X = publicKey.Slice(1, 32).ToArray(),
                    Y = publicKey.Slice(33, 32).ToArray(),
                },
            });
            return key.VerifyData(message, signature, HashAlgorithmName.SHA256,
                                  DSASignatureFormat.Rfc3279DerSequence);
        }
        catch (CryptographicException)
        {
            return false;
        }
    }

    public void Dispose() => _key.Dispose();

    private static byte[] Pad(byte[] value, int length)
    {
        if (value.Length == length) return value;
        var padded = new byte[length];
        value.CopyTo(padded, length - value.Length);
        return padded;
    }
}

/// <summary>Ephemeral P-256 key agreement, one pair per connection.</summary>
public sealed class EphemeralKeyPair : IDisposable
{
    private readonly ECDiffieHellman _key;

    public EphemeralKeyPair() => _key = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);

    public byte[] PublicKey
    {
        get
        {
            var parameters = _key.ExportParameters(false);
            var result = new byte[65];
            result[0] = 0x04;
            Pad(parameters.Q.X!, 32).CopyTo(result, 1);
            Pad(parameters.Q.Y!, 32).CopyTo(result, 33);
            return result;
        }
    }

    /// <summary>
    /// The raw 32-byte X coordinate of the shared point.
    ///
    /// .NET's <c>DeriveKeyMaterial</c> hashes the result, and CryptoKit's
    /// <c>SharedSecret</c> does not — so the raw value is derived here to keep
    /// the two key schedules identical.
    /// </summary>
    public byte[] SharedSecret(ReadOnlySpan<byte> peerPublicKey)
    {
        if (peerPublicKey.Length != 65 || peerPublicKey[0] != 0x04)
        {
            throw new ArgumentException("expected an X9.63 uncompressed P-256 point",
                                        nameof(peerPublicKey));
        }
        using var peer = ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint
            {
                X = peerPublicKey.Slice(1, 32).ToArray(),
                Y = peerPublicKey.Slice(33, 32).ToArray(),
            },
        });
        return _key.DeriveRawSecretAgreement(peer.PublicKey);
    }

    public void Dispose() => _key.Dispose();

    private static byte[] Pad(byte[] value, int length)
    {
        if (value.Length == length) return value;
        var padded = new byte[length];
        value.CopyTo(padded, length - value.Length);
        return padded;
    }
}
