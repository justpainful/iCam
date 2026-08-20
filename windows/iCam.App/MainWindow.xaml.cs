using ICam.App.Services;
using ICam.App.Views;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.Graphics;

namespace ICam.App;

public sealed partial class MainWindow : Window
{
    private readonly AppWindow _appWindow;
    private AppServices Services => App.Instance.Services;

    public MainWindow()
    {
        InitializeComponent();

        _appWindow = AppWindow;
        _appWindow.Title = "iCam";
        _appWindow.SetIcon("Assets/iCam.ico");

        ConfigureTitleBar();
        ConfigureBackdrop();
        RestorePlacement();

        Closed += OnClosed;

        Services.Sessions.DeviceAdded += _ => UpdateStatus();
        Services.Sessions.DeviceRemoved += _ => UpdateStatus();
        Services.Sessions.PairingRequested += OnPairingRequested;

        Navigate("camera");
        UpdateStatus();
    }

    // MARK: - Chrome

    private void ConfigureTitleBar()
    {
        // Draw into the title bar, but let Windows keep the caption buttons.
        // Reimplementing them is how applications end up with a close button
        // that ignores Snap, ignores the system menu, and looks wrong at 150%.
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);

        if (AppWindowTitleBar.IsCustomizationSupported())
        {
            var titleBar = _appWindow.TitleBar;
            titleBar.ButtonBackgroundColor = Colors.Transparent;
            titleBar.ButtonInactiveBackgroundColor = Colors.Transparent;
        }
    }

    private void ConfigureBackdrop()
    {
        // Mica is the window's long-lived material. Acrylic is reserved for
        // transient surfaces — menus and flyouts — where it belongs.
        if (MicaController.IsSupported())
        {
            SystemBackdrop = new MicaBackdrop { Kind = MicaKind.Base };
        }
        else if (DesktopAcrylicController.IsSupported())
        {
            SystemBackdrop = new DesktopAcrylicBackdrop();
        }
        else
        {
            // No backdrop available. Falling back to the proper system colour
            // is far better than leaving a transparent window.
            RootGrid.Background = (Brush)Application.Current
                .Resources["ApplicationPageBackgroundThemeBrush"];
        }
    }

    private void RestorePlacement()
    {
        var stored = Services.Settings.WindowPlacement;
        var parts = stored.Split(',');
        if (parts.Length == 4
            && int.TryParse(parts[0], out var x) && int.TryParse(parts[1], out var y)
            && int.TryParse(parts[2], out var width) && int.TryParse(parts[3], out var height)
            && width > 400 && height > 300)
        {
            // Only restored if it still lands on a display the user has. A
            // window remembered onto a monitor that is no longer attached is
            // a window the user cannot find.
            var area = DisplayArea.GetFromPoint(new PointInt32(x, y), DisplayAreaFallback.None);
            if (area is not null)
            {
                _appWindow.MoveAndResize(new RectInt32(x, y, width, height));
                return;
            }
        }
        _appWindow.Resize(new SizeInt32(1180, 760));
    }

    private void SavePlacement()
    {
        var position = _appWindow.Position;
        var size = _appWindow.Size;
        Services.Settings.WindowPlacement =
            $"{position.X},{position.Y},{size.Width},{size.Height}";
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        SavePlacement();

        // Closing the window while a phone is connected leaves iCam running, so
        // `iCam Camera` does not vanish from the middle of somebody's call.
        // With nothing connected, closing means closing.
        if (App.Instance.ShouldStayResidentOnWindowClose && Services.Settings.StayInTrayOnClose)
        {
            args.Handled = true;
            _appWindow.Hide();
        }
    }

    // MARK: - Navigation

    private void OnNavigationSelectionChanged(NavigationView sender,
                                              NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem { Tag: string tag })
        {
            Navigate(tag);
        }
    }

    private void Navigate(string tag)
    {
        Type page = tag switch
        {
            "library" => typeof(LibraryPage),
            "devices" => typeof(DevicesPage),
            "settings" => typeof(SettingsPage),
            _ => typeof(CameraPage),
        };

        if (ContentFrame.CurrentSourcePageType == page) return;
        ContentFrame.Navigate(page, null, new EntranceNavigationTransitionInfo());
    }

    // MARK: - Status

    private void UpdateStatus()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            var device = Services.Sessions.Primary;
            if (device is null)
            {
                StatusText.Text = "No iPhone connected";
                StatusDot.Fill = (Brush)Application.Current
                    .Resources["TextFillColorTertiaryBrush"];
                return;
            }

            var battery = device.Telemetry is { } telemetry
                ? $" · {(int)(telemetry.Battery * 100)}%"
                : "";
            StatusText.Text = $"{device.Name}{battery}";
            StatusDot.Fill = (Brush)Application.Current.Resources["ICamConnectedBrush"];
        });
    }

    private async void OnPairingRequested(ConnectedDevice device)
    {
        var digits = device.PairingDigits;
        if (digits is null || digits.Length != 6) return;

        PairingDialog.XamlRoot = RootGrid.XamlRoot;
        PairingDialog.Content = new PairingContent(device.Name, digits);

        var result = await PairingDialog.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            await device.Session.ConfirmPairingAsync();
        }
        else
        {
            device.Session.RejectPairing();
        }
    }
}
