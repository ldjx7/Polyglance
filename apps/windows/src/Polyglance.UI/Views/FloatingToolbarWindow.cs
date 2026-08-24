using System.Windows;
using System.Windows.Media;
using System.Windows.Shell;

namespace Polyglance.UI.Views;

/// <summary>
/// Hosts controls that must remain crisp outside a per-pixel transparent capture overlay.
/// </summary>
public sealed class FloatingToolbarWindow : Window
{
    public FloatingToolbarWindow(FrameworkElement toolbar)
    {
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        ShowInTaskbar = false;
        Topmost = true;
        AllowsTransparency = false;
        Background = new SolidColorBrush(Color.FromRgb(0xF8, 0xFA, 0xFC));
        UseLayoutRounding = true;
        SnapsToDevicePixels = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        TextOptions.SetTextRenderingMode(this, TextRenderingMode.ClearType);
        TextOptions.SetTextHintingMode(this, TextHintingMode.Fixed);
        Content = toolbar;

        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = 0,
            CornerRadius = new CornerRadius(14),
            GlassFrameThickness = new Thickness(0),
            ResizeBorderThickness = new Thickness(0),
            UseAeroCaptionButtons = false,
        });
    }
}
