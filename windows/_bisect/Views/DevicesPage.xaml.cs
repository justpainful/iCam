using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using ICam.App.Services;
using ICam.Core.Transport;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace ICam.App.Views;

public sealed partial class DevicesPage : Page
{
    private AppServices Services => App.Instance.Services;

    public DevicesPage() => InitializeComponent();

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        Services.Sessions.DeviceAdded += OnDevicesChanged;
        Services.Sessions.DeviceRemoved += OnDevicesChanged;
        Refresh();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        Services.Sessions.DeviceAdded -= OnDevicesChanged;
        Services.Sessions.DeviceRemoved -= OnDevicesChanged;
    }

    private void OnDevicesChanged(ConnectedDevice device) =>
        DispatcherQueue.TryEnqueue(Refresh);

    private void Refresh()
    {
        ComputerName.Text = Services.ComputerName;
        ListenPort.Text = Services.Listener.IsListening
            ? Services.Listener.Port.ToString()
            : "Not listening";

        var advertiser = Services.Listener;
        AdvertiseState.Text = advertiser.IsListening ? "Yes" : "No";
        DiscoveryWarning.IsOpen = !advertiser.IsListening;

        AddressText.Text = LocalAddress() is { } address
            ? $"{address}:{Services.Listener.Port}"
            : "Unavailable";

        BuildConnected();
        BuildPaired();
    }

    private void BuildConnected()
    {
        ConnectedList.Children.Clear();
        var devices = Services.Sessions.Devices;
        NoneConnected.Visibility = devices.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        foreach (var device in devices)
        {
            var summary = device.Telemetry is { } telemetry
                ? $"{(int)(telemetry.Battery * 100)}% · {telemetry.Power}"
                : "Connected";
            ConnectedList.Children.Add(BuildRow(device.Name, summary, null, null));
        }
    }

    private void BuildPaired()
    {
        PairedList.Children.Clear();
        var peers = Services.Trust.Peers;
        NonePaired.Visibility = peers.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        foreach (var peer in peers)
        {
            PairedList.Children.Add(BuildRow(
                peer.Name,
                $"Paired {peer.PairedAt.LocalDateTime:d MMM yyyy}",
                "Forget",
                () =>
                {
                    Services.Trust.Forget(peer.Id);
                    Refresh();
                }));
        }
    }

    private static Grid BuildRow(string title, string subtitle, string? actionText,
                                 Action? action)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var text = new StackPanel();
        text.Children.Add(new TextBlock { Text = title });
        text.Children.Add(new TextBlock
        {
            Text = subtitle,
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current
                .Resources["TextFillColorSecondaryBrush"],
        });
        Grid.SetColumn(text, 0);
        grid.Children.Add(text);

        if (actionText is not null && action is not null)
        {
            var button = new Button { Content = actionText, VerticalAlignment = VerticalAlignment.Center };
            button.Click += (_, _) => action();
            Grid.SetColumn(button, 1);
            grid.Children.Add(button);
        }
        return grid;
    }

    /// <summary>
    /// The address a phone on the same network would use. Picks a real
    /// interface rather than a loopback or a virtual adapter, which is what a
    /// naive first-address lookup returns on a machine with Hyper-V or a VPN.
    /// </summary>
    private static IPAddress? LocalAddress()
    {
        var candidates = NetworkInterface.GetAllNetworkInterfaces()
            .Where(nic => nic.OperationalStatus == OperationalStatus.Up
                          && nic.NetworkInterfaceType is NetworkInterfaceType.Ethernet
                              or NetworkInterfaceType.Wireless80211)
            .SelectMany(nic => nic.GetIPProperties().UnicastAddresses)
            .Select(unicast => unicast.Address)
            .Where(address => address.AddressFamily == AddressFamily.InterNetwork
                              && !IPAddress.IsLoopback(address))
            .ToList();

        return candidates.FirstOrDefault();
    }
}
