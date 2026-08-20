using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace ICam.App.Services;

/// <summary>
/// Registers <c>iCam Camera</c> with Windows and holds it open.
///
/// The lifetime is deliberately tied to this process. Windows keeps a software
/// camera source alive only while somebody holds the object, which is exactly
/// the behaviour iCam wants: the camera exists whenever iCam is running, and
/// disappears when it is not — rather than lingering in every application's
/// device list after the user has quit.
/// </summary>
public sealed class VirtualCameraHost : IDisposable
{
    private const string ClsidText = "{6EA042AA-06DB-4533-BADC-ADDF389ED998}";
    private const string FriendlyName = "iCam Camera";
    private const uint MfVersion = 0x00020070;

    private const string RegistryPath =
        @"SOFTWARE\Classes\CLSID\{6EA042AA-06DB-4533-BADC-ADDF389ED998}\InprocServer32";

    public enum InstallState
    {
        /// <summary>Registered and available to other applications.</summary>
        Ready,
        /// <summary>Never set up on this computer.</summary>
        NotInstalled,
        /// <summary>Registered, but the DLL it points at is gone.</summary>
        FileMissing,
        /// <summary>This build of Windows has no virtual camera support.</summary>
        Unsupported,
    }

    private IntPtr _camera = IntPtr.Zero;
    private IMFVirtualCamera? _virtualCamera;

    /// <summary>
    /// <c>MFCreateVirtualCamera</c> arrived in Windows 11 21H2. On anything
    /// older iCam still works as a preview and a remote control; only the
    /// device other applications can select is unavailable, and the interface
    /// says so rather than offering a switch that cannot work.
    /// </summary>
    public static bool IsSupportedByThisWindows =>
        OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000);

    public bool IsRunning { get; private set; }
    public string? LastError { get; private set; }

    public event Action? StateChanged;

    /// <summary>
    /// Whether the COM class is registered machine-wide and its DLL is present.
    ///
    /// Machine-wide is not a preference: the Frame Server runs as a service and
    /// cannot see a per-user registration, so `HKCU` yields a camera that is
    /// created successfully and never appears.
    /// </summary>
    public static InstallState CheckInstallation()
    {
        if (!IsSupportedByThisWindows) return InstallState.Unsupported;

        using var key = Registry.LocalMachine.OpenSubKey(RegistryPath);
        if (key?.GetValue(null) is not string path || string.IsNullOrWhiteSpace(path))
        {
            return InstallState.NotInstalled;
        }
        return File.Exists(path) ? InstallState.Ready : InstallState.FileMissing;
    }

    public bool Start()
    {
        if (IsRunning) return true;

        var state = CheckInstallation();
        if (state != InstallState.Ready)
        {
            LastError = state switch
            {
                InstallState.Unsupported =>
                    "iCam Camera needs Windows 11.",
                InstallState.FileMissing =>
                    "iCam Camera is registered but its files are missing. Set it up again.",
                _ => "iCam Camera has not been set up on this computer yet.",
            };
            StateChanged?.Invoke();
            return false;
        }

        var hr = MFStartup(MfVersion, 0);
        if (hr < 0)
        {
            LastError = "Windows could not start its media engine.";
            Log.Media.Error($"MFStartup 0x{hr:X8}");
            StateChanged?.Invoke();
            return false;
        }

        hr = MFCreateVirtualCamera(
            type: 0,        // SoftwareCameraSource
            lifetime: 0,    // Session — the camera lives as long as iCam does
            access: 0,      // CurrentUser
            FriendlyName, ClsidText, IntPtr.Zero, 0, out _camera);

        if (hr < 0)
        {
            LastError = "Windows refused to create iCam Camera.";
            Log.Media.Error($"MFCreateVirtualCamera 0x{hr:X8}");
            StateChanged?.Invoke();
            return false;
        }

        _virtualCamera = (IMFVirtualCamera)Marshal.GetObjectForIUnknown(_camera);
        hr = _virtualCamera.Start(IntPtr.Zero);
        if (hr < 0)
        {
            // The usual cause is a registration the Frame Server cannot reach.
            LastError = "Windows could not start iCam Camera. Try setting it up again.";
            Log.Media.Error($"IMFVirtualCamera.Start 0x{hr:X8}");
            Release();
            StateChanged?.Invoke();
            return false;
        }

        IsRunning = true;
        LastError = null;
        Log.Media.Info("iCam Camera is available to other applications");
        StateChanged?.Invoke();
        return true;
    }

    public void Stop()
    {
        if (!IsRunning) return;
        Release();
        IsRunning = false;
        Log.Media.Info("iCam Camera stopped");
        StateChanged?.Invoke();
    }

    private void Release()
    {
        if (_virtualCamera is not null)
        {
            try
            {
                _virtualCamera.Stop();
                _virtualCamera.Shutdown();
            }
            catch (COMException)
            {
                // Already gone. Nothing useful left to do.
            }
            Marshal.ReleaseComObject(_virtualCamera);
            _virtualCamera = null;
        }
        if (_camera != IntPtr.Zero)
        {
            Marshal.Release(_camera);
            _camera = IntPtr.Zero;
        }
    }

    public void Dispose() => Stop();

    [DllImport("mfplat.dll")]
    private static extern int MFStartup(uint version, uint flags);

    [DllImport("mfsensorgroup.dll", CharSet = CharSet.Unicode)]
    private static extern int MFCreateVirtualCamera(
        uint type, uint lifetime, uint access,
        [MarshalAs(UnmanagedType.LPWStr)] string friendlyName,
        [MarshalAs(UnmanagedType.LPWStr)] string sourceId,
        IntPtr categories, uint categoryCount, out IntPtr virtualCamera);
}

