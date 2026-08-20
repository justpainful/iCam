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

        switch (VirtualCameraService.Installation)
        {
            case VirtualCameraHost.InstallState.Ready when camera.IsInUse:
                VirtualCameraState.Text = "In use by another app right now.";
                VirtualCameraButton.Content = "Set up again";
                VirtualCameraButton.IsEnabled = true;
                VirtualCameraInfo.IsOpen = false;
                break;

            case VirtualCameraHost.InstallState.Ready when camera.IsRunning:
                VirtualCameraState.Text =
                    "Ready. Choose iCam Camera in Zoom, Teams, Discord or OBS.";
                VirtualCameraButton.Content = "Set up again";
                VirtualCameraButton.IsEnabled = true;
                VirtualCameraInfo.IsOpen = false;
                break;

            case VirtualCameraHost.InstallState.Ready:
                VirtualCameraState.Text = camera.LastError ?? "Registered, but not started.";
                VirtualCameraButton.Content = "Set up again";
                VirtualCameraButton.IsEnabled = true;
                VirtualCameraInfo.IsOpen = false;
                break;

            case VirtualCameraHost.InstallState.FileMissing:
                VirtualCameraState.Text = "Registered, but its files are missing.";
                VirtualCameraButton.Content = "Set up again";
                VirtualCameraButton.IsEnabled = true;
                VirtualCameraInfo.Severity = InfoBarSeverity.Warning;
                VirtualCameraInfo.Title = "iCam Camera needs setting up again";
                VirtualCameraInfo.Message =
                    "It is registered with Windows, but the files it points at are gone.";
                VirtualCameraInfo.IsOpen = true;
                break;

            case VirtualCameraHost.InstallState.Unsupported:
                VirtualCameraState.Text = "Not available on this version of Windows.";
                VirtualCameraButton.IsEnabled = false;
                VirtualCameraInfo.Severity = InfoBarSeverity.Informational;
                VirtualCameraInfo.Title = "Windows 11 is required for iCam Camera";
                VirtualCameraInfo.Message =
                    "Everything else works here: live preview, full camera control, and "
                    + "recording. Only the camera other apps can select needs Windows 11.";
                VirtualCameraInfo.IsOpen = true;
                break;

            default:
                VirtualCameraState.Text = "Not set up on this computer yet.";
                VirtualCameraButton.Content = "Set up";
                VirtualCameraButton.IsEnabled = true;
                VirtualCameraInfo.Severity = InfoBarSeverity.Informational;
                VirtualCameraInfo.Title = "Setting up asks for permission once";
                VirtualCameraInfo.Message =
                    "The part of Windows that serves cameras runs as a service, and a "
                    + "service cannot see a per-user setup — so registering a camera needs "
                    + "administrator permission once. iCam itself always runs as you, and "
                    + "removing the camera later needs nothing.";
                VirtualCameraInfo.IsOpen = true;
                break;
        }
    }

    private async void OnEnableVirtualCamera(object sender, RoutedEventArgs e)
    {
        VirtualCameraButton.IsEnabled = false;
        try
        {
            var script = Path.Combine(AppContext.BaseDirectory, "VirtualCamera", "register.ps1");
            if (!File.Exists(script))
            {
                VirtualCameraInfo.Severity = InfoBarSeverity.Error;
                VirtualCameraInfo.Title = "The setup files are missing";
                VirtualCameraInfo.Message =
                    "iCam could not find what it needs to register the camera.";
                VirtualCameraInfo.IsOpen = true;
                return;
            }

            // Elevated for this one step and no longer. The application itself
            // never runs as administrator.
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{script}\"",
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            });
            if (process is not null) await process.WaitForExitAsync();

            Services.VirtualCamera.Start();
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // The user declined the permission prompt. That is an answer, not
            // a failure, and it does not deserve an error dialog.
            VirtualCameraInfo.Severity = InfoBarSeverity.Informational;
            VirtualCameraInfo.Title = "Setup was cancelled";
            VirtualCameraInfo.Message =
                "iCam Camera was not set up. Everything else keeps working.";
            VirtualCameraInfo.IsOpen = true;
        }
        finally
        {
            VirtualCameraButton.IsEnabled = true;
            RefreshVirtualCamera();
        }
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
