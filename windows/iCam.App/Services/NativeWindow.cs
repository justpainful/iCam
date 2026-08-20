using System.Runtime.InteropServices;

namespace ICam.App.Services;

/// <summary>
/// The two Win32 calls WinUI does not wrap: finding another process's window
/// and bringing it forward. Used exactly once, when a second iCam declines to
/// start and hands the user back the one that already is.
///
/// Classic <c>DllImport</c> rather than <c>LibraryImport</c>, because the
/// source generator emits unsafe code and four P/Invokes are not a reason to
/// allow unsafe blocks across the whole application.
/// </summary>
internal static class NativeWindow
{
    public static void ActivateExisting(string title)
    {
        var window = FindWindowW(null, title);
        if (window == IntPtr.Zero) return;

        // Restore first: SetForegroundWindow on a minimised window brings
        // forward a window the user still cannot see.
        if (IsIconic(window)) ShowWindow(window, SW_RESTORE);
        SetForegroundWindow(window);
    }

    private const int SW_RESTORE = 9;

    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr FindWindowW(string? className, string windowName);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(IntPtr window, int command);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr window);
}
