using System;
using System.Collections.Generic;
using System.IO;
using System.Media;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Microsoft.Win32;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.Platform.Capture;
using Polyglance.Platform.Dpi;
using Polyglance.Platform.Interop;
using Polyglance.Platform.Ocr;

namespace Polyglance.UI.Views;

public partial class ScreenSelectionWindow : Window
{
    private enum SelectionPhase
    {
        Ready,
        DraggingNew,
        Selected,
        Moving,
        Resizing,
        Expanding
    }

    private readonly BitmapSource _fullScreenBitmap;
    private readonly Rect _screenBounds;
    private readonly TranslationService _translationService;
    private readonly AppConfiguration _config;
    private readonly ScreenshotCaptureIntent _captureIntent;
    private readonly Action<string> _colorClipboardWriter;

    private SelectionPhase _phase = SelectionPhase.Ready;
    private NativeSelectionEditTarget _currentEditTarget = NativeSelectionEditTarget.None;
    private Point _dragStart;
    private Rect _initialSelection = Rect.Empty;
    private Rect _selectionRect = Rect.Empty;
    private Rect _hoveredWindowRect = Rect.Empty;
    private string _activeTool = "None";

    private readonly List<UIElement> _annotationHistory = new();
    private readonly List<UIElement> _redoStack = new();
    private Shape? _currentDrawingShape;
    private Point _drawingStart;

    public ScreenSelectionWindow(
        BitmapSource fullScreenBitmap,
        Rect screenBounds,
        TranslationService translationService,
        AppConfiguration config,
        ScreenshotCaptureIntent captureIntent = ScreenshotCaptureIntent.Standard)
        : this(
            fullScreenBitmap,
            screenBounds,
            translationService,
            config,
            captureIntent,
            Clipboard.SetText)
    {
    }

    internal ScreenSelectionWindow(
        BitmapSource fullScreenBitmap,
        Rect screenBounds,
        TranslationService translationService,
        AppConfiguration config,
        ScreenshotCaptureIntent captureIntent,
        Action<string> colorClipboardWriter)
    {
        InitializeComponent();

        _fullScreenBitmap = fullScreenBitmap;
        _screenBounds = screenBounds;
        _translationService = translationService;
        _config = config;
        _captureIntent = captureIntent;
        _colorClipboardWriter = colorClipboardWriter;

        // screenBounds comes from GetSystemMetrics and is therefore physical
        // pixels, while Left/Top/Width/Height are DIPs. Assigning it directly
        // oversizes the overlay on any scaled display, so seed the values for the
        // first layout pass and then place the window by physical pixels once it
        // has a handle.
        Left = screenBounds.X;
        Top = screenBounds.Y;
        Width = screenBounds.Width;
        Height = screenBounds.Height;
        SourceInitialized += (_, _) => CoverCapturedArea();

        BackgroundImage.Source = fullScreenBitmap;

        Toolbar.ToolSelected += OnToolSelected;
        Toolbar.ActionTriggered += OnActionTriggered;

        Cursor = Cursors.Cross;
        UpdateMask(Rect.Empty);
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        Point pt = e.GetPosition(this);

        if (Toolbar.IsMouseOver)
            return;

        // 1. 右键处理 (对齐 macOS: 逐级回退取消)
        if (e.RightButton == MouseButtonState.Pressed)
        {
            HandleRightClick();
            return;
        }

        // 2. 左键处理
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            if (_activeTool != "None" && !_selectionRect.IsEmpty && _selectionRect.Contains(pt))
            {
                // 标注模式：在选区内开始绘制
                _drawingStart = pt;
                StartAnnotationDrawing(pt);
                return;
            }

            if (_phase == SelectionPhase.Selected && !_selectionRect.IsEmpty)
            {
                // 双击选区内：直接复制到剪贴板并退出 (macOS 极速模式)
                if (e.ClickCount >= 2 && _selectionRect.Contains(pt))
                {
                    OnActionTriggered("Copy");
                    return;
                }

                var target = DetectEditTarget(pt, _selectionRect, handleTolerance: 8);
                _currentEditTarget = target;
                _dragStart = pt;
                _initialSelection = _selectionRect;
                Toolbar.Visibility = Visibility.Collapsed;

                switch (target)
                {
                    case NativeSelectionEditTarget.Move:
                        _phase = SelectionPhase.Moving;
                        Cursor = Cursors.SizeAll;
                        break;

                    case NativeSelectionEditTarget.Expand:
                        // 选区外部点击：按照 macOS 逻辑，扩大选区至包含当前鼠标点
                        _phase = SelectionPhase.Expanding;
                        _selectionRect = ExpandSelectionToward(_initialSelection, pt);
                        UpdateSelectionDisplay();
                        break;

                    default:
                        // 拖拽控制手柄缩放
                        _phase = SelectionPhase.Resizing;
                        break;
                }
                return;
            }

            if (_phase == SelectionPhase.Ready)
            {
                // 开始初次鼠标划选
                _phase = SelectionPhase.DraggingNew;
                _dragStart = pt;
                _selectionRect = new Rect(pt, new Size(0, 0));
                Toolbar.Visibility = Visibility.Collapsed;
                CandidateBorder.Visibility = Visibility.Collapsed;
                ShowMagnifier(pt);
                return;
            }
        }
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        Point pt = e.GetPosition(this);

