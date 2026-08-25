using System;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.Platform.Ocr;
using Polyglance.Platform.Pin;

namespace Polyglance.UI.Views;

public partial class PinWindow : Window
{
    private readonly BitmapSource _bitmap;
    private readonly TranslationService? _translationService;
    private readonly AppConfiguration? _configuration;
    private double _scale = 1.0;

    public PinWindow(
        BitmapSource bitmap,
        TranslationService? translationService = null,
        AppConfiguration? configuration = null)
    {
        InitializeComponent();
        _bitmap = bitmap;
        _translationService = translationService;
        _configuration = configuration;
        PinImage.Source = bitmap;
        Rect workArea = SystemParameters.WorkArea;
        double maximumWidth = Math.Max(240, workArea.Width * 0.72);
        double maximumHeight = Math.Max(180, workArea.Height * 0.72);
        _scale = Math.Min(1, Math.Min(
            maximumWidth / Math.Max(1, bitmap.PixelWidth),
            maximumHeight / Math.Max(1, bitmap.PixelHeight)));
        PinImage.Width = bitmap.PixelWidth * _scale;
        PinImage.Height = bitmap.PixelHeight * _scale;

        PinHistoryManager.SavePinToHistory(bitmap);

        OcrMenuItem.IsEnabled = translationService != null && configuration != null;
        TranslateMenuItem.IsEnabled = translationService != null && configuration != null;
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            DragMove();
        }
    }

    private void OnMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if ((Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
        {
            // Ctrl+Wheel: Adjust Opacity
            if (e.Delta > 0)
                Opacity = Math.Min(1.0, Opacity + 0.1);
            else
                Opacity = Math.Max(0.2, Opacity - 0.1);
        }
        else
        {
            // Wheel: Zoom Scale
            if (e.Delta > 0)
                _scale = Math.Min(3.5, _scale * 1.1);
            else
                _scale = Math.Max(0.15, _scale / 1.1);

            PinImage.Width = _bitmap.PixelWidth * _scale;
            PinImage.Height = _bitmap.PixelHeight * _scale;
        }
    }

    private void OnMouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            Close();
        }
    }

    private void OnCopyClick(object sender, RoutedEventArgs e)
    {
        Clipboard.SetImage(_bitmap);
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        var dlg = new SaveFileDialog
        {
            Filter = "PNG Image (*.png)|*.png|JPEG Image (*.jpg)|*.jpg",
            FileName = $"Pin_{DateTime.Now:yyyyMMdd_HHmmss}.png"
        };
        if (dlg.ShowDialog() == true)
        {
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(_bitmap));
            using var stream = File.Create(dlg.FileName);
            encoder.Save(stream);
        }
    }

    private void OnSetOpacity100(object sender, RoutedEventArgs e) => Opacity = 1.0;
    private void OnSetOpacity80(object sender, RoutedEventArgs e) => Opacity = 0.8;
    private void OnSetOpacity60(object sender, RoutedEventArgs e) => Opacity = 0.6;
    private void OnSetOpacity40(object sender, RoutedEventArgs e) => Opacity = 0.4;

    private void OnToggleTopmostClick(object sender, RoutedEventArgs e)
    {
        Topmost = !Topmost;
    }

    private void OnToggleShadowClick(object sender, RoutedEventArgs e)
    {
        Shadow.Opacity = Shadow.Opacity > 0 ? 0.0 : 0.3;
    }

    private async void OnOcrClick(object sender, RoutedEventArgs e)
    {
        if (_translationService == null || _configuration == null)
        {
            return;
        }

        try
        {
            var document = await WindowsMediaOcr.RecognizeDocumentAsync(_bitmap);
            if (string.IsNullOrWhiteSpace(document.FullText))
            {
                throw new WindowsOcrException("当前贴图中没有识别到文字。");
            }
            var ocrWindow = new OcrSelectionWindow(
                _bitmap,
                document,
                _translationService,
                _configuration,
                new Rect(Left, Top, ActualWidth, ActualHeight));
            ocrWindow.Show();
            ocrWindow.Activate();
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "OCR 识别失败", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async void OnTranslateClick(object sender, RoutedEventArgs e)
    {
        if (_translationService == null || _configuration == null)
        {
            return;
        }

        try
        {
            var document = await WindowsMediaOcr.RecognizeDocumentAsync(_bitmap);
            if (string.IsNullOrWhiteSpace(document.FullText))
            {
                throw new WindowsOcrException("当前贴图中没有识别到文字。");
            }
            var result = await _translationService.TranslateAsync(
                document.FullText,
                _configuration.TargetLanguage,
                _configuration.SourceLanguage,
                _configuration);
            var resultWindow = new ScreenTranslationWindow(
                document.FullText,
                result.Text,
                _bitmap,
                _translationService,
                _configuration)
            {
                Left = Left,
                Top = Top
            };
            resultWindow.Show();
            resultWindow.Activate();
        }
        catch (Exception error)
        {
            MessageBox.Show($"截图翻译失败：{error.Message}", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        Close();
    }
}
