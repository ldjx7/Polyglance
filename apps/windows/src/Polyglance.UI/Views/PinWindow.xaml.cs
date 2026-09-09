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
using Path = System.Windows.Shapes.Path;
using TextBox = System.Windows.Controls.TextBox;
using FontFamily = System.Windows.Media.FontFamily;
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
    internal BitmapSource Bitmap => _bitmap;
    private readonly TranslationService? _translationService;
    private readonly AppConfiguration? _configuration;
    private readonly Action<string> _colorClipboardWriter;
    private readonly MagnifierControl _colorMagnifier = new();
    private readonly Window _colorMagnifierWindow;
    private double _scale = 1.0;
    private readonly System.Windows.Threading.DispatcherTimer _zoomBadgeTimer = new() { Interval = TimeSpan.FromMilliseconds(800) };
    private readonly List<UIElement> _annotationHistory = new();
    private readonly List<UIElement> _annotationRedoStack = new();
    private FrameworkElement? _currentDrawingShape;
    private Canvas? _currentMosaicStroke;
    private Point _lastMosaicPoint;
    private Point _drawingStart;
    private string _activeAnnotationTool = "None";
    private UIElement? _selectedAnnotationElement;
    private AnnotationHandleType _draggingAnnotationHandle = AnnotationHandleType.None;
    private bool _isMovingAnnotation;
    private Point _movingAnnotationLastPoint;
    private int _nextNumber = 1;
    private bool _isLocked;
    private readonly PinSessionController _sessions;

    private OcrTextDocument? _ocrDocument;
    private bool _isTextSelecting;
    private Point _textSelectStart;
    private Rect _textSelectionRect = Rect.Empty;
    private readonly List<LayoutTextWord> _selectedWords = [];

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
        Size? capturedDisplaySize = null,
        PinArchiveSource source = PinArchiveSource.Screenshot,
        bool saveToHistory = true)
        : this(bitmap, translationService, configuration, Clipboard.SetText, capturedDisplaySize, source, saveToHistory)
    {
    }

    internal PinWindow(
        BitmapSource bitmap,
        TranslationService? translationService,
        AppConfiguration? configuration,
        Action<string> colorClipboardWriter,
        Size? capturedDisplaySize = null,
        PinArchiveSource source = PinArchiveSource.Screenshot,
        bool saveToHistory = true,
        PinArchiveStore? archiveStore = null,
        string? archiveId = null,
        PinSessionRecord? session = null)
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

        AnnotationToolbar.ApplyItemsConfiguration(configuration?.ScreenshotToolbarItems);
        AnnotationToolbar.ToolSelected += OnAnnotationToolSelected;
        AnnotationToolbar.ActionTriggered += OnAnnotationActionTriggered;
        AnnotationToolbar.ColorChanged += OnAnnotationToolbarColorChanged;
        AnnotationToolbar.StrokeSizeChanged += OnAnnotationToolbarStrokeSizeChanged;
        AnnotationToolbar.SubToolActionTriggered += OnAnnotationToolbarSubToolActionTriggered;

        _sessions = PinSessionController.For(archiveStore);
        _isLocked = session?.IsLocked ?? false;
        Opacity = session?.Opacity ?? 1;
        Topmost = session?.IsAlwaysOnTop ?? true;
        _sessions.Register(this, bitmap, source, saveToHistory, archiveId, session, null, state => state with
        {
            X = double.IsFinite(Left) ? Left : 0, Y = double.IsFinite(Top) ? Top : 0,
            Width = PinImage.Width, Height = PinImage.Height, Opacity = Opacity,
            IsLocked = _isLocked, IsAlwaysOnTop = Topmost
        }, () => _annotationHistory.Count > 0 ? CompositedBitmap() : null);
        var destroyItem = new MenuItem { Header = "销毁贴图及历史" };
        destroyItem.Click += async (_, _) => await _sessions.Destroy(this);
        var destroyAllItem = new MenuItem { Header = "销毁全部贴图及对应历史" };
        destroyAllItem.Click += async (_, _) => await _sessions.DestroyAll();
        var lockItem = new MenuItem { Header = "锁定／解锁贴图" };
        lockItem.Click += (_, _) => _isLocked = !_isLocked;
        var restoreItem = new MenuItem { Header = "恢复最近关闭的贴图" };
        restoreItem.Click += async (_, _) => await _sessions.Restore(false, _translationService, _configuration);
        ContainerBorder.ContextMenu.Items.Add(lockItem);
        ContainerBorder.ContextMenu.Items.Add(destroyItem);
        ContainerBorder.ContextMenu.Items.Add(destroyAllItem);
        ContainerBorder.ContextMenu.Items.Add(restoreItem);

        OcrMenuItem.IsEnabled = true;
        TranslateMenuItem.IsEnabled = translationService != null && configuration != null;
        // The pin is created as the active replacement for the screenshot
        // selection. Apply its selected appearance before the first render so
        // there is no inactive-to-active flash after Show().
        SetSelectionHighlight(true);
        _zoomBadgeTimer.Tick += (_, _) => { ZoomBadge.Visibility = Visibility.Collapsed; _zoomBadgeTimer.Stop(); };
        Loaded += async (_, _) => await RecognizeTextInPinAsync();
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
        if (_isLocked) return;
        if (e.ChangedButton == MouseButton.Middle)
        {
            _scale = 1.0;
            PinImage.Width = _bitmap.PixelWidth;
            PinImage.Height = _bitmap.PixelHeight;
            ShowZoomBadge(100);
            e.Handled = true;
            return;
        }
        if (IsColorPicking)
        {
            UpdateColorAt(e.GetPosition(PinImage));
            e.Handled = true;
            return;
        }
        if (IsAnnotationEditing)
        {
            if (!AnnotationToolbar.IsMouseOver)
            {
                AnnotationToolbar.CloseAllPopups();
            }
            Point point = e.GetPosition(PinSurface);

            if (_selectedAnnotationElement != null)
            {
                var handle = AnnotationSecondaryEditor.HitTestHandles(_selectedAnnotationElement, point);
                if (handle != AnnotationHandleType.None)
                {
                    _draggingAnnotationHandle = handle;
                    PinSurface.CaptureMouse();
                    e.Handled = true;
                    return;
                }
            }

            UIElement? hitElement = null;
            for (int i = _annotationHistory.Count - 1; i >= 0; i--)
            {
                if (AnnotationSecondaryEditor.HitTestElement(_annotationHistory[i], point))
                {
                    hitElement = _annotationHistory[i];
                    break;
                }
            }

            if (hitElement != null)
            {
                if (e.ClickCount >= 2 && hitElement is TextBox tb)
                {
                    SelectAnnotationElement(tb);
                    tb.IsReadOnly = false;
                    tb.Focus();
                    tb.SelectAll();
                    e.Handled = true;
                    return;
                }

                SelectAnnotationElement(hitElement);
                _isMovingAnnotation = true;
                _movingAnnotationLastPoint = point;
                PinSurface.CaptureMouse();
                e.Handled = true;
                return;
            }

            if (_selectedAnnotationElement != null)
            {
                SelectAnnotationElement(null);
            }

            if (_activeAnnotationTool == "None")
                return;
            _drawingStart = point;
            StartAnnotationDrawing(point);
            PinSurface.CaptureMouse();
            e.Handled = true;
            return;
        }
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            Point pt = e.GetPosition(PinSurface);
            if (_ocrDocument != null && (GetWordAt(pt) != null || (_selectedWords.Count > 0 && _textSelectionRect.Contains(pt))))
            {
                _isTextSelecting = true;
                _textSelectStart = pt;
                _textSelectionRect = new Rect(pt, new Size(0, 0));
                TextCapsuleBar.Visibility = Visibility.Collapsed;
                PinSurface.CaptureMouse();
                e.Handled = true;
                return;
            }

            ClearTextSelection();
            DragMove();
        }
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (IsColorPicking)
        {
            UpdateColorAt(e.GetPosition(PinImage));
            return;
        }

        if (IsAnnotationEditing)
        {
            Point pt = e.GetPosition(PinSurface);

            if (_draggingAnnotationHandle != AnnotationHandleType.None && _selectedAnnotationElement != null)
            {
                AnnotationSecondaryEditor.ResizeElement(
                    _selectedAnnotationElement,
                    _draggingAnnotationHandle,
                    pt,
                    rect => MosaicStrokeBuilder.CreateRectMosaic(
                        _bitmap,
                        new Size(PinSurface.ActualWidth, PinSurface.ActualHeight),
                        rect,
                        Math.Max(4, AnnotationToolbar.CurrentStrokeSize * 2),
                        AnnotationToolbar.MosaicIsBlur)?.Source as BitmapSource);
                AnnotationSecondaryEditor.DrawSelection(AnnotationSelectionCanvas, _selectedAnnotationElement);
                e.Handled = true;
                return;
            }

            if (_isMovingAnnotation && _selectedAnnotationElement != null)
            {
                double dx = pt.X - _movingAnnotationLastPoint.X;
                double dy = pt.Y - _movingAnnotationLastPoint.Y;
                _movingAnnotationLastPoint = pt;
                AnnotationSecondaryEditor.MoveElement(_selectedAnnotationElement, dx, dy);
                AnnotationSecondaryEditor.DrawSelection(AnnotationSelectionCanvas, _selectedAnnotationElement);
                e.Handled = true;
                return;
            }

            if (_currentDrawingShape is not null || _currentMosaicStroke is not null)
            {
                UpdateAnnotationDrawing(pt);
                return;
            }

            if (e.LeftButton == MouseButtonState.Released)
            {
                if (_selectedAnnotationElement != null)
                {
                    var handle = AnnotationSecondaryEditor.HitTestHandles(_selectedAnnotationElement, pt);
                    if (handle != AnnotationHandleType.None)
                    {
                        Cursor = AnnotationSecondaryEditor.GetCursorForHandle(handle);
                        return;
                    }
                    if (AnnotationSecondaryEditor.HitTestElement(_selectedAnnotationElement, pt))
                    {
                        Cursor = Cursors.SizeAll;
                        return;
                    }
                }

                bool overAny = false;
                for (int i = _annotationHistory.Count - 1; i >= 0; i--)
                {
                    if (AnnotationSecondaryEditor.HitTestElement(_annotationHistory[i], pt))
                    {
                        overAny = true;
                        break;
                    }
                }
                Cursor = overAny ? Cursors.Hand : (_activeAnnotationTool != "None" ? Cursors.Cross : Cursors.Arrow);
            }
            return;
        }

        if (!IsAnnotationEditing && !IsColorPicking && !_isLocked)
        {
            Point pt = e.GetPosition(PinSurface);
            if (_isTextSelecting)
            {
                _textSelectionRect = new Rect(
                    Math.Min(_textSelectStart.X, pt.X),
                    Math.Min(_textSelectStart.Y, pt.Y),
                    Math.Max(1, Math.Abs(pt.X - _textSelectStart.X)),
                    Math.Max(1, Math.Abs(pt.Y - _textSelectStart.Y)));
                UpdateTextSelection();
                return;
            }

            if (_ocrDocument != null)
            {
                var word = GetWordAt(pt);
                Cursor = word != null ? Cursors.IBeam : Cursors.Arrow;
            }
        }
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_isTextSelecting)
        {
            _isTextSelecting = false;
            PinSurface.ReleaseMouseCapture();
            if (_selectedWords.Count > 0)
            {
                ShowTextCapsuleBar();
            }
            else
            {
                ClearTextSelection();
            }
            e.Handled = true;
            return;
        }

        if (_draggingAnnotationHandle != AnnotationHandleType.None)
        {
            _draggingAnnotationHandle = AnnotationHandleType.None;
            PinSurface.ReleaseMouseCapture();
            if (_selectedAnnotationElement != null)
            {
                AnnotationSecondaryEditor.DrawSelection(AnnotationSelectionCanvas, _selectedAnnotationElement);
            }
            e.Handled = true;
            return;
        }

        if (_isMovingAnnotation)
        {
            _isMovingAnnotation = false;
            PinSurface.ReleaseMouseCapture();
            if (_selectedAnnotationElement != null)
            {
                AnnotationSecondaryEditor.DrawSelection(AnnotationSelectionCanvas, _selectedAnnotationElement);
            }
            e.Handled = true;
            return;
        }

        if (_currentDrawingShape is null && _currentMosaicStroke is null)
            return;

        var finished = _currentDrawingShape is not null
            ? _currentDrawingShape
            : (UIElement)_currentMosaicStroke!;

        _annotationHistory.Add(finished);
        _annotationRedoStack.Clear();
        _currentDrawingShape = null;
        _currentMosaicStroke = null;
        PinSurface.ReleaseMouseCapture();
        SelectAnnotationElement(finished);
        UpdateAnnotationUndoRedoState();
        e.Handled = true;
    }

    private void OnMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (_isLocked) return;
        if (_selectedAnnotationElement != null || (_activeAnnotationTool != "None" && !string.IsNullOrEmpty(_activeAnnotationTool)))
        {
            if (_selectedAnnotationElement is TextBox || (_selectedAnnotationElement == null && _activeAnnotationTool == "Text"))
            {
                AnnotationToolbar.AdjustFontSize(e.Delta > 0 ? 1 : -1);
            }
            else
            {
                AnnotationToolbar.AdjustStrokeSize(e.Delta > 0 ? 1 : -1);
            }
            e.Handled = true;
            return;
        }

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
            ShowZoomBadge((int)Math.Round(_scale * 100));
            e.Handled = true;
        }
    }

    private void ShowZoomBadge(int percent)
    {
        ZoomBadgeText.Text = $"{percent}%";
        ZoomBadge.Visibility = Visibility.Visible;
        _zoomBadgeTimer.Stop();
        _zoomBadgeTimer.Start();
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
        if (TextCapsuleBar.Visibility == Visibility.Visible)
        {
            if (e.Key == Key.Escape)
            {
                ClearTextSelection();
                e.Handled = true;
                return;
            }
            if (e.Key == Key.C && (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
            {
                OnCapsuleCopyClick(this, new RoutedEventArgs());
                e.Handled = true;
                return;
            }
        }

        if (IsAnnotationEditing)
        {
            if (e.Key == Key.Delete || e.Key == Key.Back)
            {
                if (_selectedAnnotationElement != null)
                {
                    if (_selectedAnnotationElement is TextBox tb && !tb.IsReadOnly)
                    {
                        return;
                    }
                    _annotationHistory.Remove(_selectedAnnotationElement);
                    AnnotationCanvas.Children.Remove(_selectedAnnotationElement);
                    SelectAnnotationElement(null);
                    _annotationRedoStack.Clear();
                    UpdateAnnotationUndoRedoState();
                    e.Handled = true;
                    return;
                }
            }
            else if (e.Key == Key.Escape)
            {
                if (_selectedAnnotationElement != null)
                {
                    SelectAnnotationElement(null);
                    e.Handled = true;
                    return;
                }
                ToggleAnnotationEditing();
                e.Handled = true;
                return;
            }
            else if (e.Key == Key.Z && (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
            {
                OnAnnotationActionTriggered("Undo");
                e.Handled = true;
                return;
            }
            else if (e.Key == Key.Y && (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
            {
                OnAnnotationActionTriggered("Redo");
                e.Handled = true;
                return;
            }
        }

        if (e.Key == Key.Escape && !IsColorPicking) { Close(); e.Handled = true; return; }
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
            SelectAnnotationElement(null);
            Cursor = Cursors.Arrow;
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
                    if (_selectedAnnotationElement == element)
                    {
                        SelectAnnotationElement(null);
                    }
                }
                break;
            case "Redo":
                if (_annotationRedoStack.Count > 0)
                {
                    UIElement element = _annotationRedoStack[^1];
                    _annotationRedoStack.RemoveAt(_annotationRedoStack.Count - 1);
                    _annotationHistory.Add(element);
                    AnnotationCanvas.Children.Add(element);
                    SelectAnnotationElement(element);
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
                var rect = new Rectangle
                {
                    Stroke = brush,
                    StrokeThickness = strokeSize,
                    RadiusX = 3,
                    RadiusY = 3,
                    StrokeDashArray = AnnotationToolbar.CurrentDashArray,
                    Fill = AnnotationToolbar.IsFilled ? brush : Brushes.Transparent
                };
                Canvas.SetLeft(rect, point.X);
                Canvas.SetTop(rect, point.Y);
                AnnotationCanvas.Children.Add(rect);
                _currentDrawingShape = rect;
                break;
            case "Ellipse":
                var ellipse = new Ellipse
                {
                    Stroke = brush,
                    StrokeThickness = strokeSize,
                    StrokeDashArray = AnnotationToolbar.CurrentDashArray,
                    Fill = AnnotationToolbar.IsFilled ? brush : Brushes.Transparent
                };
                Canvas.SetLeft(ellipse, point.X);
                Canvas.SetTop(ellipse, point.Y);
                AnnotationCanvas.Children.Add(ellipse);
                _currentDrawingShape = ellipse;
                break;
            case "Line":
                var line = new System.Windows.Shapes.Line
                {
                    X1 = point.X,
                    Y1 = point.Y,
                    X2 = point.X,
                    Y2 = point.Y,
                    Stroke = brush,
                    StrokeThickness = strokeSize,
                    StrokeStartLineCap = PenLineCap.Round,
                    StrokeEndLineCap = PenLineCap.Round,
                    StrokeDashArray = AnnotationToolbar.CurrentDashArray
                };
                AnnotationCanvas.Children.Add(line);
                _currentDrawingShape = line;
                break;
            case "Arrow":
                var arrowInfo = new ArrowInfo
                {
                    Start = point,
                    End = point,
                    StrokeSize = strokeSize,
                    ArrowStyle = AnnotationToolbar.ArrowStyle,
                    IsFilled = AnnotationToolbar.IsFilled
                };
                var arrow = new System.Windows.Shapes.Path
                {
                    Stroke = brush,
                    StrokeThickness = (AnnotationToolbar.ArrowStyle == 2 || AnnotationToolbar.ArrowStyle == 3) ? Math.Max(strokeSize * 1.6, strokeSize + 2.0) : strokeSize,
                    StrokeStartLineCap = PenLineCap.Round,
                    StrokeEndLineCap = PenLineCap.Round,
                    StrokeLineJoin = PenLineJoin.Round,
                    Fill = (AnnotationToolbar.ArrowStyle == 5 || AnnotationToolbar.ArrowStyle == 7 || AnnotationToolbar.ArrowStyle == 8 || AnnotationToolbar.IsFilled) ? brush : Brushes.Transparent,
                    StrokeDashArray = AnnotationToolbar.CurrentDashArray,
                    Data = AnnotationSecondaryEditor.MakeArrowGeometry(point, point, strokeSize, AnnotationToolbar.ArrowStyle, AnnotationToolbar.IsFilled),
                    Tag = arrowInfo
                };
                AnnotationCanvas.Children.Add(arrow);
                _currentDrawingShape = arrow;
                break;
            case "Text":
                var text = new System.Windows.Controls.TextBox
                {
                    Background = AnnotationToolbar.HasTextBorder ? new SolidColorBrush(Color.FromArgb(160, 0, 0, 0)) : Brushes.Transparent,
                    BorderBrush = AnnotationToolbar.HasTextBorder ? brush : Brushes.Transparent,
                    BorderThickness = AnnotationToolbar.HasTextBorder ? new Thickness(1) : new Thickness(1),
                    Foreground = AnnotationToolbar.HasTextBorder ? Brushes.White : brush,
                    FontFamily = !string.IsNullOrEmpty(AnnotationToolbar.CurrentFontFamily) ? new System.Windows.Media.FontFamily(AnnotationToolbar.CurrentFontFamily) : new System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei"),
                    FontSize = AnnotationToolbar.FontSizeValue,
                    FontWeight = AnnotationToolbar.IsBold ? FontWeights.Bold : FontWeights.Normal,
                    FontStyle = AnnotationToolbar.IsItalic ? FontStyles.Italic : FontStyles.Normal,
                    AcceptsReturn = true,
                    MinWidth = 60,
                    Padding = AnnotationToolbar.HasTextBorder ? new Thickness(4, 2, 4, 2) : new Thickness(0),
                    CaretBrush = AnnotationToolbar.HasTextBorder ? Brushes.White : brush
                };
                Canvas.SetLeft(text, point.X);
                Canvas.SetTop(text, point.Y);
                AnnotationCanvas.Children.Add(text);
                _annotationHistory.Add(text);
                _annotationRedoStack.Clear();
                text.Loaded += (_, _) => text.Focus();
                text.LostFocus += (_, _) =>
                {
                    if (string.IsNullOrWhiteSpace(text.Text))
                    {
                        AnnotationCanvas.Children.Remove(text);
                        _annotationHistory.Remove(text);
                        if (_selectedAnnotationElement == text)
                        {
                            SelectAnnotationElement(null);
                        }
                    }
                    else
                    {
                        text.BorderThickness = AnnotationToolbar.HasTextBorder ? new Thickness(1) : new Thickness(0);
                        text.IsReadOnly = true;
                        SelectAnnotationElement(text);
                    }
                    UpdateAnnotationUndoRedoState();
                };
                UpdateAnnotationUndoRedoState();
                break;
            case "Mosaic":
                if (AnnotationToolbar.MosaicShapeType == 1)
                {
                    var rectImg = MosaicStrokeBuilder.CreateRectMosaic(
                        _bitmap,
                        new Size(PinSurface.ActualWidth, PinSurface.ActualHeight),
                        new Rect(point, new Size(1, 1)),
                        Math.Max(4, strokeSize * 2),
                        AnnotationToolbar.MosaicIsBlur);
                    Canvas.SetLeft(rectImg, point.X);
                    Canvas.SetTop(rectImg, point.Y);
                    AnnotationCanvas.Children.Add(rectImg);
                    _currentDrawingShape = rectImg;
                }
                else
                {
                    double mosaicDiameter = Math.Max(18, strokeSize * 5);
                    _currentMosaicStroke = MosaicStrokeBuilder.Begin(
                        _bitmap,
                        new Size(PinSurface.ActualWidth, PinSurface.ActualHeight),
                        point,
                        mosaicDiameter,
                        AnnotationToolbar.MosaicIsBlur);
                    _lastMosaicPoint = point;
                    AnnotationCanvas.Children.Add(_currentMosaicStroke);
                }
                break;
            case "Number":
                bool isOutline = AnnotationToolbar.NumberStyle == 1;
                double markerSize = Math.Max(18, AnnotationToolbar.CurrentStrokeSize * 5);
                double radius = markerSize / 2.0;
                var marker = new Border
                {
                    Width = markerSize,
                    Height = markerSize,
                    CornerRadius = new CornerRadius(radius),
                    Background = isOutline ? Brushes.Transparent : brush,
                    BorderBrush = isOutline ? brush : Brushes.Transparent,
                    BorderThickness = isOutline ? new Thickness(2) : new Thickness(0),
                    Child = new TextBlock
                    {
                        Text = _nextNumber.ToString(),
                        Foreground = isOutline ? brush : Brushes.White,
                        FontWeight = FontWeights.Bold,
                        FontSize = Math.Max(9, markerSize * 0.55),
                        HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
                        VerticalAlignment = System.Windows.VerticalAlignment.Center
                    }
                };
                _nextNumber++;
                Canvas.SetLeft(marker, point.X - radius);
                Canvas.SetTop(marker, point.Y - radius);
                AnnotationCanvas.Children.Add(marker);
                _annotationHistory.Add(marker);
                _annotationRedoStack.Clear();
                SelectAnnotationElement(marker);
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
        else if (_currentDrawingShape is System.Windows.Shapes.Line line)
        {
            line.X2 = current.X;
            line.Y2 = current.Y;
        }
        else if (_currentDrawingShape is Polyline pen)
        {
            pen.Points.Add(current);
        }
        else if (_currentDrawingShape is System.Windows.Shapes.Path arrow)
        {
            if (arrow.Tag is ArrowInfo arrowInfo)
            {
                arrowInfo.End = current;
            }
            arrow.Data = AnnotationSecondaryEditor.MakeArrowGeometry(_drawingStart, current, arrow.StrokeThickness, AnnotationToolbar.ArrowStyle, AnnotationToolbar.IsFilled);
        }
        else if (_currentDrawingShape is System.Windows.Controls.Image mosaicImg && _activeAnnotationTool == "Mosaic")
        {
            double x = Math.Min(_drawingStart.X, current.X);
            double y = Math.Min(_drawingStart.Y, current.Y);
            double w = Math.Max(1, Math.Abs(current.X - _drawingStart.X));
            double h = Math.Max(1, Math.Abs(current.Y - _drawingStart.Y));
            var newImg = MosaicStrokeBuilder.CreateRectMosaic(
                _bitmap,
                new Size(PinSurface.ActualWidth, PinSurface.ActualHeight),
                new Rect(x, y, w, h),
                Math.Max(4, AnnotationToolbar.CurrentStrokeSize * 2),
                AnnotationToolbar.MosaicIsBlur);
            mosaicImg.Source = newImg.Source;
            mosaicImg.Width = w;
            mosaicImg.Height = h;
            Canvas.SetLeft(mosaicImg, x);
            Canvas.SetTop(mosaicImg, y);
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
                    diameter,
                    AnnotationToolbar.MosaicIsBlur);
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

    private void SelectAnnotationElement(UIElement? element)
    {
        if (_selectedAnnotationElement is TextBox prevTb && prevTb != element)
        {
            prevTb.IsReadOnly = true;
        }

        _selectedAnnotationElement = element;
        AnnotationSecondaryEditor.DrawSelection(AnnotationSelectionCanvas, element);
        if (element != null)
        {
            SyncElementStyleToAnnotationToolbar(element);
        }
    }

    private void SyncElementStyleToAnnotationToolbar(UIElement element)
    {
        string toolName = AnnotationSecondaryEditor.GetToolName(element);
        if (toolName != "None")
        {
            _activeAnnotationTool = toolName;
            AnnotationToolbar.SelectTool(toolName);
        }

        if (element is Shape shape)
        {
            if (shape.Stroke is SolidColorBrush sb)
            {
                AnnotationToolbar.SetCurrentColor(sb.Color);
            }
            AnnotationToolbar.SetCurrentStrokeSize(shape.StrokeThickness);
            if (shape is Path path && path.Tag is ArrowInfo arrow)
            {
                AnnotationToolbar.SetCurrentStrokeSize(arrow.StrokeSize);
            }
        }
        else if (element is TextBox tb)
        {
            if (tb.Foreground is SolidColorBrush fb)
            {
                AnnotationToolbar.SetCurrentColor(fb.Color);
            }
            AnnotationToolbar.SetFontSize(tb.FontSize);
        }
        else if (element is Border border)
        {
            if (border.Background is SolidColorBrush bb && bb != Brushes.Transparent)
            {
                AnnotationToolbar.SetCurrentColor(bb.Color);
            }
            else if (border.BorderBrush is SolidColorBrush bbb)
            {
                AnnotationToolbar.SetCurrentColor(bbb.Color);
            }
            AnnotationToolbar.SetCurrentStrokeSize(Math.Max(1, Math.Round(border.Width / 5.0)));
        }
    }

    private void OnAnnotationToolbarColorChanged(Color color)
    {
        if (_selectedAnnotationElement == null) return;
        var brush = new SolidColorBrush(color);

        if (_selectedAnnotationElement is Shape shape)
        {
            shape.Stroke = brush;
            if (shape is Path path && path.Tag is ArrowInfo arrow)
            {
                if (arrow.IsFilled || arrow.ArrowStyle == 5 || arrow.ArrowStyle == 7 || arrow.ArrowStyle == 8)
                {
                    path.Fill = brush;
                }
            }
            else if (shape is Rectangle or Ellipse)
            {
                if (AnnotationToolbar.IsFilled)
                {
                    shape.Fill = brush;
                }
            }
        }
        else if (_selectedAnnotationElement is TextBox tb)
        {
            tb.Foreground = brush;
            if (AnnotationToolbar.HasTextBorder)
            {
                tb.BorderBrush = brush;
            }
        }
        else if (_selectedAnnotationElement is Border border)
        {
            if (AnnotationToolbar.NumberStyle == 0)
            {
                border.Background = brush;
            }
            else
            {
                border.BorderBrush = brush;
                if (border.Child is TextBlock numTb)
                {
                    numTb.Foreground = brush;
                }
            }
        }
        AnnotationSecondaryEditor.DrawSelection(AnnotationSelectionCanvas, _selectedAnnotationElement);
    }

    private void OnAnnotationToolbarStrokeSizeChanged(double size)
    {
        if (_selectedAnnotationElement == null) return;

        if (_selectedAnnotationElement is Shape shape)
        {
            if (shape is Path path && path.Tag is ArrowInfo arrow)
            {
                arrow.StrokeSize = size;
                path.StrokeThickness = (arrow.ArrowStyle == 2 || arrow.ArrowStyle == 3) ? Math.Max(size * 1.6, size + 2.0) : size;
                path.Data = AnnotationSecondaryEditor.MakeArrowGeometry(arrow.Start, arrow.End, arrow.StrokeSize, arrow.ArrowStyle, arrow.IsFilled);
            }
            else
            {
                shape.StrokeThickness = size;
            }
        }
        else if (_selectedAnnotationElement is Border border)
        {
            double newMarkerSize = Math.Max(18, size * 5);
            double newRadius = newMarkerSize / 2.0;
            double oldRadius = border.Width / 2.0;
            double centerX = Canvas.GetLeft(border) + oldRadius;
            double centerY = Canvas.GetTop(border) + oldRadius;

            border.Width = newMarkerSize;
            border.Height = newMarkerSize;
            border.CornerRadius = new CornerRadius(newRadius);
            Canvas.SetLeft(border, centerX - newRadius);
            Canvas.SetTop(border, centerY - newRadius);

            if (border.Child is TextBlock numTb)
            {
                numTb.FontSize = Math.Max(9, newMarkerSize * 0.55);
            }
        }
        AnnotationSecondaryEditor.DrawSelection(AnnotationSelectionCanvas, _selectedAnnotationElement);
    }

    private void OnAnnotationToolbarSubToolActionTriggered(string action)
    {
        if (_selectedAnnotationElement == null) return;

        if (action == "FillChanged" && _selectedAnnotationElement is Shape shape)
        {
            var brush = new SolidColorBrush(AnnotationToolbar.CurrentColor);
            if (shape is Rectangle or Ellipse)
            {
                shape.Fill = AnnotationToolbar.IsFilled ? brush : Brushes.Transparent;
            }
            else if (shape is Path path && path.Tag is ArrowInfo arrow)
            {
                arrow.IsFilled = AnnotationToolbar.IsFilled;
                path.Fill = (arrow.ArrowStyle == 5 || arrow.ArrowStyle == 7 || arrow.ArrowStyle == 8 || arrow.IsFilled) ? brush : Brushes.Transparent;
                path.Data = AnnotationSecondaryEditor.MakeArrowGeometry(arrow.Start, arrow.End, arrow.StrokeSize, arrow.ArrowStyle, arrow.IsFilled);
            }
        }
        else if (action == "DashChanged" && _selectedAnnotationElement is Shape dashShape)
        {
            dashShape.StrokeDashArray = AnnotationToolbar.CurrentDashArray;
        }
        else if (action == "ArrowStyleChanged" && _selectedAnnotationElement is Path arrowPath && arrowPath.Tag is ArrowInfo arrow)
        {
            arrow.ArrowStyle = AnnotationToolbar.ArrowStyle;
            arrowPath.StrokeThickness = (arrow.ArrowStyle == 2 || arrow.ArrowStyle == 3) ? Math.Max(arrow.StrokeSize * 1.6, arrow.StrokeSize + 2.0) : arrow.StrokeSize;
            var brush = new SolidColorBrush(AnnotationToolbar.CurrentColor);
            arrowPath.Fill = (arrow.ArrowStyle == 5 || arrow.ArrowStyle == 7 || arrow.ArrowStyle == 8 || arrow.IsFilled) ? brush : Brushes.Transparent;
            arrowPath.Data = AnnotationSecondaryEditor.MakeArrowGeometry(arrow.Start, arrow.End, arrow.StrokeSize, arrow.ArrowStyle, arrow.IsFilled);
        }
        else if (_selectedAnnotationElement is TextBox tb)
        {
            if (action == "BoldChanged")
            {
                tb.FontWeight = AnnotationToolbar.IsBold ? FontWeights.Bold : FontWeights.Normal;
            }
            else if (action == "ItalicChanged")
            {
                tb.FontStyle = AnnotationToolbar.IsItalic ? FontStyles.Italic : FontStyles.Normal;
            }
            else if (action == "BorderChanged")
            {
                tb.Background = AnnotationToolbar.HasTextBorder ? new SolidColorBrush(Color.FromArgb(160, 0, 0, 0)) : Brushes.Transparent;
                tb.BorderBrush = AnnotationToolbar.HasTextBorder ? new SolidColorBrush(AnnotationToolbar.CurrentColor) : Brushes.Transparent;
            }
            else if (action == "FontSizeChanged")
            {
                tb.FontSize = AnnotationToolbar.FontSizeValue;
            }
            else if (action == "FontFamilyChanged")
            {
                tb.FontFamily = new FontFamily(AnnotationToolbar.CurrentFontFamily);
            }
        }
        else if (action.StartsWith("NumberStyle") && _selectedAnnotationElement is Border border)
        {
            var brush = new SolidColorBrush(AnnotationToolbar.CurrentColor);
            if (AnnotationToolbar.NumberStyle == 0)
            {
                border.Background = brush;
                border.BorderBrush = Brushes.Transparent;
                border.BorderThickness = new Thickness(0);
                if (border.Child is TextBlock ntb)
                    ntb.Foreground = Brushes.White;
            }
            else
            {
                border.Background = Brushes.Transparent;
                border.BorderBrush = brush;
                border.BorderThickness = new Thickness(2);
                if (border.Child is TextBlock ntb)
                    ntb.Foreground = brush;
            }
        }

        AnnotationSecondaryEditor.DrawSelection(AnnotationSelectionCanvas, _selectedAnnotationElement);
    }

    private async void OnOcrClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var document = await OcrService.RecognizeDocumentAsync(_bitmap);
            if (string.IsNullOrWhiteSpace(document.FullText))
            {
                throw new WindowsOcrException("当前贴图中没有识别到文字。");
            }
            var ocrWindow = new OcrWorkspaceWindow(
                _bitmap,
                document,
                _translationService,
                _configuration)
            {
                Owner = this,
                Left = Left + 20,
                Top = Top + 20
            };
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
            var document = await OcrService.RecognizeDocumentAsync(_bitmap);
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

    private async Task RecognizeTextInPinAsync()
    {
        try
        {
            _ocrDocument = await OcrService.RecognizeDocumentAsync(_bitmap);
        }
        catch
        {
            // Background OCR for pin selection is non-blocking
        }
    }

    private LayoutTextWord? GetWordAt(Point pt)
    {
        if (_ocrDocument == null || _bitmap.PixelWidth <= 0 || _bitmap.PixelHeight <= 0)
            return null;

        double scaleX = PinImage.ActualWidth > 0 ? PinImage.ActualWidth / _bitmap.PixelWidth : 1;
        double scaleY = PinImage.ActualHeight > 0 ? PinImage.ActualHeight / _bitmap.PixelHeight : 1;

        foreach (var line in _ocrDocument.Lines)
        {
            if (line.Words.Count > 0)
            {
                foreach (var word in line.Words)
                {
                    var rect = new Rect(word.X * scaleX, word.Y * scaleY, word.Width * scaleX, word.Height * scaleY);
                    if (rect.Contains(pt))
                        return word;
                }
            }
            else
            {
                var rect = new Rect(line.X * scaleX, line.Y * scaleY, line.Width * scaleX, line.Height * scaleY);
                if (rect.Contains(pt))
                {
                    return new LayoutTextWord
                    {
                        Text = line.Text,
                        X = line.X,
                        Y = line.Y,
                        Width = line.Width,
                        Height = line.Height
                    };
                }
            }
        }

        return null;
    }

    private void UpdateTextSelection()
    {
        AnnotationSelectionCanvas.Children.Clear();
        _selectedWords.Clear();
        if (_ocrDocument == null || _bitmap.PixelWidth <= 0 || _bitmap.PixelHeight <= 0)
            return;

        double scaleX = PinImage.ActualWidth > 0 ? PinImage.ActualWidth / _bitmap.PixelWidth : 1;
        double scaleY = PinImage.ActualHeight > 0 ? PinImage.ActualHeight / _bitmap.PixelHeight : 1;

        foreach (var line in _ocrDocument.Lines)
        {
            var words = line.Words.Count > 0
                ? line.Words
                : [new LayoutTextWord { Text = line.Text, X = line.X, Y = line.Y, Width = line.Width, Height = line.Height }];

            foreach (var word in words)
            {
                var wordRect = new Rect(word.X * scaleX, word.Y * scaleY, word.Width * scaleX, word.Height * scaleY);
                if (_textSelectionRect.IntersectsWith(wordRect))
                {
                    _selectedWords.Add(word);
                    var highlight = new Rectangle
                    {
                        Width = Math.Max(2, wordRect.Width),
                        Height = Math.Max(2, wordRect.Height),
                        Fill = new SolidColorBrush(Color.FromArgb(60, 10, 132, 255)),
                        Stroke = new SolidColorBrush(Color.FromArgb(160, 10, 132, 255)),
                        StrokeThickness = 1
                    };
                    Canvas.SetLeft(highlight, wordRect.X);
                    Canvas.SetTop(highlight, wordRect.Y);
                    AnnotationSelectionCanvas.Children.Add(highlight);
                }
            }
        }
    }

    private void ClearTextSelection()
    {
        _isTextSelecting = false;
        _textSelectionRect = Rect.Empty;
        _selectedWords.Clear();
        AnnotationSelectionCanvas.Children.Clear();
        TextCapsuleBar.Visibility = Visibility.Collapsed;
    }

    private void ShowTextCapsuleBar()
    {
        if (_selectedWords.Count == 0) return;
        double scaleX = _bitmap.PixelWidth > 0 ? PinImage.ActualWidth / _bitmap.PixelWidth : 1;
        double scaleY = _bitmap.PixelHeight > 0 ? PinImage.ActualHeight / _bitmap.PixelHeight : 1;

        double minX = _selectedWords.Min(w => w.X * scaleX);
        double minY = _selectedWords.Min(w => w.Y * scaleY);
        double maxX = _selectedWords.Max(w => (w.X + w.Width) * scaleX);

        double capsuleWidth = 320;
        double left = Math.Clamp((minX + maxX) / 2 - capsuleWidth / 2, 4, Math.Max(4, PinSurface.ActualWidth - capsuleWidth - 4));
        double top = Math.Max(4, minY - 32);

        TextCapsuleBar.Margin = new Thickness(left, top, 0, 0);
        TextCapsuleBar.Visibility = Visibility.Visible;
    }

    private void OnCapsuleCopyClick(object sender, RoutedEventArgs e)
    {
        if (_selectedWords.Count > 0)
        {
            var text = string.Join(" ", _selectedWords.Select(w => w.Text));
            Clipboard.SetText(TextFormattingService.ApplyPanguSpacing(text));
        }
        ClearTextSelection();
    }

    private void OnCapsuleHighlightClick(object sender, RoutedEventArgs e)
    {
        double scaleX = _bitmap.PixelWidth > 0 ? PinImage.ActualWidth / _bitmap.PixelWidth : 1;
        double scaleY = _bitmap.PixelHeight > 0 ? PinImage.ActualHeight / _bitmap.PixelHeight : 1;
        foreach (var word in _selectedWords)
        {
            var rect = new Rectangle
            {
                Width = Math.Max(2, word.Width * scaleX),
                Height = Math.Max(2, word.Height * scaleY),
                Fill = new SolidColorBrush(Color.FromArgb(0x60, 0xFD, 0xE0, 0x47))
            };
            Canvas.SetLeft(rect, word.X * scaleX);
            Canvas.SetTop(rect, word.Y * scaleY);
            AnnotationCanvas.Children.Add(rect);
            _annotationHistory.Add(rect);
        }
        ClearTextSelection();
    }

    private void OnCapsuleWavyClick(object sender, RoutedEventArgs e)
    {
        double scaleX = _bitmap.PixelWidth > 0 ? PinImage.ActualWidth / _bitmap.PixelWidth : 1;
        double scaleY = _bitmap.PixelHeight > 0 ? PinImage.ActualHeight / _bitmap.PixelHeight : 1;
        var lines = _selectedWords.GroupBy(w => Math.Round(w.Y * scaleY / 10)).ToList();
        foreach (var lineGroup in lines)
        {
            double left = lineGroup.Min(w => w.X * scaleX);
            double right = lineGroup.Max(w => (w.X + w.Width) * scaleX);
            double bottom = lineGroup.Max(w => (w.Y + w.Height) * scaleY);

            var path = CreateWavyPath(left, right, bottom, Color.FromRgb(0xEF, 0x44, 0x44));
            AnnotationCanvas.Children.Add(path);
            _annotationHistory.Add(path);
        }
        ClearTextSelection();
    }

    private void OnCapsuleLineClick(object sender, RoutedEventArgs e)
    {
        double scaleX = _bitmap.PixelWidth > 0 ? PinImage.ActualWidth / _bitmap.PixelWidth : 1;
        double scaleY = _bitmap.PixelHeight > 0 ? PinImage.ActualHeight / _bitmap.PixelHeight : 1;
        var lines = _selectedWords.GroupBy(w => Math.Round(w.Y * scaleY / 10)).ToList();
        foreach (var lineGroup in lines)
        {
            double left = lineGroup.Min(w => w.X * scaleX);
            double right = lineGroup.Max(w => (w.X + w.Width) * scaleX);
            double bottom = lineGroup.Max(w => (w.Y + w.Height) * scaleY);

            var line = new Line
            {
                X1 = left,
                Y1 = bottom,
                X2 = right,
                Y2 = bottom,
                Stroke = new SolidColorBrush(Color.FromRgb(0x3B, 0x82, 0xF6)),
                StrokeThickness = 2
            };
            AnnotationCanvas.Children.Add(line);
            _annotationHistory.Add(line);
        }
        ClearTextSelection();
    }

    private void OnCapsuleStrikethroughClick(object sender, RoutedEventArgs e)
    {
        double scaleX = _bitmap.PixelWidth > 0 ? PinImage.ActualWidth / _bitmap.PixelWidth : 1;
        double scaleY = _bitmap.PixelHeight > 0 ? PinImage.ActualHeight / _bitmap.PixelHeight : 1;
        var lines = _selectedWords.GroupBy(w => Math.Round(w.Y * scaleY / 10)).ToList();
        foreach (var lineGroup in lines)
        {
            double left = lineGroup.Min(w => w.X * scaleX);
            double right = lineGroup.Max(w => (w.X + w.Width) * scaleX);
            double midY = lineGroup.Average(w => (w.Y + w.Height / 2) * scaleY);

            var line = new Line
            {
                X1 = left,
                Y1 = midY,
                X2 = right,
                Y2 = midY,
                Stroke = new SolidColorBrush(Color.FromRgb(0x9C, 0xA3, 0xAF)),
                StrokeThickness = 2
            };
            AnnotationCanvas.Children.Add(line);
            _annotationHistory.Add(line);
        }
        ClearTextSelection();
    }

    private async void OnCapsuleTranslateClick(object sender, RoutedEventArgs e)
    {
        if (_selectedWords.Count == 0 || _translationService == null || _configuration == null)
            return;

        var text = string.Join(" ", _selectedWords.Select(w => w.Text));
        ClearTextSelection();

        try
        {
            var result = await _translationService.TranslateAsync(
                text,
                _configuration.TargetLanguage,
                _configuration.SourceLanguage,
                _configuration);

            var window = new ScreenTranslationWindow(
                text,
                result.Text,
                _bitmap,
                _translationService,
                _configuration)
            {
                Left = Left + 20,
                Top = Top + 20
            };
            window.Show();
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "翻译失败", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private static Path CreateWavyPath(double left, double right, double y, Color color)
    {
        var geometry = new StreamGeometry();
        using (var ctx = geometry.Open())
        {
            ctx.BeginFigure(new Point(left, y), false, false);
            double step = 6;
            double amp = 2;
            bool up = true;
            for (double x = left; x < right; x += step)
            {
                double nextX = Math.Min(right, x + step);
                double midX = (x + nextX) / 2;
                double targetY = up ? y - amp : y + amp;
                ctx.QuadraticBezierTo(new Point(midX, targetY), new Point(nextX, y), true, false);
                up = !up;
            }
        }
        geometry.Freeze();
        return new Path
        {
            Data = geometry,
            Stroke = new SolidColorBrush(color),
            StrokeThickness = 1.5
        };
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
