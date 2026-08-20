using System.Text.Json;
using System.Text.Json.Serialization;
using ICam.Core.Security;

namespace ICam.Core.Transport;

/// <summary>
/// Persistent record of which iPhones this computer trusts.
///
/// Trust is bound to a public key. An attacker who takes over the address or
/// the name of a paired iPhone still fails the handshake, because the signature
/// will not verify.
/// </summary>
public sealed class FileTrustStore : ITrustStore
{
    private sealed class Entry
    {
        [JsonPropertyName("id")] public string Id { get; set; } = "";
        [JsonPropertyName("lastSeenAt")] public DateTimeOffset? LastSeenAt { get; set; }
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("pairedAt")] public DateTimeOffset PairedAt { get; set; }
        [JsonPropertyName("publicKey")] public byte[] PublicKey { get; set; } = [];
    }

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    private readonly string _path;
    private readonly Lock _lock = new();
    private List<Entry> _entries = [];

    public FileTrustStore(string? path = null)
    {
        _path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "iCam", "trusted-devices.json");
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        Load();
    }

    public IReadOnlyList<TrustedPeer> Peers
    {
        get
        {
            lock (_lock)
            {
                return _entries
                    .Select(e => new TrustedPeer(e.Id, e.Name, e.PublicKey, e.PairedAt, e.LastSeenAt))
                    .ToList();
            }
        }
    }

    public bool IsTrusted(ReadOnlySpan<byte> publicKey)
    {
        var fingerprint = DeviceIdentity.FingerprintOf(publicKey);
        lock (_lock)
        {
            return _entries.Any(e => e.Id == fingerprint);
        }
    }

    public void Trust(byte[] publicKey, string name)
    {
        var fingerprint = DeviceIdentity.FingerprintOf(publicKey);
        lock (_lock)
        {
            var existing = _entries.FirstOrDefault(e => e.Id == fingerprint);
            if (existing is not null)
            {
                existing.Name = name;
                existing.LastSeenAt = DateTimeOffset.UtcNow;
            }
            else
            {
                _entries.Add(new Entry
                {
                    Id = fingerprint,
                    Name = name,
                    PublicKey = publicKey,
                    PairedAt = DateTimeOffset.UtcNow,
                    LastSeenAt = DateTimeOffset.UtcNow,
                });
            }
            Save();
        }
    }

    public void NoteSeen(string fingerprint)
    {
        lock (_lock)
        {
            var existing = _entries.FirstOrDefault(e => e.Id == fingerprint);
            if (existing is null) return;
            existing.LastSeenAt = DateTimeOffset.UtcNow;
            Save();
        }
    }

    public void Forget(string fingerprint)
    {
        lock (_lock)
        {
            _entries.RemoveAll(e => e.Id == fingerprint);
            Save();
        }
    }

    private void Load()
    {
        if (!File.Exists(_path)) return;
        try
        {
            _entries = JsonSerializer.Deserialize<List<Entry>>(File.ReadAllBytes(_path), Options)
                       ?? [];
        }
        catch (Exception error) when (error is JsonException or IOException)
        {
            // A corrupt trust file must not stop the application, but it also
            // must not silently become "trust nothing" with no trace.
            Console.Error.WriteLine($"iCam: trust store unreadable, starting empty ({error.Message})");
            _entries = [];
        }
    }

    private void Save()
    {
        try
        {
            // Written beside the target and moved into place, so a crash
            // mid-write cannot leave a half-written trust file behind.
            var temporary = _path + ".tmp";
            File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(_entries, Options));
            File.Move(temporary, _path, overwrite: true);
        }
        catch (IOException error)
        {
            Console.Error.WriteLine($"iCam: could not save the trust store ({error.Message})");
        }
    }
}

/// <summary>An in-memory trust store, for tests and for a first run.</summary>
public sealed class InMemoryTrustStore : ITrustStore
{
    private readonly List<TrustedPeer> _peers = [];

    public IReadOnlyList<TrustedPeer> Peers => _peers;

    public bool IsTrusted(ReadOnlySpan<byte> publicKey)
    {
        var fingerprint = DeviceIdentity.FingerprintOf(publicKey);
        return _peers.Any(p => p.Id == fingerprint);
    }

    public void Trust(byte[] publicKey, string name)
    {
        var fingerprint = DeviceIdentity.FingerprintOf(publicKey);
        _peers.RemoveAll(p => p.Id == fingerprint);
        _peers.Add(new TrustedPeer(fingerprint, name, publicKey,
                                   DateTimeOffset.UtcNow, DateTimeOffset.UtcNow));
    }

    public void NoteSeen(string fingerprint) { }

    public void Forget(string fingerprint) => _peers.RemoveAll(p => p.Id == fingerprint);
}
