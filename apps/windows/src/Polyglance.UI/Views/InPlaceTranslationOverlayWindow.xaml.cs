using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.Platform.Capture;
using Polyglance.Platform.Ocr;

namespace Polyglance.UI.Views;

public partial class InPlaceTranslationOverlayWindow : Window
{
    private readonly BitmapSource _croppedBitmap;
    private readonly List<LayoutTextLine> _ocrLines;
    private readonly TranslationService _translationService;
    private readonly AppConfiguration _config;
    private readonly Rect _screenBounds;
    private readonly List<string> _translatedParagraphs = new();

    public InPlaceTranslationOverlayWindow(
        BitmapSource croppedBitmap,
        Rect screenBounds,
        List<LayoutTextLine> ocrLines,
        TranslationService translationService,
        AppConfiguration config)
    {
        InitializeComponent();

        _croppedBitmap = croppedBitmap;
        _screenBounds = screenBounds;
        _ocrLines = ocrLines;
        _translationService = translationService;
        _config = config;

        Left = screenBounds.X;
        Top = screenBounds.Y;
        Width = screenBounds.Width;
        Height = screenBounds.Height;

        BackgroundImage.Source = croppedBitmap;

        PositionToolbar();
        Loaded += async (s, e) => await PerformInPlaceTranslationAsync();
    }

    private void PositionToolbar()
    {
        double tbWidth = 380;
        double left = Math.Max(10, (Width - tbWidth) / 2);
        double top = Math.Max(10, Height - 58);

        Canvas.SetLeft(ToolbarBorder, left);
        Canvas.SetTop(ToolbarBorder, top);
    }

    private async Task PerformInPlaceTranslationAsync()
    {
        OverlayCanvas.Children.Clear();
        _translatedParagraphs.Clear();

        if (_ocrLines.Count == 0) return;

        // Use the shared Rust layout engine, matching the macOS paragraph
        // grouping instead of maintaining a Windows-only heuristic.
        var paragraphs = TranslationService.AggregateParagraphs(_ocrLines);
        if (paragraphs.Count == 0)
        {
            TxtStatus.Text = "未识别到可翻译内容";
            MessageBox.Show(
                "当前截图中没有识别到可翻译的文字。",
                "截图翻译",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }

        for (int index = 0; index < paragraphs.Count; index++)
        {
            var p = paragraphs[index];
            string srcText = p.Text.Trim();
            if (string.IsNullOrWhiteSpace(srcText)) continue;

            string targetText;
            try
            {
                TxtStatus.Text = $"正在翻译 {index + 1}/{paragraphs.Count}…";
                var res = await _translationService.TranslateAsync(
                    srcText,
                    _config.TargetLanguage,
                    _config.SourceLanguage,
                    _config);
                targetText = res.Text;
            }
            catch (Exception error)
            {
                TxtStatus.Text = "翻译失败";
                MessageBox.Show(
                    $"截图翻译失败：{error.Message}",
                    "Polyglance",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            _translatedParagraphs.Add(targetText);

            // Create in-place overlay card
            double pX = p.X;
            double pY = p.Y;
            double pW = p.Width;
            double pH = p.Height;

            var bgBrush = new SolidColorBrush(Color.FromArgb(240, 255, 255, 255));
            var fgBrush = new SolidColorBrush(Color.FromArgb(255, 20, 20, 20));

            var card = new Border
            {
                Background = bgBrush,
                BorderBrush = new SolidColorBrush(Color.FromArgb(50, 10, 132, 255)),
                BorderThickness = new Thickness(0.8),
                CornerRadius = new CornerRadius(3),
                Padding = new Thickness(2, 1, 2, 1),
                Width = Math.Max(pW, 40),
                MinHeight = Math.Max(pH, 16),
                Cursor = Cursors.Hand,
                ToolTip = "点击复制该段译文"
            };

            var tb = new TextBlock
            {
                Text = targetText,
                Foreground = fgBrush,
                FontSize = Math.Max(11, Math.Min(16, pH / Math.Max(1u, p.LineCount) * 0.75)),
                TextWrapping = TextWrapping.Wrap,
                FontWeight = FontWeights.Medium,
                FontFamily = new System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei UI")
            };

            card.Child = tb;

            string capturedText = targetText;
            card.MouseDown += (s, e) =>
            {
                Clipboard.SetText(capturedText);
                e.Handled = true;
            };
            card.MouseEnter += (_, _) =>
            {
                card.Background = new SolidColorBrush(Color.FromArgb(248, 224, 239, 255));
                card.BorderBrush = new SolidColorBrush(Color.FromArgb(210, 10, 132, 255));
            };
            card.MouseLeave += (_, _) =>
            {
                card.Background = bgBrush;
                card.BorderBrush = new SolidColorBrush(Color.FromArgb(50, 10, 132, 255));
            };

            Canvas.SetLeft(card, pX);
            Canvas.SetTop(card, pY);
            OverlayCanvas.Children.Add(card);
        }
        TxtStatus.Text = "按住 Space 预览原文";
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Space)
        {
            OverlayCanvas.Visibility = Visibility.Collapsed;
        }
        else if (e.Key == Key.Escape)
        {
            Close();
        }
    }

    private void OnKeyUp(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Space)
        {
            OverlayCanvas.Visibility = Visibility.Visible;
        }
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.RightButton == MouseButtonState.Pressed)
        {
            Close();
        }
    }

    private void OnCopyAllClick(object sender, RoutedEventArgs e)
    {
        if (_translatedParagraphs.Count > 0)
        {
            Clipboard.SetText(string.Join("\n\n", _translatedParagraphs));
        }
    }

    private void OnPinClick(object sender, RoutedEventArgs e)
    {
        var rendered = RenderMergedBitmap();
        if (rendered != null)
        {
            var pin = new PinWindow(rendered, _translationService, _config);
            pin.Left = Left;
            pin.Top = Top;
            pin.Show();
        }
        Close();
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        var rendered = RenderMergedBitmap();
        if (rendered != null)
        {
            var dlg = new SaveFileDialog
            {
                Filter = "PNG Image (*.png)|*.png|JPEG Image (*.jpg)|*.jpg",
                FileName = $"TranslatedScreen_{DateTime.Now:yyyyMMdd_HHmmss}.png"
            };
            if (dlg.ShowDialog() == true)
            {
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(rendered));
                using var stream = File.Create(dlg.FileName);
                encoder.Save(stream);
            }
        }
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        Close();
    }

    private BitmapSource? RenderMergedBitmap()
    {
        int w = (int)Width;
        int h = (int)Height;
        if (w <= 0 || h <= 0) return _croppedBitmap;

        var rtb = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            dc.DrawImage(_croppedBitmap, new Rect(0, 0, w, h));
            var brush = new VisualBrush(OverlayCanvas);
            dc.DrawRectangle(brush, null, new Rect(0, 0, w, h));
        }
        rtb.Render(dv);
        rtb.Freeze();
        return rtb;
    }
}
