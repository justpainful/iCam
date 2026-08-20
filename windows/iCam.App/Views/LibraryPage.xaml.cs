using Microsoft.UI.Xaml.Controls;

namespace ICam.App.Views;

/// <summary>
/// Media captured on this computer.
///
/// Deliberately narrow: iCam is not trying to replace the Photos app, and a
/// library that indexed everything would be a second, worse file browser.
/// </summary>
public sealed partial class LibraryPage : Page
{
    public LibraryPage() => InitializeComponent();
}
