using System.Runtime.InteropServices;
using ICam.Core.Protocol;

namespace ICam.App.Services;

/// <summary>
/// Publishes this computer as <c>_icam._tcp</c> on the local network, using the
/// mDNS responder built into Windows.
///
/// <c>DnsServiceRegister</c> is used rather than the WinRT
/// <c>DnssdServiceInstance</c> API because the WinRT one can only advertise a
/// <c>StreamSocketListener</c> it owns, and iCam wants a plain socket it can
/// tune. This registers whatever port the listener actually got.
///
/// If registration fails — a locked-down network profile, a policy that
/// disables mDNS — that is reported, not hidden. The user can still connect by
/// address, and the interface says so instead of showing an empty list forever.
/// </summary>
public sealed class DnssdAdvertiser : IDisposable
{
    private const uint DnsRequestPending = 9506;
    private const uint DnsQueryRequestVersion1 = 1;

    private IntPtr _instance = IntPtr.Zero;
    private RegisterComplete? _callback;   // held so the GC cannot collect it
    private GCHandle _pinnedKeys;
    private GCHandle _pinnedValues;

    public bool IsAdvertising { get; private set; }
    public string? FailureReason { get; private set; }

    public event Action? StateChanged;

    /// <param name="computerName">What the phone shows in its device list.</param>
    /// <param name="fingerprint">
    /// The identity fingerprint, so a phone can recognise a computer it already
    /// trusts before it connects — rather than trusting a name or an address,
    /// either of which anything on the network can claim.
    /// </param>
    public void Start(string computerName, string fingerprint, ushort port)
    {
        Stop();

        try
        {
            // "iCam on RAEID-PC._icam._tcp.local" — the instance name is what
            // Bonjour browsers show if the TXT record is unavailable.
            var instanceName = $"{Sanitise(computerName)}.{Wire.BonjourType}.local";
            var hostName = $"{Sanitise(Environment.MachineName)}.local";

            string[] keys = ["v", "name", "id", "os"];
            string[] values = [Wire.ProtocolVersion.ToString(), computerName, fingerprint, "windows"];

            var keyPointers = keys.Select(Marshal.StringToHGlobalUni).ToArray();
            var valuePointers = values.Select(Marshal.StringToHGlobalUni).ToArray();
            _pinnedKeys = GCHandle.Alloc(keyPointers, GCHandleType.Pinned);
            _pinnedValues = GCHandle.Alloc(valuePointers, GCHandleType.Pinned);

            _instance = DnsServiceConstructInstance(
                instanceName, hostName,
                IntPtr.Zero, IntPtr.Zero,
                port, 0, 0,
                (uint)keys.Length,
                _pinnedKeys.AddrOfPinnedObject(),
                _pinnedValues.AddrOfPinnedObject());

            if (_instance == IntPtr.Zero)
            {
                Fail("Windows could not build the network advertisement.");
                return;
            }

            _callback = OnRegisterComplete;
            var request = new DnsServiceRegisterRequest
            {
                Version = DnsQueryRequestVersion1,
                InterfaceIndex = 0,
                ServiceInstance = _instance,
                RegisterCompletionCallback = Marshal.GetFunctionPointerForDelegate(_callback),
                QueryContext = IntPtr.Zero,
                Credentials = IntPtr.Zero,
                UnicastEnabled = false,
            };

            var status = DnsServiceRegister(ref request, IntPtr.Zero);
            if (status is not DnsRequestPending and not 0)
            {
                Fail($"Windows refused the network advertisement (error {status}).");
                return;
            }

            IsAdvertising = true;
            FailureReason = null;
            Log.Net.Info($"Advertising {Wire.BonjourType} on port {port}");
            StateChanged?.Invoke();
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException)
        {
            Fail("This version of Windows does not support network device discovery.");
        }
    }

    public void Stop()
    {
        if (_instance != IntPtr.Zero)
        {
            try
            {
                var request = new DnsServiceRegisterRequest
                {
                    Version = DnsQueryRequestVersion1,
                    ServiceInstance = _instance,
                };
                DnsServiceDeRegister(ref request, IntPtr.Zero);
                DnsServiceFreeInstance(_instance);
            }
            catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException)
            {
                // Nothing was registered; nothing to undo.
            }
            _instance = IntPtr.Zero;
        }

        if (_pinnedKeys.IsAllocated)
        {
            FreeStrings(_pinnedKeys);
            _pinnedKeys.Free();
        }
        if (_pinnedValues.IsAllocated)
        {
            FreeStrings(_pinnedValues);
            _pinnedValues.Free();
        }

        _callback = null;
        if (IsAdvertising)
        {
            IsAdvertising = false;
            StateChanged?.Invoke();
        }
    }

    private static void FreeStrings(GCHandle handle)
    {
        if (handle.Target is not IntPtr[] pointers) return;
        foreach (var pointer in pointers)
        {
            if (pointer != IntPtr.Zero) Marshal.FreeHGlobal(pointer);
        }
    }

    private void Fail(string reason)
    {
        FailureReason = reason;
        IsAdvertising = false;
        Log.Net.Warn(reason);
        StateChanged?.Invoke();
    }

    private void OnRegisterComplete(uint status, IntPtr context, IntPtr instance)
    {
        if (status != 0)
        {
            Fail($"Windows could not advertise iCam on this network (error {status}).");
            return;
        }
        IsAdvertising = true;
        StateChanged?.Invoke();
    }

    public void Dispose() => Stop();

    /// <summary>
    /// DNS labels cannot contain a dot, and a computer name legitimately can.
    /// </summary>
    private static string Sanitise(string value)
    {
        var cleaned = value.Replace('.', '-').Trim();
        return string.IsNullOrEmpty(cleaned) ? "iCam" : cleaned;
    }

    // MARK: - Native

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate void RegisterComplete(uint status, IntPtr context, IntPtr instance);

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceRegisterRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr ServiceInstance;
        public IntPtr RegisterCompletionCallback;
        public IntPtr QueryContext;
        public IntPtr Credentials;
        [MarshalAs(UnmanagedType.Bool)] public bool UnicastEnabled;
    }

    // Classic DllImport rather than LibraryImport: these signatures pass a
    // struct containing a marshalled BOOL, and the source generator would
    // require the whole assembly to opt out of runtime marshalling to handle
    // it. Turning that off across a WinUI project to save one interop stub is
    // not a trade worth making.
    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr DnsServiceConstructInstance(
        string serviceName, string hostName,
        IntPtr ip4, IntPtr ip6,
        ushort port, ushort priority, ushort weight,
        uint propertiesCount, IntPtr keys, IntPtr values);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceRegister(ref DnsServiceRegisterRequest request,
                                                  IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceDeRegister(ref DnsServiceRegisterRequest request,
                                                    IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern void DnsServiceFreeInstance(IntPtr instance);
}
