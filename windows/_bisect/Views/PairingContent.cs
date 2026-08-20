using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace ICam.App.Views;

/// <summary>
/// The six digits, on both devices, before anything is trusted.
///
/// Matching digits are what prove nobody is in the middle: they are derived
/// from the handshake transcript, so an attacker who relayed the connection
/// would produce different ones.
/// </summary>
public sealed class PairingContent : StackPanel
{
    public PairingContent(string deviceName, string digits)
    {
        Spacing = 14;

        Children.Add(new TextBlock
        {
            Text = deviceName,
            Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
            HorizontalAlignment = HorizontalAlignment.Center,
        });

        Children.Add(new TextBlock
        {
            Text = $"{digits[..3]} {digits[3..]}",
            FontSize = 40,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas, Cascadia Mono"),
            CharacterSpacing = 120,
            HorizontalAlignment = HorizontalAlignment.Center,
        });

        Children.Add(new TextBlock
        {
            Text = "Check that your iPhone shows the same six digits, then confirm on both.",
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            MaxWidth = 320,
            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current
                .Resources["TextFillColorSecondaryBrush"],
        });
    }
}