/// <summary>
/// <c>IMFVirtualCamera</c> derives from <c>IMFAttributes</c>, so its thirty
/// slots come first. They are never called here; only the vtable order matters,
/// and getting the count wrong lands every call on the wrong method.
/// </summary>
[ComImport, Guid("1C08A864-EF6C-4C75-AF59-5F2D68DA9563"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFVirtualCamera
{
    void Slot00(); void Slot01(); void Slot02(); void Slot03(); void Slot04();
    void Slot05(); void Slot06(); void Slot07(); void Slot08(); void Slot09();
    void Slot10(); void Slot11(); void Slot12(); void Slot13(); void Slot14();
    void Slot15(); void Slot16(); void Slot17(); void Slot18(); void Slot19();
    void Slot20(); void Slot21(); void Slot22(); void Slot23(); void Slot24();
    void Slot25(); void Slot26(); void Slot27(); void Slot28(); void Slot29();

    [PreserveSig] int AddDeviceSourceInfo([MarshalAs(UnmanagedType.LPWStr)] string info);
    [PreserveSig] int AddProperty(IntPtr key, uint type, IntPtr data, uint length);
    [PreserveSig] int AddRegistryEntry([MarshalAs(UnmanagedType.LPWStr)] string name,
                                       [MarshalAs(UnmanagedType.LPWStr)] string? subkey,
                                       uint type, IntPtr data, uint length);
    [PreserveSig] int Start(IntPtr callback);
    [PreserveSig] int Stop();
    [PreserveSig] int Remove();
    [PreserveSig] int GetMediaSource(out IntPtr source);
    [PreserveSig] int SendCameraProperty(IntPtr set, uint id, uint flags, IntPtr payload,
                                         uint payloadLength, IntPtr data, uint dataLength,
                                         out uint written);
    [PreserveSig] int CreateSyncEvent(IntPtr set, uint id, uint flags, IntPtr handle,
                                      out IntPtr syncObject);
    [PreserveSig] int CreateSyncSemaphore(IntPtr set, uint id, uint flags, IntPtr handle,
                                          int adjustment, out IntPtr syncObject);
    [PreserveSig] int Shutdown();
}
