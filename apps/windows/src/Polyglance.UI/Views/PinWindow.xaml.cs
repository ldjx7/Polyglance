using System;
using System.IO;
using System.Media;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Microsoft.Win32;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.Platform.Ocr;
using Polyglance.Platform.Pin;
using Polyglance.UI.Controls;

namespace Polyglance.UI.Views;

public partial class PinWindow : Window
{
    // Eight DIPs of transparent shadow breathing room plus the one-DIP border
    // that participates in WPF layout before the image content begins.
    internal const double ContentInset = 9;
    private readonly BitmapSource _bitmap;
    private readonly TranslationService? _translationService;
    private readonly AppConfiguration? _configuration;
    private readonly Action<string> _colorClipboardWriter;
    private readonly MagnifierControl _colorMagnifier = new();
    private readonly Window _colorMagnifierWindow;
    private double _scale = 1.0;
    private readonly List<UIElement> _annotationHistory = new();
    private readonly List<UIElement> _annotationRedoStack = new();
    private Shape? _currentDrawingShape;
    private Canvas? _currentMosaicStroke;
    private Point _lastMosaicPoint;
    private Point _drawingStart;
    private string _activeAnnotationTool = "None";
    private int _nextNumber = 1;

    internal bool IsColorPicking { get; private set; }
    internal bool IsAnnotationEditing { get; private set; }
    internal MagnifierControl ColorMagnifierControl => _colorMagnifier;
    internal ScreenshotToolbar AnnotationTools => AnnotationToolbar;
    internal string ColorPickerMenuHeader => ColorPickerMenuItem.Header?.ToString() ?? string.Empty;
    internal bool IsSelectionHighlighted { get; private set; }
    internal Thickness SelectionBorderThickness => ContainerBorder.BorderThickness;
    internal Color SelectionBorderColor => ((SolidColorBrush)ContainerBorder.BorderBrush).Color;
    internal Color SelectionShadowColor => Shadow.Color;
    internal double SelectionShadowOpacity => Shadow.Opacity;

    public PinWindow(
        BitmapSource bitmap,
        TranslationService? translationService = null,
        AppConfiguration? configuration = null,
        Size? capturedDisplaySize = null)
        : this(bitmap, translationService, configuration, Clipboard.SetText, capturedDisplaySize)
    {
    }

    internal PinWindow(
        BitmapSource bitmap,
        TranslationService? translationService,
        AppConfiguration? configuration,
        Action<string> colorClipboardWriter,
        Size? capturedDisplaySize = null,
        bool saveToHistory = true)
    {
        InitializeComponent();
        _bitmap = bitmap;
        _translationService = translationService;
        _configuration = configuration;
        _colorClipboardWriter = colorClipboardWriter;
        _colorMagnifierWindow = new Window
        {
            Content = _colorMagnifier,
            Width = _colorMagnifier.Width,
            Height = _colorMagnifier.Height,
            WindowStyle = WindowStyle.None,
            AllowsTransparency = true,
            Background = Brushes.Transparent,
            ShowInTaskbar = false,
            ShowActivated = false,
            Focusable = false,
            Topmost = true,
            SizeToContent = SizeToContent.WidthAndHeight
        };
        PinImage.Source = bitmap;
        Rect workArea = SystemParameters.WorkArea;
        Size initialDisplaySize = CalculateInitialDisplaySize(
            new Size(bitmap.PixelWidth, bitmap.PixelHeight),
            capturedDisplaySize,
            new Size(Math.Max(240, workArea.Width), Math.Max(180, workArea.Height)));
        _scale = initialDisplaySize.Width / Math.Max(1, bitmap.PixelWidth);
        PinImage.Width = initialDisplaySize.Width;
        PinImage.Height = initialDisplaySize.Height;

        AnnotationToolbar.ToolSelected += OnAnnotationToolSelected;
        AnnotationToolbar.ActionTriggered += OnAnnotationActionTriggered;

        if (saveToHistory)
            PinHistoryManager.SavePinToHistory(bitmap);

        OcrMenuItem.IsEnabled = true;
        TranslateMenuItem.IsEnabled = translationService != null && configuration != null;
        // The pin is created as the active replacement for the screenshot
        // selection. Apply its selected appearance before the first render so
        // there is no inactive-to-active flash after Show().
        SetSelectionHighlight(true);
    }

