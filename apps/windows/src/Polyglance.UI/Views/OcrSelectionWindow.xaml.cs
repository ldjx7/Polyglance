using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Polyglance.Core.Models;
using Polyglance.Core.Services;

namespace Polyglance.UI.Views;

public partial class OcrSelectionWindow : Window
{
    private readonly BitmapSource _bitmap;
    private readonly OcrTextDocument _document;
    private readonly TranslationService _translationService;
    private readonly AppConfiguration _configuration;
    private readonly Rect? _sourceFrame;
    private readonly List<(LayoutTextWord Word, Rectangle Highlight)> _wordHighlights = [];
    private Point _dragStart;
    private Rect _selection = Rect.Empty;
    private bool _isSelecting;

    public OcrSelectionWindow(
        BitmapSource bitmap,
        OcrTextDocument document,
        TranslationService translationService,
        AppConfiguration configuration,
        Rect? sourceFrame = null)
    {
        InitializeComponent();
        _bitmap = bitmap;
        _document = document;
        _translationService = translationService;
        _configuration = configuration;
        _sourceFrame = sourceFrame;

        OriginalImage.Source = bitmap;
        ImageSurface.Width = bitmap.PixelWidth;
        ImageSurface.Height = bitmap.PixelHeight;
        WordCanvas.Width = bitmap.PixelWidth;
        WordCanvas.Height = bitmap.PixelHeight;
        BuildWordHighlights();
    }

    private void BuildWordHighlights()
    {
        foreach (var line in _document.Lines)
        {
            if (line.Words.Count == 0)
            {
                AddHighlight(new LayoutTextWord
                {
                    Text = line.Text,
                    X = line.X,
                    Y = line.Y,
                    Width = line.Width,
                    Height = line.Height
                });
                continue;
            }

            foreach (var word in line.Words)
            {
                AddHighlight(word);
            }
        }
    }

    private void AddHighlight(LayoutTextWord word)
    {
        var rectangle = new Rectangle
        {
            Width = Math.Max(1, word.Width),
            Height = Math.Max(1, word.Height),
            Fill = Brushes.Transparent,
            Stroke = new SolidColorBrush(Color.FromArgb(46, 10, 132, 255)),
            StrokeThickness = 0.75
        };
        Canvas.SetLeft(rectangle, word.X);
        Canvas.SetTop(rectangle, word.Y);
        WordCanvas.Children.Add(rectangle);
        _wordHighlights.Add((word, rectangle));
    }

    private void OnSurfaceMouseDown(object sender, MouseButtonEventArgs e)
    {
        _dragStart = e.GetPosition(ImageSurface);
        _selection = new Rect(_dragStart, new Size(0, 0));
        _isSelecting = true;
        ImageSurface.CaptureMouse();
        UpdateSelectionDisplay();
        e.Handled = true;
    }

    private void OnSurfaceMouseMove(object sender, MouseEventArgs e)
    {
        if (!_isSelecting || e.LeftButton != MouseButtonState.Pressed)
        {
            return;
        }

        Point current = e.GetPosition(ImageSurface);
        _selection = new Rect(
            new Point(Math.Min(_dragStart.X, current.X), Math.Min(_dragStart.Y, current.Y)),
            new Point(Math.Max(_dragStart.X, current.X), Math.Max(_dragStart.Y, current.Y)));
        UpdateSelectionDisplay();
    }

    private void OnSurfaceMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (!_isSelecting)
        {
            return;
        }

        _isSelecting = false;
        ImageSurface.ReleaseMouseCapture();
        if (_selection.Width < 3 || _selection.Height < 3)
        {
            Point point = e.GetPosition(ImageSurface);
            var hit = _wordHighlights.Find(item => WordRect(item.Word).Contains(point));
            _selection = hit.Word == null ? Rect.Empty : WordRect(hit.Word);
        }
        UpdateSelectionDisplay();
    }

    private void UpdateSelectionDisplay()
    {
        bool hasSelection = !_selection.IsEmpty && _selection.Width > 0 && _selection.Height > 0;
        SelectionBorder.Visibility = hasSelection ? Visibility.Visible : Visibility.Collapsed;
        if (hasSelection)
        {
            Canvas.SetLeft(SelectionBorder, _selection.X);
            Canvas.SetTop(SelectionBorder, _selection.Y);
            SelectionBorder.Width = _selection.Width;
            SelectionBorder.Height = _selection.Height;
        }

        foreach (var (word, highlight) in _wordHighlights)
        {
            bool selected = hasSelection && _selection.IntersectsWith(WordRect(word));
            highlight.Fill = selected
                ? new SolidColorBrush(Color.FromArgb(76, 10, 132, 255))
                : Brushes.Transparent;
            highlight.Stroke = new SolidColorBrush(Color.FromArgb(
                selected ? (byte)180 : (byte)46,
                10,
                132,
                255));
        }

        string selectedText = SelectedText();
        TxtStatus.Text = hasSelection
            ? $"已选择 {selectedText.Length} 个字符"
            : "拖动框选要复制或翻译的文字；未选择时操作全部文字";
    }

    private string SelectedText() => _document.SelectedText(new NativeRect(
        _selection.X,
        _selection.Y,
        _selection.Width,
        _selection.Height));

    private static Rect WordRect(LayoutTextWord word) =>
        new(word.X, word.Y, word.Width, word.Height);

    private void OnCopyAllClick(object sender, RoutedEventArgs e) => CopyText(_document.FullText);

    private void OnCopySelectionClick(object sender, RoutedEventArgs e) => CopyText(SelectedText());

    private static void CopyText(string text)
    {
        if (!string.IsNullOrWhiteSpace(text))
        {
            Clipboard.SetText(text);
        }
    }

    private async void OnTranslateClick(object sender, RoutedEventArgs e)
    {
        string sourceText = SelectedText();
        if (string.IsNullOrWhiteSpace(sourceText))
        {
            MessageBox.Show("当前区域没有识别到可翻译的文字。", "OCR", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        BtnTranslate.IsEnabled = false;
        TxtStatus.Text = "正在翻译…";
        try
        {
            var result = await _translationService.TranslateAsync(
                sourceText,
                _configuration.TargetLanguage,
                _configuration.SourceLanguage,
                _configuration);
            var resultWindow = new ScreenTranslationWindow(
                sourceText,
                result.Text,
                _bitmap,
                _translationService,
                _configuration);
            if (_sourceFrame is Rect frame)
            {
                resultWindow.Left = frame.X;
                resultWindow.Top = frame.Y;
            }
            resultWindow.Show();
            resultWindow.Activate();
            TxtStatus.Text = "翻译完成，可继续选择其他文字";
        }
        catch (Exception error)
        {
            MessageBox.Show($"OCR 翻译失败：{error.Message}", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Warning);
            TxtStatus.Text = "翻译失败，请检查翻译服务设置后重试";
        }
        finally
        {
            BtnTranslate.IsEnabled = true;
        }
    }

    private void OnCloseClick(object sender, RoutedEventArgs e) => Close();

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Close();
        }
        else if (e.Key == Key.C && Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
        {
            CopyText(SelectedText());
        }
    }
}
