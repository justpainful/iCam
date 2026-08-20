using System.Diagnostics;
using ICam.App.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace ICam.App.Views;

public sealed partial class SettingsPage : Page
{
    private AppServices Services => App.Instance.Services;
    private bool _loading;

    public SettingsPage() => InitializeComponent();

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _loading = true;
        try
        {
            SelectByTag(ProfilePicker, Services.Settings.StreamProfileName);
            AutoStreamToggle.IsOn = Services.Settings.StartStreamingOnConnect;
            TrayToggle.IsOn = Services.Settings.StayInTrayOnClose;

            VersionText.Text = AppServices.VersionString;
            FingerprintText.Text = Format(Services.Identity.Fingerprint);
            RefreshVirtualCamera();
        }
        finally
        {
            _loading = false;
        }
    }

    private void RefreshVirtualCamera()
    {
        var camera = Services.VirtualCamera;
        switch (camera.State)
        {
            case VirtualCameraService.InstallState.Installed:
                VirtualCameraState.Text = "Ready. Other apps can pick it as a camera.";
                VirtualCameraButton.Content = "Remove";
                VirtualCameraButton.IsEnabled = true;
                VirtualCameraInfo.IsOpen = false;
                break;

            case VirtualCameraService.InstallState.NotInstalled:
                VirtualCameraState.Text = "Not set up yet.";
                VirtualCameraButton.Content = "Enable";
                VirtualCameraButton.IsEnabled = true;
                VirtualCameraInfo.IsOpen = false;
                break;

            case VirtualCameraService.InstallState.NeedsElevation:
                VirtualCameraState.Text = "Needs permission to finish setting up.";
                VirtualCameraButton.Content = "Enable";
                VirtualCameraButton.IsEnabled = true;
                VirtualCameraInfo.Severity = InfoBarSeverity.Warning;
                VirtualCameraInfo.Title = "One-time permission needed";
                VirtualCameraInfo.Message =
                    "Registering a camera with Windows needs administrator permission once. "
                    + "iCam itself keeps running as you.";
                VirtualCameraInfo.IsOpen = true;
                break;

            case VirtualCameraService.InstallState.Unsupported:
                VirtualCameraState.Text = "Not available on this version of Windows.";
                VirtualCameraButton.IsEnabled = false;
                VirtualCameraInfo.Severity = InfoBarSeverity.Informational;
                VirtualCameraInfo.Title = "Windows 11 is required for iCam Camera";
                VirtualCameraInfo.Message =
                    "Everything else works here: live preview, full camera control, and "
                    + "recording. Only the virtual camera other apps can select needs "
                    + "Windows 11.";
                VirtualCameraInfo.IsOpen = true;
                break;
        }
    }

    private void OnEnableVirtualCamera(object sender, RoutedEventArgs e)
    {
        // Registration is a separate, elevated step that installs the frame
        // source. It is not implemented yet, and the interface says so rather
        // than showing a button that silently does nothing.
        VirtualCameraInfo.Severity = InfoBarSeverity.Informational;
        VirtualCameraInfo.Title = "Not available in this build";
        VirtualCameraInfo.Message =
            "iCam Camera is still being built. Live preview and camera control work now; "
            + "this switch will turn on the device other apps can select.";
        VirtualCameraInfo.IsOpen = true;
    }

    private void OnProfileChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if ((ProfilePicker.SelectedItem as ComboBoxItem)?.Tag is string tag)
        {
            Services.Settings.StreamProfileName = tag;
        }
    }

    private void OnAutoStreamToggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        Services.Settings.StartStreamingOnConnect = AutoStreamToggle.IsOn;
    }

    private void OnTrayToggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        Services.Settings.StayInTrayOnClose = TrayToggle.IsOn;
    }

    private void OnOpenLogs(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(Log.LogDirectory);
        Process.Start(new ProcessStartInfo
        {
            FileName = Log.LogDirectory,
            UseShellExecute = true,
        });
    }

    private static void SelectByTag(ComboBox box, string tag)
    {
        for (var i = 0; i < box.Items.Count; i++)
        {
            if (box.Items[i] is ComboBoxItem item && (item.Tag as string) == tag)
            {
                box.SelectedIndex = i;
                return;
            }
        }
        box.SelectedIndex = 1;
    }

    /// <summary>
    /// Groups the fingerprint so a person can actually compare it against the
    /// one on their phone.
    /// </summary>
    private static string Format(string fingerprint) =>
        string.Join(' ', Enumerable.Range(0, fingerprint.Length / 4)
            .Select(i => fingerprint.Substring(i * 4, 4)));
}
