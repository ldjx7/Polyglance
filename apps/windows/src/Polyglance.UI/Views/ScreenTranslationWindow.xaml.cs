using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;

namespace Polyglance.UI.Views;

public partial class ScreenTranslationWindow : Window
{
    private readonly BitmapSource _originalBitmap;
    private readonly string _translatedText;

    public ScreenTranslationWindow(string sourceText, string targetText, BitmapSource originalBitmap)
    {
        InitializeComponent();
        _originalBitmap = originalBitmap;
        _translatedText = targetText;

        TxtSource.Text = sourceText;
        TxtTarget.Text = targetText;
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            DragMove();
        }
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        Close();
    }

    private void OnPinOriginalClick(object sender, RoutedEventArgs e)
    {
        var pinWin = new PinWindow(_originalBitmap);
        pinWin.Left = Left;
        pinWin.Top = Top;
        pinWin.Show();
        Close();
    }

    private void OnCopyTranslationClick(object sender, RoutedEventArgs e)
    {
        Clipboard.SetText(_translatedText);
        Close();
    }
}