    private void OnActivated(object? sender, EventArgs e) => SetSelectionHighlight(true);

    private void OnDeactivated(object? sender, EventArgs e) => SetSelectionHighlight(false);

    private void SetSelectionHighlight(bool highlighted)
    {
        IsSelectionHighlighted = highlighted;
        ContainerBorder.BorderBrush = new SolidColorBrush(highlighted
            ? Color.FromArgb(0x60, 0x0A, 0x84, 0xFF)
            : Color.FromArgb(0x20, 0, 0, 0));
        ContainerBorder.BorderThickness = new Thickness(1);
        Shadow.Color = highlighted ? Color.FromRgb(0x0A, 0x84, 0xFF) : Colors.Black;
        Shadow.BlurRadius = highlighted ? 24 : 12;
        Shadow.ShadowDepth = highlighted ? 0 : 3;
        Shadow.Opacity = highlighted ? 0.50 : 0.3;
    }

    internal void SetSelectionHighlightForTesting(bool highlighted) =>
        SetSelectionHighlight(highlighted);

    internal static Point WindowOriginForContentFrame(Rect contentFrame) =>
        new(contentFrame.X - ContentInset, contentFrame.Y - ContentInset);

    /// <summary>
    /// Normal screenshots provide their size in WPF device-independent pixels.
    /// It must win over the bitmap's backing-pixel size, especially at 125%-200%
    /// display scaling. Images without capture geometry are fitted to one work
    /// area, without the former arbitrary 72% reduction.
    /// </summary>
    internal static Size CalculateInitialDisplaySize(
        Size bitmapPixelSize,
        Size? capturedDisplaySize,
        Size maximumDisplaySize)
    {
        if (capturedDisplaySize is { } captured
            && double.IsFinite(captured.Width)
            && double.IsFinite(captured.Height)
            && captured.Width > 0
            && captured.Height > 0)
        {
            return captured;
        }

        double bitmapWidth = Math.Max(1, bitmapPixelSize.Width);
        double bitmapHeight = Math.Max(1, bitmapPixelSize.Height);
        double maximumWidth = Math.Max(1, maximumDisplaySize.Width);
        double maximumHeight = Math.Max(1, maximumDisplaySize.Height);
        double scale = Math.Min(1, Math.Min(
            maximumWidth / bitmapWidth,
            maximumHeight / bitmapHeight));
        return new Size(bitmapWidth * scale, bitmapHeight * scale);
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (IsColorPicking)
        {
            UpdateColorAt(e.GetPosition(PinImage));
            e.Handled = true;
            return;
        }
        if (IsAnnotationEditing)
        {
            if (_activeAnnotationTool == "None")
                return;
            Point point = e.GetPosition(PinSurface);
            _drawingStart = point;
            StartAnnotationDrawing(point);
            e.Handled = true;
            return;
        }
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            DragMove();
        }
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (IsColorPicking)
            UpdateColorAt(e.GetPosition(PinImage));
        else if (_currentDrawingShape is not null || _currentMosaicStroke is not null)
            UpdateAnnotationDrawing(e.GetPosition(PinSurface));
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_currentDrawingShape is null && _currentMosaicStroke is null)
            return;
        _annotationHistory.Add(_currentDrawingShape is not null
            ? _currentDrawingShape
            : _currentMosaicStroke!);
        _annotationRedoStack.Clear();
        _currentDrawingShape = null;
        _currentMosaicStroke = null;
        UpdateAnnotationUndoRedoState();
        e.Handled = true;
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
        if (IsColorPicking)
        {
            e.Handled = true;
            return;
        }
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            Close();
        }
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape && IsColorPicking)
        {
            FinishColorPicking();
            e.Handled = true;
            return;
        }
        if (HandleColorShortcut(e.Key, Keyboard.Modifiers))
            e.Handled = true;
    }

    internal bool HandleColorShortcut(Key key, ModifierKeys modifiers)
    {
        if (!IsColorPicking
            || key != Key.C
            || (modifiers & (ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Windows)) != ModifierKeys.None)
        {
            return false;
        }
        if ((modifiers & ModifierKeys.Shift) == ModifierKeys.Shift)
        {
            _colorMagnifier.ToggleDisplayFormat();
        }
        else if (_colorMagnifier.CurrentSample is { } sample)
        {
            try
            {
                string copied = sample.Text(_colorMagnifier.DisplayFormat);
                _colorClipboardWriter(copied);
                _colorMagnifier.ShowCopyConfirmation(copied);
            }
            catch (ExternalException)
            {
                SystemSounds.Beep.Play();
            }
        }
        else
        {
            SystemSounds.Beep.Play();
        }
        return true;
    }

    internal void ToggleColorPicking()
    {
        if (IsColorPicking)
            FinishColorPicking();
        else
            BeginColorPicking();
    }

    internal void UpdateColorAt(Point imagePoint)
    {
        if (!IsColorPicking)
            return;
        double width = PinImage.ActualWidth > 0 ? PinImage.ActualWidth : PinImage.Width;
        double height = PinImage.ActualHeight > 0 ? PinImage.ActualHeight : PinImage.Height;
        if (width <= 0 || height <= 0
            || imagePoint.X < 0 || imagePoint.Y < 0
            || imagePoint.X > width || imagePoint.Y > height)
        {
            _colorMagnifierWindow.Hide();
            return;
        }
        int pixelX = Math.Clamp((int)Math.Floor(imagePoint.X * _bitmap.PixelWidth / width), 0, _bitmap.PixelWidth - 1);
        int pixelY = Math.Clamp((int)Math.Floor(imagePoint.Y * _bitmap.PixelHeight / height), 0, _bitmap.PixelHeight - 1);
        _colorMagnifier.Update(CompositedBitmap(), pixelX, pixelY);
        PositionColorMagnifier(imagePoint);
    }

    private void BeginColorPicking()
    {
        IsColorPicking = true;
        ColorPickerMenuItem.Header = "退出取色";
        Cursor = Cursors.Cross;
        Activate();
        Keyboard.Focus(this);
    }

    private void FinishColorPicking()
    {
        IsColorPicking = false;
        ColorPickerMenuItem.Header = "取色";
        Cursor = Cursors.Arrow;
        _colorMagnifierWindow.Hide();
    }

    private void PositionColorMagnifier(Point imagePoint)
    {
        Point screenPixels = PinImage.PointToScreen(imagePoint);
        Point screen = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformFromDevice.Transform(screenPixels)
            ?? screenPixels;
        double left = screen.X + 16;
        double top = screen.Y + 16;
        Rect workArea = SystemParameters.WorkArea;
        if (left + _colorMagnifier.Width > workArea.Right)
            left = screen.X - _colorMagnifier.Width - 16;
        if (top + _colorMagnifier.Height > workArea.Bottom)
            top = screen.Y - _colorMagnifier.Height - 16;
        _colorMagnifierWindow.Left = Math.Max(workArea.Left, left);
        _colorMagnifierWindow.Top = Math.Max(workArea.Top, top);
        if (!_colorMagnifierWindow.IsVisible)
        {
            _colorMagnifierWindow.Owner = this;
            _colorMagnifierWindow.Show();
        }
    }

    private void OnColorPickerClick(object sender, RoutedEventArgs e) => ToggleColorPicking();

    private void OnCopyClick(object sender, RoutedEventArgs e)
    {
        Clipboard.SetImage(CompositedBitmap());
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
            encoder.Frames.Add(BitmapFrame.Create(CompositedBitmap()));
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

    private void OnAnnotationClick(object sender, RoutedEventArgs e)
    {
        ToggleAnnotationEditing();
    }

    internal void ToggleAnnotationEditing()
    {
        if (IsColorPicking)
            FinishColorPicking();
        IsAnnotationEditing = !IsAnnotationEditing;
        AnnotationMenuItem.Header = IsAnnotationEditing ? "完成标注" : "标注";
        AnnotationToolbar.SetPinAnnotationMode(IsAnnotationEditing);
        AnnotationToolbar.Visibility = IsAnnotationEditing ? Visibility.Visible : Visibility.Collapsed;
        if (!IsAnnotationEditing)
        {
            _activeAnnotationTool = "None";
            AnnotationToolbar.ClearSelectedTool();
        }
        Activate();
        Keyboard.Focus(this);
    }

    private void OnAnnotationToolSelected(string tool)
    {
        _activeAnnotationTool = tool;
        Cursor = tool == "None" ? Cursors.Arrow : Cursors.Cross;
    }

    private void OnAnnotationActionTriggered(string action)
    {
        switch (action)
        {
            case "Undo":
                if (_annotationHistory.Count > 0)
                {
                    UIElement element = _annotationHistory[^1];
                    _annotationHistory.RemoveAt(_annotationHistory.Count - 1);
                    _annotationRedoStack.Add(element);
                    AnnotationCanvas.Children.Remove(element);
                }
                break;
            case "Redo":
                if (_annotationRedoStack.Count > 0)
                {
                    UIElement element = _annotationRedoStack[^1];
                    _annotationRedoStack.RemoveAt(_annotationRedoStack.Count - 1);
                    _annotationHistory.Add(element);
                    AnnotationCanvas.Children.Add(element);
                }
                break;
            case "Finish":
                if (IsAnnotationEditing)
                    ToggleAnnotationEditing();
                break;
        }
        UpdateAnnotationUndoRedoState();
    }

    private void UpdateAnnotationUndoRedoState() =>
        AnnotationToolbar.SetUndoRedoState(_annotationHistory.Count > 0, _annotationRedoStack.Count > 0);

    private void StartAnnotationDrawing(Point point)
    {
        var brush = new SolidColorBrush(AnnotationToolbar.CurrentColor);
        double strokeSize = AnnotationToolbar.CurrentStrokeSize;
        switch (_activeAnnotationTool)
        {
            case "Pen":
                var pen = new Polyline
                {
                    Stroke = brush,
                    StrokeThickness = strokeSize,
                    StrokeLineJoin = PenLineJoin.Round,
                    StrokeStartLineCap = PenLineCap.Round,
                    StrokeEndLineCap = PenLineCap.Round
                };
                pen.Points.Add(point);
                AnnotationCanvas.Children.Add(pen);
                _currentDrawingShape = pen;
                break;
            case "Rect":
                var rect = new Rectangle { Stroke = brush, StrokeThickness = strokeSize, RadiusX = 3, RadiusY = 3 };
                Canvas.SetLeft(rect, point.X);
                Canvas.SetTop(rect, point.Y);
                AnnotationCanvas.Children.Add(rect);
                _currentDrawingShape = rect;
                break;
            case "Ellipse":
                var ellipse = new Ellipse { Stroke = brush, StrokeThickness = strokeSize };
                Canvas.SetLeft(ellipse, point.X);
                Canvas.SetTop(ellipse, point.Y);
                AnnotationCanvas.Children.Add(ellipse);
                _currentDrawingShape = ellipse;
                break;
            case "Arrow":
                var arrow = new System.Windows.Shapes.Path
                {
                    Stroke = brush,
                    StrokeThickness = strokeSize,
                    StrokeStartLineCap = PenLineCap.Round,
                    StrokeEndLineCap = PenLineCap.Round,
                    StrokeLineJoin = PenLineJoin.Round,
                    Data = MakeArrowGeometry(point, point, strokeSize)
                };
                AnnotationCanvas.Children.Add(arrow);
                _currentDrawingShape = arrow;
                break;
            case "Text":
                var text = new System.Windows.Controls.TextBox
                {
                    Background = Brushes.Transparent,
                    BorderBrush = brush,
                    BorderThickness = new Thickness(1),
                    Foreground = brush,
                    FontSize = 16,
                    FontWeight = FontWeights.Bold,
                    MinWidth = 60,
                    CaretBrush = brush
                };
                Canvas.SetLeft(text, point.X);
                Canvas.SetTop(text, point.Y);
                AnnotationCanvas.Children.Add(text);
                _annotationHistory.Add(text);
                text.Loaded += (_, _) => text.Focus();
                text.LostFocus += (_, _) =>
                {
                    if (string.IsNullOrWhiteSpace(text.Text))
                    {
                        AnnotationCanvas.Children.Remove(text);
                        _annotationHistory.Remove(text);
                    }
                    else
                    {
                        text.BorderThickness = new Thickness(0);
                        text.IsReadOnly = true;
                    }
                    UpdateAnnotationUndoRedoState();
                };
                MakeTextMovable(text);
                UpdateAnnotationUndoRedoState();
                break;
            case "Mosaic":
                double mosaicDiameter = Math.Max(18, strokeSize * 5);
                _currentMosaicStroke = MosaicStrokeBuilder.Begin(
                    _bitmap,
                    new Size(PinSurface.ActualWidth, PinSurface.ActualHeight),
                    point,
                    mosaicDiameter);
                _lastMosaicPoint = point;
                AnnotationCanvas.Children.Add(_currentMosaicStroke);
                break;
            case "Number":
                var marker = new Border
                {
                    Width = 24,
                    Height = 24,
                    CornerRadius = new CornerRadius(12),
                    Background = brush,
                    Child = new TextBlock
                    {
                        Text = _nextNumber.ToString(),
                        Foreground = Brushes.White,
                        FontWeight = FontWeights.Bold,
                        FontSize = 13,
                        HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
                        VerticalAlignment = System.Windows.VerticalAlignment.Center
                    }
                };
                _nextNumber++;
                Canvas.SetLeft(marker, point.X - 12);
                Canvas.SetTop(marker, point.Y - 12);
                AnnotationCanvas.Children.Add(marker);
                _annotationHistory.Add(marker);
                _annotationRedoStack.Clear();
                UpdateAnnotationUndoRedoState();
                break;
        }
    }

    private void UpdateAnnotationDrawing(Point point)
    {
        Point current = new(
            Math.Clamp(point.X, 0, PinSurface.ActualWidth),
            Math.Clamp(point.Y, 0, PinSurface.ActualHeight));
        if (_currentDrawingShape is Rectangle rect)
        {
            Canvas.SetLeft(rect, Math.Min(_drawingStart.X, current.X));
            Canvas.SetTop(rect, Math.Min(_drawingStart.Y, current.Y));
            rect.Width = Math.Abs(current.X - _drawingStart.X);
            rect.Height = Math.Abs(current.Y - _drawingStart.Y);
        }
        else if (_currentDrawingShape is Ellipse ellipse)
        {
            Canvas.SetLeft(ellipse, Math.Min(_drawingStart.X, current.X));
            Canvas.SetTop(ellipse, Math.Min(_drawingStart.Y, current.Y));
            ellipse.Width = Math.Abs(current.X - _drawingStart.X);
            ellipse.Height = Math.Abs(current.Y - _drawingStart.Y);
        }
        else if (_currentDrawingShape is Polyline pen)
        {
            pen.Points.Add(current);
        }
        else if (_currentDrawingShape is System.Windows.Shapes.Path arrow)
        {
            arrow.Data = MakeArrowGeometry(_drawingStart, current, arrow.StrokeThickness);
        }
        else if (_currentMosaicStroke is not null && _activeAnnotationTool == "Mosaic")
        {
            double diameter = Math.Max(18, AnnotationToolbar.CurrentStrokeSize * 5);
            foreach (Point sample in MosaicStrokeBuilder.Interpolate(
                         _lastMosaicPoint,
                         current,
                         Math.Max(2, diameter / 4)))
            {
                MosaicStrokeBuilder.AddStamp(
                    _currentMosaicStroke,
                    _bitmap,
                    new Size(PinSurface.ActualWidth, PinSurface.ActualHeight),
                    sample,
                    diameter);
            }
            _lastMosaicPoint = current;
        }
    }

    private BitmapSource CompositedBitmap()
    {
        if (_annotationHistory.Count == 0 || PinSurface.ActualWidth <= 0 || PinSurface.ActualHeight <= 0)
            return _bitmap;
        var output = new RenderTargetBitmap(_bitmap.PixelWidth, _bitmap.PixelHeight, 96, 96, PixelFormats.Pbgra32);
        var visual = new DrawingVisual();
        using (DrawingContext context = visual.RenderOpen())
        {
            context.DrawImage(_bitmap, new Rect(0, 0, _bitmap.PixelWidth, _bitmap.PixelHeight));
            double scaleX = _bitmap.PixelWidth / PinSurface.ActualWidth;
            double scaleY = _bitmap.PixelHeight / PinSurface.ActualHeight;
            context.PushTransform(new ScaleTransform(scaleX, scaleY));
            context.DrawRectangle(new VisualBrush(AnnotationCanvas)
            {
                Stretch = Stretch.None,
                AlignmentX = AlignmentX.Left,
                AlignmentY = AlignmentY.Top
            }, null, new Rect(0, 0, PinSurface.ActualWidth, PinSurface.ActualHeight));
            context.Pop();
        }
        output.Render(visual);
        output.Freeze();
        return output;
    }

    private static Geometry MakeArrowGeometry(Point start, Point end, double strokeSize)
    {
        double dx = end.X - start.X;
        double dy = end.Y - start.Y;
        double length = Math.Sqrt(dx * dx + dy * dy);
        if (length < 0.001)
            return new LineGeometry(start, end);
        double angle = Math.Atan2(dy, dx);
        double headLength = Math.Min(Math.Max(strokeSize * 4, 8), length * 0.5);
        const double headAngle = Math.PI / 7;
        Point first = new(end.X - headLength * Math.Cos(angle - headAngle), end.Y - headLength * Math.Sin(angle - headAngle));
        Point second = new(end.X - headLength * Math.Cos(angle + headAngle), end.Y - headLength * Math.Sin(angle + headAngle));
        var geometry = new StreamGeometry();
        using (StreamGeometryContext context = geometry.Open())
        {
            context.BeginFigure(start, false, false);
            context.LineTo(end, true, false);
            context.BeginFigure(end, false, false);
            context.LineTo(first, true, false);
            context.BeginFigure(end, false, false);
            context.LineTo(second, true, false);
        }
        geometry.Freeze();
        return geometry;
    }

    private static void MakeTextMovable(System.Windows.Controls.TextBox textBox)
    {
        Point offset = default;
        bool dragging = false;
        textBox.PreviewMouseLeftButtonDown += (_, eventArgs) =>
        {
            if (!textBox.IsReadOnly)
                return;
            Point point = eventArgs.GetPosition(textBox.Parent as IInputElement);
            offset = new Point(point.X - Canvas.GetLeft(textBox), point.Y - Canvas.GetTop(textBox));
            dragging = true;
            textBox.CaptureMouse();
            eventArgs.Handled = true;
        };
        textBox.PreviewMouseMove += (_, eventArgs) =>
        {
            if (!dragging || eventArgs.LeftButton != MouseButtonState.Pressed)
                return;
            Point point = eventArgs.GetPosition(textBox.Parent as IInputElement);
            Canvas.SetLeft(textBox, Math.Max(0, point.X - offset.X));
            Canvas.SetTop(textBox, Math.Max(0, point.Y - offset.Y));
            eventArgs.Handled = true;
        };
        textBox.PreviewMouseLeftButtonUp += (_, eventArgs) =>
        {
            dragging = false;
            textBox.ReleaseMouseCapture();
            eventArgs.Handled = true;
        };
    }

    private async void OnOcrClick(object sender, RoutedEventArgs e)
    {
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
                new Rect(Left, Top, ActualWidth, ActualHeight))
            {
                Owner = this,
                Left = Left,
                Top = Top
            };
            ocrWindow.Show();
            ocrWindow.Activate();
            Hide();
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

    protected override void OnClosed(EventArgs e)
    {
        Cursor = Cursors.Arrow;
        if (_colorMagnifierWindow.IsVisible)
            _colorMagnifierWindow.Close();
        base.OnClosed(e);
    }
}
