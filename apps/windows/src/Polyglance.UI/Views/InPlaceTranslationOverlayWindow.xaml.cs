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

        // Group nearby lines into paragraphs
        var paragraphs = GroupLinesIntoParagraphs(_ocrLines);

        foreach (var p in paragraphs)
        {
            string srcText = string.Join(" ", p.Lines.ConvertAll(l => l.Text)).Trim();
            if (string.IsNullOrWhiteSpace(srcText)) continue;

            string targetText = srcText;
            try
            {
                var res = await _translationService.TranslateAsync(srcText, _config.TargetLanguage, null, _config);
                targetText = res.Text;
            }
            catch { }

            _translatedParagraphs.Add(targetText);

            // Create in-place overlay card
            double pX = p.Bounds.X;
            double pY = p.Bounds.Y;
            double pW = p.Bounds.Width;
            double pH = p.Bounds.Height;

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
                FontSize = Math.Max(11, Math.Min(16, pH / Math.Max(1, p.Lines.Count) * 0.75)),
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

            Canvas.SetLeft(card, pX);
            Canvas.SetTop(card, pY);
            OverlayCanvas.Children.Add(card);
        }
    }

    private sealed class ParagraphGroup
    {
        public Rect Bounds { get; set; }
        public List<LayoutTextLine> Lines { get; } = new();
    }

    private List<ParagraphGroup> GroupLinesIntoParagraphs(List<LayoutTextLine> lines)
    {
        var groups = new List<ParagraphGroup>();
        foreach (var line in lines)
        {
            var r = new Rect(line.X, line.Y, line.Width, line.Height);
            bool added = false;
            foreach (var g in groups)
            {
                if (Math.Abs(g.Bounds.Bottom - r.Top) < 18 && Math.Abs(g.Bounds.Left - r.Left) < 60)
                {
                    g.Lines.Add(line);
                    g.Bounds = Rect.Union(g.Bounds, r);
                    added = true;
                    break;
                }
            }
            if (!added)
            {
                var g = new ParagraphGroup { Bounds = r };
                g.Lines.Add(line);
                groups.Add(g);
            }
        }
        return groups;
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
            var pin = new PinWindow(rendered);
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
