using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using Polyglance.Core.Models;
using Polyglance.Core.Services;

namespace Polyglance.UI.Views;

public partial class ScreenTranslationWindow : Window
{
    private readonly BitmapSource _originalBitmap;
    private readonly string _translatedText;
    private readonly TranslationService? _translationService;
    private readonly AppConfiguration? _configuration;

    public ScreenTranslationWindow(
        string sourceText,
        string targetText,
        BitmapSource originalBitmap,
        TranslationService? translationService = null,
        AppConfiguration? configuration = null)
    {
        InitializeComponent();
        _originalBitmap = originalBitmap;
        _translatedText = targetText;
        _translationService = translationService;
        _configuration = configuration;

        OriginalImage.Source = originalBitmap;
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
        var pinWin = new PinWindow(_originalBitmap, _translationService, _configuration);
        pinWin.Left = Left;
        pinWin.Top = Top;
        pinWin.Show();
        Close();
    }

    private void OnShowOriginalClick(object sender, RoutedEventArgs e) => ShowMode(OriginalPanel);

    private void OnShowSourceClick(object sender, RoutedEventArgs e) => ShowMode(SourcePanel);

    private void OnShowTranslationClick(object sender, RoutedEventArgs e) => ShowMode(TargetPanel);

    private void ShowMode(FrameworkElement visiblePanel)
    {
        OriginalPanel.Visibility = visiblePanel == OriginalPanel ? Visibility.Visible : Visibility.Collapsed;
        SourcePanel.Visibility = visiblePanel == SourcePanel ? Visibility.Visible : Visibility.Collapsed;
        TargetPanel.Visibility = visiblePanel == TargetPanel ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnCopyTranslationClick(object sender, RoutedEventArgs e)
    {
        Clipboard.SetText(_translatedText);
        Close();
    }
}
