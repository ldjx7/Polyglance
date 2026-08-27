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
    private readonly TranslationService? _translationService;
    private readonly AppConfiguration? _configuration;
    private readonly Rect? _sourceFrame;
    private readonly List<(LayoutTextWord Word, Rectangle Highlight)> _wordHighlights = [];
    private readonly double _viewScaleX;
    private readonly double _viewScaleY;
    private Point _dragStart;
    private Point _windowDragStart;
    private Rect _selection = Rect.Empty;
    private bool _isSelecting;
    private bool _isMovingWindow;
    private bool _selectionEnabled = true;

    internal bool IsSelectionEnabled => _selectionEnabled;
    internal bool AreContextualActionsVisible => ContextualActions.Visibility == Visibility.Visible;
    internal void ExitSelectionOrClose()
    {
        if (_selectionEnabled)
            SetSelectionEnabled(false);
        else
            Close();
    }

    public OcrSelectionWindow(
        BitmapSource bitmap,
        OcrTextDocument document,
        TranslationService? translationService,
        AppConfiguration? configuration,
        Rect? sourceFrame = null)
    {
        InitializeComponent();
        _bitmap = bitmap;
        _document = document;
        _translationService = translationService;
        _configuration = configuration;
        _sourceFrame = sourceFrame;

        OriginalImage.Source = bitmap;
        Rect workArea = SystemParameters.WorkArea;
        double preferredWidth = sourceFrame.HasValue && sourceFrame.Value.Width > 0
            ? sourceFrame.Value.Width
            : bitmap.PixelWidth;
        double preferredHeight = sourceFrame.HasValue && sourceFrame.Value.Height > 0
            ? sourceFrame.Value.Height
            : bitmap.PixelHeight;
        double fit = Math.Min(1, Math.Min(
            workArea.Width * 0.9 / Math.Max(1, preferredWidth),
            workArea.Height * 0.9 / Math.Max(1, preferredHeight)));
        double displayWidth = Math.Max(240, preferredWidth * fit);
        double displayHeight = Math.Max(140, preferredHeight * fit);
        _viewScaleX = displayWidth / bitmap.PixelWidth;
        _viewScaleY = displayHeight / bitmap.PixelHeight;
        ImageSurface.Width = displayWidth;
        ImageSurface.Height = displayHeight;
        WordCanvas.Width = displayWidth;
        WordCanvas.Height = displayHeight;
        BtnTranslate.IsEnabled = translationService is not null && configuration is not null;
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
            Width = Math.Max(1, word.Width * _viewScaleX),
            Height = Math.Max(1, word.Height * _viewScaleY),
            Fill = Brushes.Transparent,
            Stroke = Brushes.Transparent,
            StrokeThickness = 0.75
        };
        Canvas.SetLeft(rectangle, word.X * _viewScaleX);
        Canvas.SetTop(rectangle, word.Y * _viewScaleY);
        WordCanvas.Children.Add(rectangle);
        _wordHighlights.Add((word, rectangle));
    }

    private void OnSurfaceMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount >= 2 && !_selectionEnabled)
        {
            Close();
            e.Handled = true;
            return;
        }

        if (!_selectionEnabled || Keyboard.Modifiers.HasFlag(ModifierKeys.Alt))
        {
            _isMovingWindow = true;
            _windowDragStart = e.GetPosition(this);
            CaptureMouse();
            e.Handled = true;
            return;
        }

        _dragStart = e.GetPosition(ImageSurface);
        _selection = new Rect(_dragStart, new Size(0, 0));
        _isSelecting = true;
        ImageSurface.CaptureMouse();
        UpdateSelectionDisplay();
        e.Handled = true;
    }

    private void OnSurfaceMouseMove(object sender, MouseEventArgs e)
    {
        if (_isMovingWindow && e.LeftButton == MouseButtonState.Pressed)
        {
            Point windowPoint = e.GetPosition(this);
            Left += windowPoint.X - _windowDragStart.X;
            Top += windowPoint.Y - _windowDragStart.Y;
            e.Handled = true;
            return;
        }

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
        if (_isMovingWindow)
        {
            _isMovingWindow = false;
            ReleaseMouseCapture();
            e.Handled = true;
            return;
        }

        if (!_isSelecting)
        {
            return;
        }

        _isSelecting = false;
        ImageSurface.ReleaseMouseCapture();
        if (_selection.Width < 3 || _selection.Height < 3)
        {
            Point point = e.GetPosition(ImageSurface);
            var hit = _wordHighlights.Find(item => ViewWordRect(item.Word).Contains(point));
            _selection = hit.Word == null ? Rect.Empty : ViewWordRect(hit.Word);
        }
        UpdateSelectionDisplay();
    }

    private void UpdateSelectionDisplay()
    {
        bool hasSelection = !_selection.IsEmpty && _selection.Width > 0 && _selection.Height > 0;
        SelectionBorder.Visibility = hasSelection ? Visibility.Visible : Visibility.Collapsed;
        ContextualActions.Visibility = hasSelection ? Visibility.Visible : Visibility.Collapsed;
        if (hasSelection)
        {
            Canvas.SetLeft(SelectionBorder, _selection.X);
            Canvas.SetTop(SelectionBorder, _selection.Y);
            SelectionBorder.Width = _selection.Width;
            SelectionBorder.Height = _selection.Height;
        }

        foreach (var (word, highlight) in _wordHighlights)
        {
            bool selected = hasSelection && _selection.IntersectsWith(ViewWordRect(word));
            highlight.Fill = selected
                ? new SolidColorBrush(Color.FromArgb(76, 10, 132, 255))
                : Brushes.Transparent;
            highlight.Stroke = selected
                ? new SolidColorBrush(Color.FromArgb(180, 10, 132, 255))
                : Brushes.Transparent;
        }
    }

    private string SelectedText()
    {
        if (_selection.IsEmpty || _selection.Width <= 0 || _selection.Height <= 0)
            return string.Empty;
        return _document.SelectedText(new NativeRect(
            _selection.X / _viewScaleX,
            _selection.Y / _viewScaleY,
            _selection.Width / _viewScaleX,
            _selection.Height / _viewScaleY));
    }

    private Rect ViewWordRect(LayoutTextWord word) => new(
        word.X * _viewScaleX,
        word.Y * _viewScaleY,
        word.Width * _viewScaleX,
        word.Height * _viewScaleY);

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
        if (_translationService is null || _configuration is null)
            return;
        string sourceText = SelectedText();
        if (string.IsNullOrWhiteSpace(sourceText))
        {
            MessageBox.Show("当前区域没有识别到可翻译的文字。", "OCR", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        BtnTranslate.IsEnabled = false;
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
        }
        catch (Exception error)
        {
            MessageBox.Show($"OCR 翻译失败：{error.Message}", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            BtnTranslate.IsEnabled = true;
        }
    }

    private void OnCloseClick(object sender, RoutedEventArgs e) => Close();

    private void OnToggleSelectionModeClick(object sender, RoutedEventArgs e)
    {
        SetSelectionEnabled(!_selectionEnabled);
    }

    private void SetSelectionEnabled(bool enabled)
    {
        _selectionEnabled = enabled;
        SelectionModeMenuItem.Header = enabled ? "退出文字选择" : "选择文字";
        if (!enabled)
        {
            _selection = Rect.Empty;
            UpdateSelectionDisplay();
        }
        Cursor = enabled ? Cursors.IBeam : Cursors.Arrow;
    }

    private void OnAnnotationClick(object sender, RoutedEventArgs e)
    {
        if (Owner is PinWindow ownerPin)
        {
            Close();
            ownerPin.ToggleAnnotationEditing();
            return;
        }

        var pin = new PinWindow(_bitmap, _translationService, _configuration)
        {
            Left = Left,
            Top = Top
        };
        pin.Show();
        pin.ToggleAnnotationEditing();
        Close();
    }

    protected override void OnClosed(EventArgs e)
    {
        // OCR selection temporarily replaces its source pin at the same screen
        // location; returning restores that pin instead of leaving a second,
        // unrelated document window behind.
        if (Owner is Window owner)
        {
            owner.Show();
            owner.Activate();
        }
        base.OnClosed(e);
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            ExitSelectionOrClose();
        }
        else if (e.Key == Key.C && Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
        {
            CopyText(SelectedText());
        }
        else if (e.Key == Key.C && Keyboard.Modifiers == ModifierKeys.Shift)
        {
            CopyText(_document.FullText);
        }
    }
}
