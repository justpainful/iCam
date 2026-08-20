using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using ICam.Core.Security;

namespace ICam.Core.Protocol;

/// <summary>
/// Canonical JSON for the handshake.
///
/// Both peers must produce byte-identical bytes or the transcript signature
/// fails, so two things are pinned here: properties are declared in sorted key
/// order (System.Text.Json writes them in declaration order, matching Swift's
/// <c>.sortedKeys</c>), and the relaxed encoder is used so a device named in
/// Arabic or Japanese is written as UTF-8 rather than as <c>\uXXXX</c> escapes,
/// which is what Swift does.
/// </summary>
public static class HandshakeCodec
{
    public static readonly JsonSerializerOptions Options = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = false,
    };

    public static byte[] Encode<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);

    public static T? Decode<T>(ReadOnlySpan<byte> data) =>
        JsonSerializer.Deserialize<T>(data, Options);

    /// <summary>Peeks at <c>t</c> without committing to a concrete message type.</summary>
    public static string? MessageType(ReadOnlySpan<byte> data)
    {
        try
        {
            using var document = JsonDocument.Parse(data.ToArray());
            return document.RootElement.TryGetProperty("t", out var element)
                ? element.GetString()
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

public sealed class DeviceInfo
{
    [JsonPropertyName("app")] public string App { get; set; } = "";
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("model")] public string Model { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("os")] public string Os { get; set; } = "";
}

public sealed class ClientHello
{
    [JsonPropertyName("dev")] public DeviceInfo Dev { get; set; } = new();
    [JsonPropertyName("eph")] public byte[] Eph { get; set; } = [];
    [JsonPropertyName("idk")] public byte[] Idk { get; set; } = [];
    [JsonPropertyName("rnd")] public byte[] Rnd { get; set; } = [];
    [JsonPropertyName("t")] public string T { get; set; } = "hello";
    [JsonPropertyName("v")] public int V { get; set; } = Wire.ProtocolVersion;
}

public sealed class ServerHello
{
    [JsonPropertyName("dev")] public DeviceInfo Dev { get; set; } = new();
    [JsonPropertyName("eph")] public byte[] Eph { get; set; } = [];
    [JsonPropertyName("idk")] public byte[] Idk { get; set; } = [];
    [JsonPropertyName("rnd")] public byte[] Rnd { get; set; } = [];
    [JsonPropertyName("sig")] public byte[]? Sig { get; set; }
    [JsonPropertyName("t")] public string T { get; set; } = "hello_ack";
    [JsonPropertyName("v")] public int V { get; set; } = Wire.ProtocolVersion;

    /// <summary>The exact bytes the transcript covers: this message without <c>sig</c>.</summary>
    public byte[] TranscriptBytes()
    {
        var copy = new ServerHello
        {
            Dev = Dev, Eph = Eph, Idk = Idk, Rnd = Rnd, Sig = null, T = T, V = V,
        };
        return HandshakeCodec.Encode(copy);
    }
}

public sealed class ClientAuth
{
    [JsonPropertyName("sig")] public byte[] Sig { get; set; } = [];
    [JsonPropertyName("t")] public string T { get; set; } = "auth";
}

public sealed class HandshakeReady
{
    [JsonPropertyName("t")] public string T { get; set; } = "ready";
    [JsonPropertyName("trusted")] public bool Trusted { get; set; }
}

public sealed class HandshakeException : Exception
{
    public enum Reason { VersionMismatch, Malformed, BadSignature, WrongMessage }

    public Reason Kind { get; }

    public HandshakeException(Reason kind, string message) : base(message) => Kind = kind;
}

/// <summary>
/// Drives the responder half of the handshake. The PC always listens: it is the
/// stationary device, with the stable address and the firewall the user
/// controls.
/// </summary>
public sealed class ResponderHandshake : IDisposable
{
    private readonly DeviceIdentity _identity;
    private readonly DeviceInfo _deviceInfo;
    private readonly EphemeralKeyPair _ephemeral = new();
    private readonly byte[] _serverRandom = RandomNumberGenerator.GetBytes(32);

    private byte[] _transcript = [];

    public byte[] PeerIdentityKey { get; private set; } = [];
    public DeviceInfo? PeerDevice { get; private set; }
    public SessionKeys? Keys { get; private set; }

    public ResponderHandshake(DeviceIdentity identity, DeviceInfo deviceInfo)
    {
        _identity = identity;
        _deviceInfo = deviceInfo;
    }

    /// <summary>Step 1 and 2 — consume the client hello, produce the server hello.</summary>
    public byte[] HandleClientHello(ReadOnlySpan<byte> data)
    {
        var hello = HandshakeCodec.Decode<ClientHello>(data)
            ?? throw new HandshakeException(HandshakeException.Reason.Malformed,
                                            "client hello could not be read");

        if (hello.T != "hello")
        {
            throw new HandshakeException(HandshakeException.Reason.WrongMessage,
                                         $"expected hello, got {hello.T}");
        }
        if (hello.V != Wire.ProtocolVersion)
        {
            throw new HandshakeException(HandshakeException.Reason.VersionMismatch,
                                         $"peer speaks protocol version {hello.V}");
        }

        PeerIdentityKey = hello.Idk;
        PeerDevice = hello.Dev;

        var response = new ServerHello
        {
            Dev = _deviceInfo,
            Eph = _ephemeral.PublicKey,
            Idk = _identity.PublicKey,
            Rnd = _serverRandom,
        };

        // The transcript is the client's bytes exactly as they arrived, followed
        // by ours without the signature.
        var unsigned = response.TranscriptBytes();
        _transcript = new byte[data.Length + unsigned.Length];
        data.CopyTo(_transcript);
        unsigned.CopyTo(_transcript.AsSpan(data.Length));

        response.Sig = _identity.Sign(Prefixed("iCam/v1/server", _transcript));

        var shared = _ephemeral.SharedSecret(hello.Eph);
        Keys = SessionKeys.Derive(shared, hello.Rnd, _serverRandom);

        return HandshakeCodec.Encode(response);
    }

    /// <summary>Step 3 — verify the client's signature over the same transcript.</summary>
    public void HandleClientAuth(ReadOnlySpan<byte> data)
    {
        var auth = HandshakeCodec.Decode<ClientAuth>(data)
            ?? throw new HandshakeException(HandshakeException.Reason.Malformed,
                                            "client auth could not be read");
        if (auth.T != "auth")
        {
            throw new HandshakeException(HandshakeException.Reason.WrongMessage,
                                         $"expected auth, got {auth.T}");
        }
        if (!DeviceIdentity.Verify(auth.Sig, Prefixed("iCam/v1/client", _transcript),
                                   PeerIdentityKey))
        {
            throw new HandshakeException(HandshakeException.Reason.BadSignature,
                                         "the iPhone's signature did not verify");
        }
    }

    /// <summary>Step 4 — tell the iPhone whether this computer already trusts it.</summary>
    public byte[] Ready(bool trusted) =>
        HandshakeCodec.Encode(new HandshakeReady { Trusted = trusted });

    public void Dispose() => _ephemeral.Dispose();

    private static byte[] Prefixed(string label, byte[] transcript)
    {
        var prefix = Encoding.UTF8.GetBytes(label);
        var message = new byte[prefix.Length + transcript.Length];
        prefix.CopyTo(message, 0);
        transcript.CopyTo(message, prefix.Length);
        return message;
    }
}
