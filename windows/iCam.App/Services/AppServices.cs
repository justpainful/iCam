using System.Reflection;
using System.Security.Cryptography;
using ICam.Core.Security;
using ICam.Core.Transport;
using Microsoft.UI.Dispatching;
using Windows.Storage;

namespace ICam.App.Services;

/// <summary>
/// Everything long-lived, built once.
///
/// Nothing in the application reaches for a singleton; each piece is handed
/// what it needs. That keeps the ownership graph obvious and lets the pieces be
/// exercised on their own.
/// </summary>
public sealed class AppServices : IAsyncDisposable
{
    public DeviceIdentity Identity { get; }
    public FileTrustStore Trust { get; }
    public SessionManager Sessions { get; }
    public ListenerService Listener { get; }
    public VirtualCameraService VirtualCamera { get; } = new();
    public AppSettings Settings { get; } = new();

    public string ComputerName => Environment.MachineName;

    public AppServices()
    {
        Identity = LoadOrCreateIdentity();
        Trust = new FileTrustStore();
        Sessions = new SessionManager(DispatcherQueue.GetForCurrentThread());
        Listener = new ListenerService(Identity, Trust, ComputerName);

        Listener.SessionAccepted += Sessions.Add;
        Listener.Failed += reason => Log.Net.Warn(reason);
    }

    public Task StartAsync() => Listener.StartAsync();

    public async ValueTask DisposeAsync()
    {
        await Listener.DisposeAsync();
        VirtualCamera.Dispose();
        Identity.Dispose();
    }

    public static string VersionString
    {
        get
        {
            var version = Assembly.GetExecutingAssembly().GetName().Version;
            return version is null ? "1.0.0" : $"{version.Major}.{version.Minor}.{version.Build}";
        }
    }

    /// <summary>
    /// The identity key, protected with DPAPI so it is readable by this user on
    /// this machine and by nobody else. Trust is bound to this key, so losing
    /// it means every phone pairs again — which is the correct outcome, and far
    /// better than a key anyone with the file could reuse.
    /// </summary>
    private static DeviceIdentity LoadOrCreateIdentity()
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "iCam");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "identity.bin");

        if (File.Exists(path))
        {
            try
            {
                var protectedBytes = File.ReadAllBytes(path);
                var key = ProtectedData.Unprotect(protectedBytes, null,
                                                  DataProtectionScope.CurrentUser);
                return DeviceIdentity.FromPrivateKey(key);
            }
            catch (Exception error) when (error is CryptographicException or IOException)
            {
                Log.Security.Warn("The stored identity could not be read; creating a new one. " +
                                  "Paired iPhones will need to pair again.");
            }
        }

        var identity = DeviceIdentity.Create();
        try
        {
            File.WriteAllBytes(path, ProtectedData.Protect(
                identity.ExportPrivateKey(), null, DataProtectionScope.CurrentUser));
            Log.Security.Info("Created this computer's iCam identity");
        }
        catch (Exception error) when (error is CryptographicException or IOException)
        {
            Log.Security.Error("Could not save the identity; pairing will not persist", error);
        }
        return identity;
    }
}

/// <summary>
/// Preferences that belong to this computer and this person. Camera settings
/// are not here — those belong to the phone, and are shared with it.
/// </summary>
public sealed class AppSettings
{
    private readonly ApplicationDataContainer? _container = TryGetContainer();

    private static ApplicationDataContainer? TryGetContainer()
    {
        try
        {
            return ApplicationData.Current.LocalSettings;
        }
        catch (InvalidOperationException)
        {
            // Unpackaged builds have no ApplicationData. Falling back to
            // defaults is better than refusing to start.
            return null;
        }
    }

    public bool StayInTrayOnClose
    {
        get => Read(nameof(StayInTrayOnClose), true);
        set => Write(nameof(StayInTrayOnClose), value);
    }

    public bool StartStreamingOnConnect
    {
        get => Read(nameof(StartStreamingOnConnect), true);
        set => Write(nameof(StartStreamingOnConnect), value);
    }

    public string StreamProfileName
    {
        get => Read(nameof(StreamProfileName), "1080p30");
        set => Write(nameof(StreamProfileName), value);
    }

    /// <summary>Remembered so the window opens where the user left it.</summary>
    public string WindowPlacement
    {
        get => Read(nameof(WindowPlacement), "");
        set => Write(nameof(WindowPlacement), value);
    }

    private T Read<T>(string key, T fallback)
    {
        if (_container?.Values.TryGetValue(key, out var value) == true && value is T typed)
        {
            return typed;
        }
        return fallback;
    }

    private void Write<T>(string key, T value)
    {
        if (_container is null) return;
        _container.Values[key] = value;
    }
}
