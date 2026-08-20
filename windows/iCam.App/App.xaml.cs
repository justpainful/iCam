using ICam.App.Services;
using Microsoft.UI.Xaml;

namespace ICam.App;

/// <summary>
/// The composition root.
///
/// Everything long-lived is built here, once, and handed down. Nothing in the
/// application reaches for a singleton, which keeps the ownership graph obvious
/// and lets each piece be exercised on its own.
/// </summary>
public partial class App : Application
{
    public static App Instance { get; private set; } = null!;

    public AppServices Services { get; private set; } = null!;

    private MainWindow? _window;

    /// <summary>
    /// Held for the life of the process. There is exactly one iCam per
    /// session, because there is exactly one <c>iCam Camera</c> and one pipe
    /// to it — a second instance spent its life failing to create that pipe
    /// twice a second and filling the log with access-denied noise.
    /// </summary>
    private static readonly Mutex SingleInstance = new(false, @"Local\iCam.SingleInstance");

    public App()
    {
        InitializeComponent();
        Instance = this;

        // An unhandled exception on the UI thread should end up in the log with
        // a stack, not vanish into a silent process exit.
        UnhandledException += (_, e) =>
        {
            Log.App.Error("Unhandled exception on the UI thread", e.Exception);
            e.Handled = false;
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (!SingleInstance.WaitOne(TimeSpan.Zero, false))
        {
            // Another iCam is already running and owns the camera. Bring its
            // window forward rather than starting a rival.
            NativeWindow.ActivateExisting("iCam");
            Environment.Exit(0);
            return;
        }

        Services = new AppServices();
        _window = new MainWindow();
        _window.Activate();

        // Listening starts as soon as the window is up, so a phone that is
        // already looking finds this computer without the user doing anything.
        _ = Services.StartAsync();
    }

    /// <summary>
    /// Closing the window leaves iCam in the tray while a phone is connected or
    /// the virtual camera is live, and exits otherwise. Anything else would
    /// either surprise the user or kill their webcam mid-call.
    /// </summary>
    public bool ShouldStayResidentOnWindowClose =>
        Services.Sessions.HasActiveSession || Services.VirtualCamera.IsRunning;
}