        if (_currentDrawingShape != null)
        {
            UpdateAnnotationDrawing(pt);
            return;
        }

        switch (_phase)
        {
            case SelectionPhase.DraggingNew:
                _selectionRect = FromNativeRect(SelectionGeometryService.SelectionRect(
                    ToNativePoint(_dragStart),
                    ToNativePoint(pt),
                    SelectionBounds()));
                UpdateSelectionDisplay();
                ShowMagnifier(pt);
                break;

            // Editing a confirmed selection keeps the magnifier hidden: macOS runs
            // these edits while its capture phase is still .selected, and its
            // updateMagnifier hides on that phase.
            case SelectionPhase.Moving:
                _selectionRect = ApplySharedEdit(_initialSelection, _currentEditTarget, pt);
                UpdateSelectionDisplay();
                break;

            case SelectionPhase.Resizing:
                _selectionRect = ApplyResize(_initialSelection, _currentEditTarget, pt);
                UpdateSelectionDisplay();
                break;

            case SelectionPhase.Expanding:
                _selectionRect = ExpandSelectionToward(_initialSelection, pt);
                UpdateSelectionDisplay();
                break;

            case SelectionPhase.Selected:
                UpdateHoverCursor(pt);
                break;

            case SelectionPhase.Ready:
                ShowMagnifier(pt);
                break;
        }
    }

    /// <summary>
    /// Keeps the magnifier under the pointer while picking or adjusting a
    /// selection, matching the macOS session which refreshes it on move, press,
    /// drag and release so edge pixels stay readable mid-drag.
    /// </summary>
    private void ShowMagnifier(Point pt)
    {
        if (Magnifier.Visibility != Visibility.Visible)
            Magnifier.Visibility = Visibility.Visible;

        Size viewSize = OverlayViewSize();
        Canvas.SetLeft(Magnifier, Math.Min(viewSize.Width - Magnifier.Width - 12, pt.X + 16));
        Canvas.SetTop(Magnifier, Math.Min(viewSize.Height - Magnifier.Height - 12, pt.Y + 16));

        var (pixelX, pixelY) = CaptureRegionGeometry.ToBitmapPoint(
            pt,
            viewSize,
            _fullScreenBitmap.PixelWidth,
            _fullScreenBitmap.PixelHeight);
        Magnifier.Update(_fullScreenBitmap, pixelX, pixelY);
    }

    private void HideMagnifier()
    {
        Magnifier.Visibility = Visibility.Collapsed;
    }

    /// <summary>
    /// Copies the sampled colour in the format currently displayed. The clipboard
    /// can be locked by another process, so a failure beeps instead of throwing,
    /// matching the macOS session's NSSound.beep fallback.
    /// </summary>
    private void CopyCurrentColor()
    {
        if (Magnifier.CurrentSample is not { } sample)
        {
            SystemSounds.Beep.Play();
            return;
        }

        try
        {
            string copied = sample.Text(Magnifier.DisplayFormat);
            _colorClipboardWriter(copied);
            Magnifier.ShowCopyConfirmation(copied);
        }
        catch (ExternalException)
        {
            SystemSounds.Beep.Play();
        }
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_currentDrawingShape != null)
        {
            _annotationHistory.Add(_currentDrawingShape);
            _redoStack.Clear();
            _currentDrawingShape = null;
            UpdateUndoRedoButtons();
            return;
        }

        if (_phase == SelectionPhase.DraggingNew ||
            _phase == SelectionPhase.Moving ||
            _phase == SelectionPhase.Resizing ||
            _phase == SelectionPhase.Expanding)
        {
            HideMagnifier();

            if (_selectionRect.Width > 6 && _selectionRect.Height > 6)
            {
                _phase = SelectionPhase.Selected;
                _currentEditTarget = NativeSelectionEditTarget.None;
                var preferredAction = _captureIntent.ActionAfterSelection();
                if (preferredAction == ScreenshotSelectionAction.None)
                {
                    PositionToolbar();
                }
                else
                {
                    Toolbar.Visibility = Visibility.Collapsed;
                    OnActionTriggered(preferredAction switch
                    {
                        ScreenshotSelectionAction.ScreenTranslation => "ScreenTranslation",
                        ScreenshotSelectionAction.LongScreenshot => "LongScreenshot",
                        ScreenshotSelectionAction.ScreenRecording => "ScreenRecording",
                        _ => throw new InvalidOperationException("Unsupported screenshot selection action")
                    });
                }
            }
            else
            {
                ClearSelection();
            }
        }
    }

    private void HandleRightClick()
    {
        if (_activeTool != "None")
        {
            _activeTool = "None";
            Cursor = Cursors.Cross;
            return;
        }

        if (_phase == SelectionPhase.Selected || !_selectionRect.IsEmpty)
        {
            ClearSelection();
        }
        else
        {
            Close();
        }
    }

    private void ClearSelection()
    {
        _phase = SelectionPhase.Ready;
        _currentEditTarget = NativeSelectionEditTarget.None;
        _selectionRect = Rect.Empty;
        SelectionBorder.Visibility = Visibility.Collapsed;
        HandlesCanvas.Visibility = Visibility.Collapsed;
        SizeBadge.Visibility = Visibility.Collapsed;
        Toolbar.Visibility = Visibility.Collapsed;
        AnnotationCanvas.Children.Clear();
        _annotationHistory.Clear();
        _redoStack.Clear();
        UpdateMask(Rect.Empty);
        Cursor = Cursors.Cross;
    }

    // 检测鼠标在选区上的编辑目标 (手柄、内部平移、或外部扩展)
    private NativeSelectionEditTarget DetectEditTarget(Point pt, Rect sel, double handleTolerance = 8)
    {
        if (sel.IsEmpty || sel.Width <= 0 || sel.Height <= 0)
            return NativeSelectionEditTarget.None;

        return SelectionGeometryService.EditTarget(
            ToNativePoint(pt),
            ToNativeRect(sel),
            handleTolerance);
    }

    // 选区朝向外部点扩大 (对齐 macOS capture-core expanded_selection_toward)
    private Rect ExpandSelectionToward(Rect sel, Point pt)
    {
        return FromNativeRect(SelectionGeometryService.ExpandedToward(
            ToNativeRect(sel),
            ToNativePoint(pt),
            SelectionBounds()));
    }

    // 缩放手柄移动应用
    private Rect ApplyResize(Rect orig, NativeSelectionEditTarget target, Point pt)
    {
        return ApplySharedEdit(orig, target, pt);
    }

    private Rect ApplySharedEdit(Rect original, NativeSelectionEditTarget target, Point current)
    {
        return FromNativeRect(SelectionGeometryService.Edited(
            ToNativeRect(original),
            ToNativePoint(_dragStart),
            ToNativePoint(current),
            target,
            SelectionBounds(),
            minimumSide: 4));
    }

    private NativeRect SelectionBounds()
    {
        Size view = OverlayViewSize();
        return new(0, 0, view.Width, view.Height);
    }

    private static NativePoint ToNativePoint(Point point) => new(point.X, point.Y);

    private static NativeRect ToNativeRect(Rect rect) =>
        new(rect.X, rect.Y, rect.Width, rect.Height);

    private static Rect FromNativeRect(NativeRect rect) =>
        new(rect.X, rect.Y, rect.Width, rect.Height);

    private void UpdateHoverCursor(Point pt)
    {
        if (_activeTool != "None")
        {
            Cursor = Cursors.Pen;
            return;
        }

        var target = DetectEditTarget(pt, _selectionRect, handleTolerance: 8);
        switch (target)
        {
            case NativeSelectionEditTarget.TopLeft:
            case NativeSelectionEditTarget.BottomRight:
                Cursor = Cursors.SizeNWSE;
                break;
            case NativeSelectionEditTarget.TopRight:
            case NativeSelectionEditTarget.BottomLeft:
                Cursor = Cursors.SizeNESW;
                break;
            case NativeSelectionEditTarget.Top:
            case NativeSelectionEditTarget.Bottom:
                Cursor = Cursors.SizeNS;
                break;
            case NativeSelectionEditTarget.Left:
            case NativeSelectionEditTarget.Right:
                Cursor = Cursors.SizeWE;
                break;
            case NativeSelectionEditTarget.Move:
                Cursor = Cursors.SizeAll;
                break;
            case NativeSelectionEditTarget.Expand:
            default:
                Cursor = Cursors.Cross;
                break;
        }
    }

    private void UpdateSelectionDisplay()
    {
        SelectionBorder.Visibility = Visibility.Visible;
        HandlesCanvas.Visibility = Visibility.Visible;
        SizeBadge.Visibility = Visibility.Visible;

        Canvas.SetLeft(SelectionBorder, _selectionRect.X);
        Canvas.SetTop(SelectionBorder, _selectionRect.Y);
        SelectionBorder.Width = _selectionRect.Width;
        SelectionBorder.Height = _selectionRect.Height;

        // 定位8个控制手柄
        double l = _selectionRect.Left;
        double r = _selectionRect.Right;
        double t = _selectionRect.Top;
        double b = _selectionRect.Bottom;
        double midX = (l + r) / 2;
        double midY = (t + b) / 2;

        Canvas.SetLeft(HandleTL, l - 4); Canvas.SetTop(HandleTL, t - 4);
        Canvas.SetLeft(HandleT, midX - 4); Canvas.SetTop(HandleT, t - 4);
        Canvas.SetLeft(HandleTR, r - 4); Canvas.SetTop(HandleTR, t - 4);
        Canvas.SetLeft(HandleR, r - 4); Canvas.SetTop(HandleR, midY - 4);
        Canvas.SetLeft(HandleBR, r - 4); Canvas.SetTop(HandleBR, b - 4);
        Canvas.SetLeft(HandleB, midX - 4); Canvas.SetTop(HandleB, b - 4);
        Canvas.SetLeft(HandleBL, l - 4); Canvas.SetTop(HandleBL, b - 4);
        Canvas.SetLeft(HandleL, l - 4); Canvas.SetTop(HandleL, midY - 4);

        // Report the size of the image the user will actually get, matching the
        // macOS label which is driven by CaptureGeometry.outputPixelSize.
        Int32Rect outputRegion = SelectionBitmapRegion();
        TxtDimension.Text = $"{outputRegion.Width} × {outputRegion.Height} px";

        double badgeTop = _selectionRect.Top - 28;
        if (badgeTop < 6)
            badgeTop = _selectionRect.Top + 6;

        Canvas.SetLeft(SizeBadge, _selectionRect.Left + 4);
        Canvas.SetTop(SizeBadge, badgeTop);

        UpdateMask(_selectionRect);
    }

    private void UpdateMask(Rect hole)
    {
        Size view = OverlayViewSize();

        if (hole.IsEmpty || hole.Width <= 0 || hole.Height <= 0)
        {
            Canvas.SetLeft(MaskTop, 0);
            Canvas.SetTop(MaskTop, 0);
            MaskTop.Width = view.Width;
            MaskTop.Height = view.Height;

            MaskBottom.Width = 0;
            MaskLeft.Width = 0;
            MaskRight.Width = 0;
            return;
        }

        Canvas.SetLeft(MaskTop, 0);
        Canvas.SetTop(MaskTop, 0);
        MaskTop.Width = view.Width;
        MaskTop.Height = Math.Max(0, hole.Top);

        Canvas.SetLeft(MaskBottom, 0);
        Canvas.SetTop(MaskBottom, hole.Bottom);
        MaskBottom.Width = view.Width;
        MaskBottom.Height = Math.Max(0, view.Height - hole.Bottom);

        Canvas.SetLeft(MaskLeft, 0);
        Canvas.SetTop(MaskLeft, hole.Top);
        MaskLeft.Width = Math.Max(0, hole.Left);
        MaskLeft.Height = hole.Height;

        Canvas.SetLeft(MaskRight, hole.Right);
        Canvas.SetTop(MaskRight, hole.Top);
        MaskRight.Width = Math.Max(0, view.Width - hole.Right);
        MaskRight.Height = hole.Height;
    }

    private void PositionToolbar()
    {
        Toolbar.SetCompactLayout(OverlayViewSize().Width < 700);
        Toolbar.Visibility = Visibility.Visible;
        Toolbar.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        double toolbarWidth = Toolbar.DesiredSize.Width;
        double toolbarHeight = Toolbar.DesiredSize.Height;

        Size viewSize = OverlayViewSize();
        double maximumLeft = Math.Max(12, viewSize.Width - toolbarWidth - 12);
        double left = Math.Clamp(_selectionRect.Right - toolbarWidth, 12, maximumLeft);
        double top = _selectionRect.Bottom + 10;

        if (top + toolbarHeight > viewSize.Height - 12)
        {
            top = Math.Max(12, _selectionRect.Top - toolbarHeight - 10);
        }

        Canvas.SetLeft(Toolbar, left);
        Canvas.SetTop(Toolbar, top);
    }

    private void OnToolSelected(string tool)
    {
        _activeTool = tool;
    }

    private void UpdateUndoRedoButtons()
    {
        Toolbar.SetUndoRedoState(_annotationHistory.Count > 0, _redoStack.Count > 0);
    }

    private void StartAnnotationDrawing(Point pt)
    {
        var brush = new SolidColorBrush(Toolbar.CurrentColor);
        double strokeSize = Toolbar.CurrentStrokeSize;

        switch (_activeTool)
        {
            case "Rect":
                var rect = new Rectangle
                {
                    Stroke = brush,
                    StrokeThickness = strokeSize,
                    RadiusX = 3,
                    RadiusY = 3
                };
                Canvas.SetLeft(rect, pt.X);
                Canvas.SetTop(rect, pt.Y);
                AnnotationCanvas.Children.Add(rect);
                _currentDrawingShape = rect;
                break;

            case "Ellipse":
                var ellipse = new Ellipse
                {
                    Stroke = brush,
                    StrokeThickness = strokeSize
                };
                Canvas.SetLeft(ellipse, pt.X);
                Canvas.SetTop(ellipse, pt.Y);
                AnnotationCanvas.Children.Add(ellipse);
                _currentDrawingShape = ellipse;
                break;

            case "Pen":
                var polyline = new Polyline
                {
                    Stroke = brush,
                    StrokeThickness = strokeSize,
                    StrokeLineJoin = PenLineJoin.Round,
                    StrokeStartLineCap = PenLineCap.Round,
                    StrokeEndLineCap = PenLineCap.Round
                };
                polyline.Points.Add(pt);
                AnnotationCanvas.Children.Add(polyline);
                _currentDrawingShape = polyline;
                break;

            case "Arrow":
                var arrowLine = new Line
                {
                    X1 = pt.X,
                    Y1 = pt.Y,
                    X2 = pt.X,
                    Y2 = pt.Y,
                    Stroke = brush,
                    StrokeThickness = strokeSize,
                    StrokeEndLineCap = PenLineCap.Round
                };
                AnnotationCanvas.Children.Add(arrowLine);
                _currentDrawingShape = arrowLine;
                break;

            case "Text":
                var tb = new System.Windows.Controls.TextBox
                {
                    Background = Brushes.Transparent,
                    BorderBrush = brush,
                    BorderThickness = new Thickness(1),
                    Foreground = brush,
                    FontSize = 16,
                    FontWeight = FontWeights.Bold,
                    AcceptsReturn = true,
                    MinWidth = 60,
                    CaretBrush = brush
                };
                Canvas.SetLeft(tb, pt.X);
                Canvas.SetTop(tb, pt.Y);
                AnnotationCanvas.Children.Add(tb);
                _annotationHistory.Add(tb);
                UpdateUndoRedoButtons();

                tb.Loaded += (s, ev) => tb.Focus();
                tb.LostFocus += (s, ev) =>
                {
                    if (string.IsNullOrWhiteSpace(tb.Text))
                    {
                        AnnotationCanvas.Children.Remove(tb);
                        _annotationHistory.Remove(tb);
                        UpdateUndoRedoButtons();
                    }
                    else
                    {
                        tb.BorderThickness = new Thickness(0);
                        tb.IsReadOnly = true;
                    }
                };
                break;

            case "Mosaic":
                var mosaicRect = new Rectangle
                {
                    Fill = new SolidColorBrush(Color.FromArgb(140, 120, 120, 120)),
                    Stroke = Brushes.Transparent,
                    Width = 16,
                    Height = 16,
                    RadiusX = 2,
                    RadiusY = 2
                };
                Canvas.SetLeft(mosaicRect, pt.X - 8);
                Canvas.SetTop(mosaicRect, pt.Y - 8);
                AnnotationCanvas.Children.Add(mosaicRect);
                _annotationHistory.Add(mosaicRect);
                UpdateUndoRedoButtons();
                break;
        }
    }

    private void UpdateAnnotationDrawing(Point pt)
    {
        double curX = Math.Clamp(pt.X, _selectionRect.Left, _selectionRect.Right);
        double curY = Math.Clamp(pt.Y, _selectionRect.Top, _selectionRect.Bottom);

        if (_currentDrawingShape is Rectangle rect)
        {
            double x = Math.Min(_drawingStart.X, curX);
            double y = Math.Min(_drawingStart.Y, curY);
            double w = Math.Abs(curX - _drawingStart.X);
            double h = Math.Abs(curY - _drawingStart.Y);
            Canvas.SetLeft(rect, x);
            Canvas.SetTop(rect, y);
            rect.Width = w;
            rect.Height = h;
        }
        else if (_currentDrawingShape is Ellipse ellipse)
        {
            double x = Math.Min(_drawingStart.X, curX);
            double y = Math.Min(_drawingStart.Y, curY);
            double w = Math.Abs(curX - _drawingStart.X);
            double h = Math.Abs(curY - _drawingStart.Y);
            Canvas.SetLeft(ellipse, x);
            Canvas.SetTop(ellipse, y);
            ellipse.Width = w;
            ellipse.Height = h;
        }
        else if (_currentDrawingShape is Polyline polyline)
        {
            polyline.Points.Add(new Point(curX, curY));
        }
        else if (_currentDrawingShape is Line line)
        {
            line.X2 = curX;
            line.Y2 = curY;
        }
        else if (_activeTool == "Mosaic")
        {
            var mosaicRect = new Rectangle
            {
                Fill = new SolidColorBrush(Color.FromArgb(140, 120, 120, 120)),
                Stroke = Brushes.Transparent,
                Width = 16,
                Height = 16,
                RadiusX = 2,
                RadiusY = 2
            };
            Canvas.SetLeft(mosaicRect, curX - 8);
            Canvas.SetTop(mosaicRect, curY - 8);
            AnnotationCanvas.Children.Add(mosaicRect);
            _annotationHistory.Add(mosaicRect);
            UpdateUndoRedoButtons();
        }
    }

    private async void OnActionTriggered(string action)
    {
        var cropped = GetRenderedCroppedBitmap();
        if (cropped == null) return;

        switch (action)
        {
            case "Undo":
                if (_annotationHistory.Count > 0)
                {
                    var last = _annotationHistory[^1];
                    _annotationHistory.RemoveAt(_annotationHistory.Count - 1);
                    _redoStack.Add(last);
                    AnnotationCanvas.Children.Remove(last);
                    UpdateUndoRedoButtons();
                }
                break;

            case "Redo":
                if (_redoStack.Count > 0)
                {
                    var last = _redoStack[^1];
                    _redoStack.RemoveAt(_redoStack.Count - 1);
                    _annotationHistory.Add(last);
                    AnnotationCanvas.Children.Add(last);
                    UpdateUndoRedoButtons();
                }
                break;

            case "Copy":
                Clipboard.SetImage(cropped);
                Close();
                break;

            case "Pin":
                var pinWin = new PinWindow(cropped, _translationService, _config);
                pinWin.Left = Left + _selectionRect.X;
                pinWin.Top = Top + _selectionRect.Y;
                pinWin.Show();
                Close();
                break;

            case "Save":
                var dlg = new SaveFileDialog
                {
                    Filter = "PNG Image (*.png)|*.png|JPEG Image (*.jpg)|*.jpg",
                    FileName = $"Screenshot_{DateTime.Now:yyyyMMdd_HHmmss}.png"
                };
                if (dlg.ShowDialog() == true)
                {
                    var encoder = new PngBitmapEncoder();
                    encoder.Frames.Add(BitmapFrame.Create(cropped));
                    using var stream = File.Create(dlg.FileName);
                    encoder.Save(stream);
                }
                Close();
                break;

            case "Cancel":
                Close();
                break;

            case "LongScreenshot":
                var longWin = new LongScreenshotSessionWindow(
                    _fullScreenBitmap,
                    _screenBounds,
                    _selectionRect,
                    _translationService,
                    _config);
                longWin.Show();
                Close();
                break;

            case "ScreenRecording":
                var recordWin = new ScreenRecordingWindow(_screenBounds, _selectionRect);
                recordWin.Show();
                Close();
                break;

            case "OCR":
                try
                {
                    var document = await WindowsMediaOcr.RecognizeDocumentAsync(cropped);
                    if (string.IsNullOrWhiteSpace(document.FullText))
                    {
                        throw new WindowsOcrException("当前截图中没有识别到文字。");
                    }
                    var ocrWindow = new OcrSelectionWindow(
                        cropped,
                        document,
                        _translationService,
                        _config,
                        SelectedScreenFrame());
                    ocrWindow.Show();
                    ocrWindow.Activate();
                    Close();
                }
                catch (Exception error)
                {
                    ShowCaptureError("OCR 识别失败", error);
                }
                break;

            case "OCRTranslate":
                try
                {
                    var document = await WindowsMediaOcr.RecognizeDocumentAsync(cropped);
                    if (string.IsNullOrWhiteSpace(document.FullText))
                    {
                        throw new WindowsOcrException("当前截图中没有识别到文字。");
                    }
                    var result = await _translationService.TranslateAsync(
                        document.FullText,
                        _config.TargetLanguage,
                        _config.SourceLanguage,
                        _config);
                    var resultWindow = new ScreenTranslationWindow(
                        document.FullText,
                        result.Text,
                        cropped,
                        _translationService,
                        _config)
                    {
                        Left = SelectedScreenFrame().X,
                        Top = SelectedScreenFrame().Y
                    };
                    resultWindow.Show();
                    resultWindow.Activate();
                    Close();
                }
                catch (Exception error)
                {
                    ShowCaptureError("OCR 翻译失败", error);
                }
                break;

            case "ScreenTranslation":
                try
                {
                    var document = await WindowsMediaOcr.RecognizeDocumentAsync(cropped);
                    if (document.Lines.Count == 0)
                    {
                        throw new WindowsOcrException("当前截图中没有识别到文字。");
                    }
                    var inPlaceWin = new InPlaceTranslationOverlayWindow(
                        cropped,
                        SelectedScreenFrame(),
                        [.. document.Lines],
                        _translationService,
                        _config
                    );
                    inPlaceWin.Show();
                    inPlaceWin.Activate();
                    Close();
                }
                catch (Exception error)
                {
                    ShowCaptureError("截图翻译失败", error);
                }
                break;
        }
    }

    private Rect SelectedScreenFrame() => new(
        Left + _selectionRect.X,
        Top + _selectionRect.Y,
        _selectionRect.Width,
        _selectionRect.Height);

    private static void ShowCaptureError(string title, Exception error)
    {
        MessageBox.Show(error.Message, title, MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    private BitmapSource? GetRenderedCroppedBitmap()
    {
        Int32Rect region = SelectionBitmapRegion();
        if (region.IsEmpty)
            return null;

        var baseCropped = ScreenCapture.Crop(_fullScreenBitmap, region);

        if (_annotationHistory.Count == 0)
            return baseCropped;

        // Annotations were drawn in overlay DIPs, so compositing them onto the
        // physical-pixel crop needs both the selection offset and the DIP-to-pixel
        // scale. Without the scale they would land at the wrong size and position
        // on any display that is not at 100%.
        Size viewSize = OverlayViewSize();
        var rtb = new RenderTargetBitmap(region.Width, region.Height, 96, 96, PixelFormats.Pbgra32);
        double scaleX = region.Width / Math.Max(_selectionRect.Width, 0.0001);
        double scaleY = region.Height / Math.Max(_selectionRect.Height, 0.0001);
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            dc.DrawImage(baseCropped, new Rect(0, 0, region.Width, region.Height));
            dc.PushTransform(new ScaleTransform(scaleX, scaleY));
            dc.PushTransform(new TranslateTransform(-_selectionRect.X, -_selectionRect.Y));
            foreach (var elem in _annotationHistory)
            {
                var brush = new VisualBrush(elem);
                dc.DrawRectangle(brush, null, new Rect(0, 0, viewSize.Width, viewSize.Height));
            }
            dc.Pop();
            dc.Pop();
        }
        rtb.Render(dv);
        rtb.Freeze();
        return rtb;
    }

    /// <summary>
    /// The current selection as pixel indices of the captured bitmap. All output
    /// paths (copy, save, pin, OCR, translation) go through here so a scaled
    /// display cannot make the saved image disagree with the drawn selection.
    /// </summary>
    private Int32Rect SelectionBitmapRegion() => CaptureRegionGeometry.ToBitmapRegion(
        _selectionRect,
        OverlayViewSize(),
        _fullScreenBitmap.PixelWidth,
        _fullScreenBitmap.PixelHeight);

    /// <summary>
    /// The extent the background bitmap is actually stretched across, which is
    /// what pointer positions from GetPosition are relative to. ActualWidth is the
    /// size layout produced; the requested Width is only a fallback for callers
    /// that run before the first layout pass.
    /// </summary>
    private Size OverlayViewSize() => new(
        ActualWidth > 0 ? ActualWidth : Width,
        ActualHeight > 0 ? ActualHeight : Height);

    /// <summary>
    /// Places the overlay over exactly the captured area using physical pixels.
    /// SetWindowPos takes device pixels, so this is immune to the DIP conversion
    /// that oversizes the window when Left/Top/Width/Height are assigned the
    /// virtual-screen metrics directly.
    /// </summary>
    private void CoverCapturedArea()
    {
        IntPtr handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero)
        {
            return;
        }

        bool placed = NativeWin32.SetWindowPos(
            handle,
            IntPtr.Zero,
            (int)Math.Round(_screenBounds.X),
            (int)Math.Round(_screenBounds.Y),
            (int)Math.Round(_screenBounds.Width),
            (int)Math.Round(_screenBounds.Height),
            NativeWin32.SWP_NOZORDER | NativeWin32.SWP_NOACTIVATE);
        if (!placed)
        {
            return;
        }

        // SetWindowPos moved the window behind WPF's back, leaving the requested
        // Width/Height as the oversized physical numbers. A later layout pass
        // would apply those again and undo the placement, so rewrite them in DIPs.
        Point origin = DpiHelper.TransformFromPixels(
            this,
            new Point(_screenBounds.X, _screenBounds.Y));
        Point extent = DpiHelper.TransformFromPixels(
            this,
            new Point(_screenBounds.Width, _screenBounds.Height));

        Left = origin.X;
        Top = origin.Y;
        Width = Math.Abs(extent.X);
        Height = Math.Abs(extent.Y);
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            HandleRightClick();
        }
        else if (e.Key == Key.Enter)
        {
            OnActionTriggered("Copy");
        }
        else if (HandleColorShortcut(e.Key, Keyboard.Modifiers))
        {
            e.Handled = true;
        }
        else if (e.Key == Key.Z && (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
        {
            OnActionTriggered("Undo");
        }
        else if (e.Key == Key.Y && (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
        {
            OnActionTriggered("Redo");
        }
        else if (_phase == SelectionPhase.Selected && !_selectionRect.IsEmpty)
        {
            double step = (Keyboard.Modifiers & ModifierKeys.Shift) == ModifierKeys.Shift ? 10 : 1;
            double dx = 0, dy = 0;
            if (e.Key == Key.Left) dx = -step;
            else if (e.Key == Key.Right) dx = step;
            else if (e.Key == Key.Up) dy = -step;
            else if (e.Key == Key.Down) dy = step;

            if (dx != 0 || dy != 0)
            {
                _selectionRect = FromNativeRect(SelectionGeometryService.Edited(
                    ToNativeRect(_selectionRect),
                    new NativePoint(0, 0),
                    new NativePoint(dx, dy),
                    NativeSelectionEditTarget.Move,
                    SelectionBounds(),
                    minimumSide: 4));
                UpdateSelectionDisplay();
                e.Handled = true;
            }
        }
    }

    internal MagnifierControl ColorMagnifier => Magnifier;

    internal bool HandleColorShortcut(Key key, ModifierKeys modifiers)
    {
        if (key != Key.C
            || (modifiers & (ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Windows)) != ModifierKeys.None
            || Magnifier.Visibility != Visibility.Visible)
        {
            return false;
        }

        // Matches macOS: Shift+C changes format, plain C copies the value shown,
        // and neither action closes the capture overlay.
        if ((modifiers & ModifierKeys.Shift) == ModifierKeys.Shift)
            Magnifier.ToggleDisplayFormat();
        else
            CopyCurrentColor();
        return true;
    }
}
