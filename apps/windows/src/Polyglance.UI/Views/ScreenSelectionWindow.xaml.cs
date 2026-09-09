using System;
using System.Collections.Generic;
using System.IO;
using System.Media;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Path = System.Windows.Shapes.Path;
using TextBox = System.Windows.Controls.TextBox;
using FontFamily = System.Windows.Media.FontFamily;
using Microsoft.Win32;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.Platform.Barcode;
using Polyglance.Platform.Capture;
using Polyglance.Platform.Dpi;
using Polyglance.Platform.Interop;
using Polyglance.Platform.Ocr;
using Polyglance.Platform.Pin;
using Polyglance.UI.Controls;

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
    private readonly AppConfiguration? _config;
    private readonly ScreenshotCaptureIntent _captureIntent;
    private readonly Action<string> _colorClipboardWriter;

    private SelectionPhase _phase = SelectionPhase.Ready;
    private NativeSelectionEditTarget _currentEditTarget = NativeSelectionEditTarget.None;
    private Point _dragStart;
    private Rect _initialSelection = Rect.Empty;
    private Rect _selectionRect = Rect.Empty;
    private Rect _hoveredWindowRect = Rect.Empty;
    private string _activeTool = "None";
    private bool _isToolbarManuallyMoved;
    private double _manualMainToolbarLeft;
    private double _manualMainToolbarTop;

    private readonly List<UIElement> _annotationHistory = new();
    private readonly List<UIElement> _redoStack = new();
    private UIElement? _selectedAnnotationElement;
    private AnnotationHandleType _draggingAnnotationHandle = AnnotationHandleType.None;
    private Point _movingAnnotationLastPoint;
    private bool _isMovingAnnotation;
    private FrameworkElement? _currentDrawingShape;
    private Canvas? _currentMosaicStroke;
    private Point _lastMosaicPoint;
    private Point _drawingStart;
    private int _nextNumber = 1;
    private bool _isCompletingMouseGesture;
    private CancellationTokenSource? _barcodeRecognitionCancellation;
    private bool _isBarcodeRecognitionInFlight;

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

        Left = screenBounds.X;
        Top = screenBounds.Y;
        Width = screenBounds.Width;
        Height = screenBounds.Height;
        SourceInitialized += (_, _) => CoverCapturedArea();

        BackgroundImage.Source = fullScreenBitmap;

        Toolbar.ApplyItemsConfiguration(_config?.ScreenshotToolbarItems);
        Toolbar.ToolSelected += OnToolSelected;
        Toolbar.ActionTriggered += OnActionTriggered;
        Toolbar.ToolbarDragDelta += OnToolbarDragDelta;
        Toolbar.ColorChanged += OnToolbarColorChanged;
        Toolbar.StrokeSizeChanged += OnToolbarStrokeSizeChanged;
        Toolbar.SubToolActionTriggered += OnToolbarSubToolActionTriggered;

        Cursor = Cursors.Cross;
        UpdateMask(Rect.Empty);
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        Point pt = ClampPointToOverlay(e.GetPosition(this));

        if (Toolbar.IsMouseOver)
            return;

        Toolbar.CloseAllPopups();

        // 1. 右键处理 (对齐 macOS: 逐级回退取消)
        if (e.RightButton == MouseButtonState.Pressed)
        {
            HandleRightClick();
            return;
        }

        // 2. 左键处理
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            if (_activeTool != "None" && !_selectionRect.IsEmpty)
            {
                // Resize/expand handles keep priority while a markup tool is active.
                if (TryBeginSelectionEdit(pt, allowsMove: false))
                    return;

                if (!_selectionRect.Contains(pt))
                {
                    SystemSounds.Beep.Play();
                    return;
                }

                if (_selectedAnnotationElement != null)
                {
                    var handle = AnnotationSecondaryEditor.HitTestHandles(_selectedAnnotationElement, pt);
                    if (handle != AnnotationHandleType.None)
                    {
                        _draggingAnnotationHandle = handle;
                        CaptureMouse();
                        return;
                    }
                }

                UIElement? hitElement = null;
                for (int i = _annotationHistory.Count - 1; i >= 0; i--)
                {
                    if (AnnotationSecondaryEditor.HitTestElement(_annotationHistory[i], pt))
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
                        return;
                    }

                    SelectAnnotationElement(hitElement);
                    _isMovingAnnotation = true;
                    _movingAnnotationLastPoint = pt;
                    CaptureMouse();
                    return;
                }

                if (_selectedAnnotationElement != null)
                {
                    SelectAnnotationElement(null);
                }

                _drawingStart = pt;
                StartAnnotationDrawing(pt);
                CaptureMouse();
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

                TryBeginSelectionEdit(pt, allowsMove: true);
                return;
            }

            if (_phase == SelectionPhase.Ready)
            {
                // 开始初次鼠标划选
                _phase = SelectionPhase.DraggingNew;
                _dragStart = pt;
                _selectionRect = new Rect(pt, new Size(0, 0));
                _isToolbarManuallyMoved = false;
                _manualMainToolbarLeft = 0;
                _manualMainToolbarTop = 0;
                CaptureMouse();
                Toolbar.Visibility = Visibility.Collapsed;
                CandidateBorder.Visibility = Visibility.Collapsed;
                ShowMagnifier(pt);
                return;
            }
        }
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        Point pt = ClampPointToOverlay(e.GetPosition(this));

        if (_draggingAnnotationHandle != AnnotationHandleType.None && _selectedAnnotationElement != null)
        {
            AnnotationSecondaryEditor.ResizeElement(
                _selectedAnnotationElement,
                _draggingAnnotationHandle,
                pt,
                rect => MosaicStrokeBuilder.CreateRectMosaic(
                    _fullScreenBitmap,
                    OverlayViewSize(),
                    rect,
                    Math.Max(4, Toolbar.CurrentStrokeSize * 2),
                    Toolbar.MosaicIsBlur)?.Source as BitmapSource);
            AnnotationSecondaryEditor.DrawSelection(AnnotationSelectionCanvas, _selectedAnnotationElement);
            Cursor = AnnotationSecondaryEditor.GetCursorForHandle(_draggingAnnotationHandle);
            return;
        }

        if (_isMovingAnnotation && _selectedAnnotationElement != null)
        {
            double dx = pt.X - _movingAnnotationLastPoint.X;
            double dy = pt.Y - _movingAnnotationLastPoint.Y;
            AnnotationSecondaryEditor.MoveElement(_selectedAnnotationElement, dx, dy);
            _movingAnnotationLastPoint = pt;
            AnnotationSecondaryEditor.DrawSelection(AnnotationSelectionCanvas, _selectedAnnotationElement);
            Cursor = Cursors.SizeAll;
            return;
        }

        if (_currentDrawingShape != null || _currentMosaicStroke != null)
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
        // Clamping only the far edge pushed the panel off-screen at the left and
        // top, where the flipped position goes negative.
        Canvas.SetLeft(
            Magnifier,
            Math.Max(12, Math.Min(viewSize.Width - Magnifier.Width - 12, pt.X + 16)));
        Canvas.SetTop(
            Magnifier,
            Math.Max(12, Math.Min(viewSize.Height - Magnifier.Height - 12, pt.Y + 16)));

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
        if (IsMouseCaptured)
        {
            _isCompletingMouseGesture = true;
            ReleaseMouseCapture();
            _isCompletingMouseGesture = false;
        }

        if (_draggingAnnotationHandle != AnnotationHandleType.None)
        {
            _draggingAnnotationHandle = AnnotationHandleType.None;
            AnnotationSecondaryEditor.DrawSelection(AnnotationSelectionCanvas, _selectedAnnotationElement);
            return;
        }

        if (_isMovingAnnotation)
        {
            _isMovingAnnotation = false;
            AnnotationSecondaryEditor.DrawSelection(AnnotationSelectionCanvas, _selectedAnnotationElement);
            return;
        }

        if (_currentDrawingShape != null || _currentMosaicStroke != null)
        {
            UIElement finished = _currentDrawingShape is not null
                ? _currentDrawingShape
                : _currentMosaicStroke!;
            _annotationHistory.Add(finished);
            _redoStack.Clear();
            _currentDrawingShape = null;
            _currentMosaicStroke = null;
            UpdateUndoRedoButtons();
            SelectAnnotationElement(finished);
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

    private void OnLostMouseCapture(object sender, MouseEventArgs e)
    {
        if (_isCompletingMouseGesture)
            return;

        // Display edges and top-level system UI can steal mouse capture. Finish
        // with a legal selection instead of leaving a half-dragged gesture whose
        // later crop could throw from an async event handler and terminate the app.
        if (_phase is SelectionPhase.DraggingNew
            or SelectionPhase.Moving
            or SelectionPhase.Resizing
            or SelectionPhase.Expanding)
        {
            _selectionRect = ClampSelectionToOverlay(_selectionRect);
            if (_selectionRect.Width > 6 && _selectionRect.Height > 6)
            {
                _phase = SelectionPhase.Selected;
                _currentEditTarget = NativeSelectionEditTarget.None;
                HideMagnifier();
                UpdateSelectionDisplay();
                PositionToolbar();
            }
            else
            {
                ClearSelection();
            }
        }
    }

    private void HandleRightClick()
    {
        if (_selectedAnnotationElement != null)
        {
            SelectAnnotationElement(null);
            return;
        }

        if (_activeTool != "None")
        {
            FinishAnnotationMode();
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
        if (IsMouseCaptured)
            ReleaseMouseCapture();
        SelectAnnotationElement(null);
        _phase = SelectionPhase.Ready;
        _currentEditTarget = NativeSelectionEditTarget.None;
        _selectionRect = Rect.Empty;
        _isToolbarManuallyMoved = false;
        _manualMainToolbarLeft = 0;
        _manualMainToolbarTop = 0;
        SelectionBorder.Visibility = Visibility.Collapsed;
        HandlesCanvas.Visibility = Visibility.Collapsed;
        SizeBadge.Visibility = Visibility.Collapsed;
        Toolbar.Visibility = Visibility.Collapsed;
        AnnotationCanvas.Children.Clear();
        _annotationHistory.Clear();
        _redoStack.Clear();
        _nextNumber = 1;
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
                    Cursor = Cursors.Hand;
                    return;
                }
            }
            for (int i = _annotationHistory.Count - 1; i >= 0; i--)
            {
                if (AnnotationSecondaryEditor.HitTestElement(_annotationHistory[i], pt))
                {
                    Cursor = Cursors.Hand;
                    return;
                }
            }
        }

        var target = DetectEditTarget(pt, _selectionRect, handleTolerance: 8);
        if (_activeTool != "None" && target == NativeSelectionEditTarget.Move)
        {
            Cursor = Cursors.Cross;
            return;
        }

        SetCursorForEditTarget(target);
    }

    private void SetCursorForEditTarget(NativeSelectionEditTarget target)
    {
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

    private bool TryBeginSelectionEdit(Point pt, bool allowsMove)
    {
        if (_phase != SelectionPhase.Selected || _selectionRect.IsEmpty)
            return false;

        NativeSelectionEditTarget target = DetectEditTarget(pt, _selectionRect, handleTolerance: 8);
        if (!allowsMove && target == NativeSelectionEditTarget.Move)
            return false;

        _currentEditTarget = target;
        _dragStart = pt;
        _initialSelection = _selectionRect;
        Toolbar.Visibility = Visibility.Collapsed;
        CaptureMouse();

        switch (target)
        {
            case NativeSelectionEditTarget.Move:
                _phase = SelectionPhase.Moving;
                Cursor = Cursors.SizeAll;
                break;
            case NativeSelectionEditTarget.Expand:
                _phase = SelectionPhase.Expanding;
                _selectionRect = ExpandSelectionToward(_initialSelection, pt);
                UpdateSelectionDisplay();
                SetCursorForEditTarget(target);
                break;
            default:
                _phase = SelectionPhase.Resizing;
                SetCursorForEditTarget(target);
                break;
        }
        return true;
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
        Toolbar.SetCompactLayout(Toolbar.ShouldUseCompact(OverlayViewSize().Width));
        Toolbar.Visibility = Visibility.Visible;

        Size viewSize = OverlayViewSize();
        double mainWidth = Toolbar.MainToolbarWidth;
        double mainHeight = Toolbar.MainToolbarHeight;
        double subOccupiedHeight = Toolbar.SubToolbarOccupiedHeight;
        double anticipatedSubHeight = subOccupiedHeight > 0 ? subOccupiedHeight : 38;
        double spaceNeeded = mainHeight + anticipatedSubHeight + 10;

        bool subToolbarAbove = false;
        PlacementMode popupPlacement = PlacementMode.Bottom;
        double mainToolbarTop;

        if (_selectionRect.Bottom + spaceNeeded <= viewSize.Height - 12)
        {
            // 选框外部下方有充足空间：主菜单在下方，二级菜单在主菜单下方，下拉框向下展示
            subToolbarAbove = false;
            popupPlacement = PlacementMode.Bottom;
            mainToolbarTop = _selectionRect.Bottom + 10;
        }
        else if (_selectionRect.Top - spaceNeeded >= 12)
        {
            // 选框外部上方有充足空间：主菜单在上方，二级菜单在主菜单上方，下拉框正常向下展示
            subToolbarAbove = true;
            popupPlacement = PlacementMode.Bottom;
            mainToolbarTop = _selectionRect.Top - mainHeight - 10;
        }
        else
        {
            // 选框外部上下空间均不足（全屏截图或大选区）：改到选区内部下方展示，二级菜单放置在主菜单上方，下拉框向上展示
            subToolbarAbove = true;
            popupPlacement = PlacementMode.Top;
            mainToolbarTop = Math.Min(_selectionRect.Bottom - mainHeight - 10, viewSize.Height - mainHeight - 12);
            mainToolbarTop = Math.Max(12, mainToolbarTop);
        }

        Toolbar.SetSubToolbarLayout(subToolbarAbove, popupPlacement);

        double top = (subToolbarAbove && Toolbar.IsSubToolbarVisible)
            ? mainToolbarTop - Toolbar.SubToolbarOccupiedHeight
            : mainToolbarTop;

        double maximumLeft = Math.Max(12, viewSize.Width - mainWidth - 12);
        double left = Math.Clamp(_selectionRect.Right - mainWidth, 12, maximumLeft);

        if (_isToolbarManuallyMoved)
        {
            left = Math.Clamp(_manualMainToolbarLeft, 12, maximumLeft);
            top = (subToolbarAbove && Toolbar.IsSubToolbarVisible)
                ? _manualMainToolbarTop - Toolbar.SubToolbarOccupiedHeight
                : _manualMainToolbarTop;
        }
        else
        {
            _manualMainToolbarLeft = left;
            _manualMainToolbarTop = mainToolbarTop;
        }

        Canvas.SetLeft(Toolbar, left);
        Canvas.SetTop(Toolbar, top);
    }

    private void OnToolbarDragDelta(double deltaX, double deltaY)
    {
        _isToolbarManuallyMoved = true;
        Size viewSize = OverlayViewSize();
        double mainWidth = Toolbar.MainToolbarWidth;
        double mainHeight = Toolbar.MainToolbarHeight;
        double maximumLeft = Math.Max(12, viewSize.Width - mainWidth - 12);
        double maximumTop = Math.Max(12, viewSize.Height - mainHeight - 12);

        if (_manualMainToolbarLeft <= 0 && _manualMainToolbarTop <= 0)
        {
            _manualMainToolbarLeft = Canvas.GetLeft(Toolbar);
            _manualMainToolbarTop = Canvas.GetTop(Toolbar);
            if (Toolbar.IsSubToolbarAbove && Toolbar.IsSubToolbarVisible)
            {
                _manualMainToolbarTop += Toolbar.SubToolbarOccupiedHeight;
            }
        }

        _manualMainToolbarLeft = Math.Clamp(_manualMainToolbarLeft + deltaX, 12, maximumLeft);
        _manualMainToolbarTop = Math.Clamp(_manualMainToolbarTop + deltaY, 12, maximumTop);

        double top = (Toolbar.IsSubToolbarAbove && Toolbar.IsSubToolbarVisible)
            ? _manualMainToolbarTop - Toolbar.SubToolbarOccupiedHeight
            : _manualMainToolbarTop;

        Canvas.SetLeft(Toolbar, _manualMainToolbarLeft);
        Canvas.SetTop(Toolbar, top);
    }

    private void OnToolSelected(string tool)
    {
        _activeTool = tool;
        SetAnnotationMode(tool != "None");
        Cursor = tool == "None" ? Cursors.Arrow : Cursors.Cross;
    }

    private void SetAnnotationMode(bool isAnnotating)
    {
        Toolbar.SetAnnotationMode(isAnnotating);
        if (!_selectionRect.IsEmpty)
        {
            UpdateSelectionDisplay();
            PositionToolbar();
        }
    }

    private void FinishAnnotationMode()
    {
        _activeTool = "None";
        SelectAnnotationElement(null);
        Toolbar.ClearSelectedTool();
        SetAnnotationMode(false);
        Cursor = Cursors.Arrow;
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
                    RadiusY = 3,
                    StrokeDashArray = Toolbar.CurrentDashArray,
                    Fill = Toolbar.IsFilled ? brush : Brushes.Transparent
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
                    StrokeThickness = strokeSize,
                    StrokeDashArray = Toolbar.CurrentDashArray,
                    Fill = Toolbar.IsFilled ? brush : Brushes.Transparent
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

            case "Line":
                var line = new System.Windows.Shapes.Line
                {
                    X1 = pt.X,
                    Y1 = pt.Y,
                    X2 = pt.X,
                    Y2 = pt.Y,
                    Stroke = brush,
                    StrokeThickness = strokeSize,
                    StrokeStartLineCap = PenLineCap.Round,
                    StrokeEndLineCap = PenLineCap.Round,
                    StrokeDashArray = Toolbar.CurrentDashArray
                };
                AnnotationCanvas.Children.Add(line);
                _currentDrawingShape = line;
                break;

            case "Arrow":
                var arrowInfo = new ArrowInfo
                {
                    Start = pt,
                    End = pt,
                    StrokeSize = strokeSize,
                    ArrowStyle = Toolbar.ArrowStyle,
                    IsFilled = Toolbar.IsFilled
                };
                var arrowPath = new System.Windows.Shapes.Path
                {
                    Stroke = brush,
                    StrokeThickness = (Toolbar.ArrowStyle == 2 || Toolbar.ArrowStyle == 3) ? Math.Max(strokeSize * 1.6, strokeSize + 2.0) : strokeSize,
                    StrokeStartLineCap = PenLineCap.Round,
                    StrokeEndLineCap = PenLineCap.Round,
                    StrokeLineJoin = PenLineJoin.Round,
                    Fill = (Toolbar.ArrowStyle == 5 || Toolbar.ArrowStyle == 7 || Toolbar.ArrowStyle == 8 || Toolbar.IsFilled) ? brush : Brushes.Transparent,
                    StrokeDashArray = Toolbar.CurrentDashArray,
                    Data = AnnotationSecondaryEditor.MakeArrowGeometry(pt, pt, strokeSize, Toolbar.ArrowStyle, Toolbar.IsFilled),
                    Tag = arrowInfo
                };
                AnnotationCanvas.Children.Add(arrowPath);
                _currentDrawingShape = arrowPath;
                break;

            case "Text":
                var tb = new System.Windows.Controls.TextBox
                {
                    Background = Toolbar.HasTextBorder ? new SolidColorBrush(Color.FromArgb(160, 0, 0, 0)) : Brushes.Transparent,
                    BorderBrush = Toolbar.HasTextBorder ? brush : Brushes.Transparent,
                    BorderThickness = Toolbar.HasTextBorder ? new Thickness(1) : new Thickness(1),
                    Foreground = Toolbar.HasTextBorder ? Brushes.White : brush,
                    FontFamily = !string.IsNullOrEmpty(Toolbar.CurrentFontFamily) ? new System.Windows.Media.FontFamily(Toolbar.CurrentFontFamily) : new System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei"),
                    FontSize = Toolbar.FontSizeValue,
                    FontWeight = Toolbar.IsBold ? FontWeights.Bold : FontWeights.Normal,
                    FontStyle = Toolbar.IsItalic ? FontStyles.Italic : FontStyles.Normal,
                    AcceptsReturn = true,
                    MinWidth = 60,
                    Padding = Toolbar.HasTextBorder ? new Thickness(4, 2, 4, 2) : new Thickness(0),
                    CaretBrush = Toolbar.HasTextBorder ? Brushes.White : brush
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
                        if (_selectedAnnotationElement == tb)
                        {
                            SelectAnnotationElement(null);
                        }
                        UpdateUndoRedoButtons();
                    }
                    else
                    {
                        tb.BorderThickness = Toolbar.HasTextBorder ? new Thickness(1) : new Thickness(0);
                        tb.IsReadOnly = true;
                        SelectAnnotationElement(tb);
                    }
                };
                break;

            case "Mosaic":
                if (Toolbar.MosaicShapeType == 1)
                {
                    var rectImg = MosaicStrokeBuilder.CreateRectMosaic(
                        _fullScreenBitmap,
                        OverlayViewSize(),
                        new Rect(pt, new Size(1, 1)),
                        Math.Max(4, strokeSize * 2),
                        Toolbar.MosaicIsBlur);
                    Canvas.SetLeft(rectImg, pt.X);
                    Canvas.SetTop(rectImg, pt.Y);
                    AnnotationCanvas.Children.Add(rectImg);
                    _currentDrawingShape = rectImg;
                }
                else
                {
                    double mosaicDiameter = Math.Max(18, strokeSize * 5);
                    _currentMosaicStroke = MosaicStrokeBuilder.Begin(
                        _fullScreenBitmap,
                        OverlayViewSize(),
                        pt,
                        mosaicDiameter,
                        Toolbar.MosaicIsBlur);
                    _lastMosaicPoint = pt;
                    AnnotationCanvas.Children.Add(_currentMosaicStroke);
                }
                break;

            case "Number":
                bool isOutline = Toolbar.NumberStyle == 1;
                double markerSize = Math.Max(18, Toolbar.CurrentStrokeSize * 5);
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
                Canvas.SetLeft(marker, pt.X - radius);
                Canvas.SetTop(marker, pt.Y - radius);
                AnnotationCanvas.Children.Add(marker);
                _annotationHistory.Add(marker);
                _redoStack.Clear();
                UpdateUndoRedoButtons();
                SelectAnnotationElement(marker);
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
        else if (_currentDrawingShape is System.Windows.Shapes.Line line)
        {
            line.X2 = curX;
            line.Y2 = curY;
        }
        else if (_currentDrawingShape is Polyline polyline)
        {
            polyline.Points.Add(new Point(curX, curY));
        }
        else if (_currentDrawingShape is System.Windows.Shapes.Path path && _activeTool == "Arrow" && path.Tag is ArrowInfo info)
        {
            info.End = new Point(curX, curY);
            path.Data = AnnotationSecondaryEditor.MakeArrowGeometry(_drawingStart, new Point(curX, curY), path.StrokeThickness, Toolbar.ArrowStyle, Toolbar.IsFilled);
        }
        else if (_currentDrawingShape is System.Windows.Controls.Image mosaicImg && _activeTool == "Mosaic")
        {
            double x = Math.Min(_drawingStart.X, curX);
            double y = Math.Min(_drawingStart.Y, curY);
            double w = Math.Max(1, Math.Abs(curX - _drawingStart.X));
            double h = Math.Max(1, Math.Abs(curY - _drawingStart.Y));
            var newImg = MosaicStrokeBuilder.CreateRectMosaic(
                _fullScreenBitmap,
                OverlayViewSize(),
                new Rect(x, y, w, h),
                Math.Max(4, Toolbar.CurrentStrokeSize * 2),
                Toolbar.MosaicIsBlur);
            mosaicImg.Source = newImg.Source;
            mosaicImg.Width = w;
            mosaicImg.Height = h;
            Canvas.SetLeft(mosaicImg, x);
            Canvas.SetTop(mosaicImg, y);
        }
        else if (_currentMosaicStroke is not null && _activeTool == "Mosaic")
        {
            double diameter = Math.Max(18, Toolbar.CurrentStrokeSize * 5);
            Point current = new(curX, curY);
            foreach (Point sample in MosaicStrokeBuilder.Interpolate(
                         _lastMosaicPoint,
                         current,
                         Math.Max(2, diameter / 4)))
            {
                MosaicStrokeBuilder.AddStamp(
                    _currentMosaicStroke,
                    _fullScreenBitmap,
                    OverlayViewSize(),
                    sample,
                    diameter,
                    Toolbar.MosaicIsBlur);
            }
            _lastMosaicPoint = current;
        }
    }

    private async void OnActionTriggered(string action)
    {
        switch (action)
        {
            case "Undo":
                if (_annotationHistory.Count > 0)
                {
                    var last = _annotationHistory[^1];
                    _annotationHistory.RemoveAt(_annotationHistory.Count - 1);
                    _redoStack.Add(last);
                    AnnotationCanvas.Children.Remove(last);
                    if (_selectedAnnotationElement == last)
                    {
                        SelectAnnotationElement(null);
                    }
                    UpdateUndoRedoButtons();
                }
                return;

            case "Redo":
                if (_redoStack.Count > 0)
                {
                    var last = _redoStack[^1];
                    _redoStack.RemoveAt(_redoStack.Count - 1);
                    _annotationHistory.Add(last);
                    AnnotationCanvas.Children.Add(last);
                    SelectAnnotationElement(last);
                    UpdateUndoRedoButtons();
                }
                return;

            case "Finish":
                FinishAnnotationMode();
                return;

            case "Cancel":
                Close();
                return;

            case "LongScreenshot":
                var longWin = new LongScreenshotSessionWindow(
                    _fullScreenBitmap,
                    _screenBounds,
                    _selectionRect,
                    _translationService,
                    _config);
                longWin.Show();
                Close();
                return;

            case "ScreenRecording":
                var recordWin = new ScreenRecordingWindow(_screenBounds, _selectionRect, _config);
                recordWin.Show();
                Close();
                return;
        }

        BitmapSource? cropped;
        try
        {
            _selectionRect = ClampSelectionToOverlay(_selectionRect);
            cropped = GetRenderedCroppedBitmap();
        }
        catch (Exception error)
        {
            ShowCaptureError("截图失败", error);
            return;
        }
        if (cropped == null)
        {
            SystemSounds.Beep.Play();
            return;
        }

        switch (action)
        {

            case "Copy":
                Clipboard.SetImage(cropped);
                if (_config?.SaveCompletedScreenshotsToHistory == true)
                {
                    PinArchiveRecording.Record(cropped, PinArchiveSource.Screenshot);
                }
                Close();
                break;

            case "Pin":
                var pinWin = new PinWindow(
                    cropped,
                    _translationService,
                    _config,
                    _selectionRect.Size);
                Point pinOrigin = PinWindow.WindowOriginForContentFrame(
                    new Rect(
                        Left + _selectionRect.X,
                        Top + _selectionRect.Y,
                        _selectionRect.Width,
                        _selectionRect.Height));
                pinWin.Left = pinOrigin.X;
                pinWin.Top = pinOrigin.Y;
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
                    if (_config?.SaveCompletedScreenshotsToHistory == true)
                    {
                        PinArchiveRecording.Record(cropped, PinArchiveSource.Screenshot);
                    }
                }
                Close();
                break;

            case "OCR":
                if (OcrWorkspaceWindow.ActiveContinuousInstance != null && OcrWorkspaceWindow.ActiveContinuousInstance.IsLoaded)
                {
                    var activeInstance = OcrWorkspaceWindow.ActiveContinuousInstance;
                    activeInstance.StartPendingAppend(cropped);
                    activeInstance.Activate();
                    Close();
                    _ = Task.Run(async () =>
                    {
                        try
                        {
                            var document = await OcrService.RecognizeDocumentAsync(cropped);
                            await Dispatcher.InvokeAsync(() => activeInstance.FinishPendingAppend(cropped, document));
                        }
                        catch (Exception ex)
                        {
                            await Dispatcher.InvokeAsync(() => activeInstance.CancelPendingAppend(ex));
                        }
                    });
                    break;
                }

                var workspaceWindow = new OcrWorkspaceWindow(
                    cropped,
                    null,
                    _translationService,
                    _config);
                workspaceWindow.Show();
                workspaceWindow.Activate();
                Close();

                _ = Task.Run(async () =>
                {
                    try
                    {
                        var document = await OcrService.RecognizeDocumentAsync(cropped);
                        await Dispatcher.InvokeAsync(() =>
                        {
                            workspaceWindow.SetDocument(document);
                            if (_config?.OcrAutoCopyNextTime == true)
                            {
                                var mode = (Polyglance.Core.Services.TextFormattingMode)Math.Clamp(_config.OcrDefaultFormatting, 0, 3);
                                var cleaned = TextFormattingService.Format(document.Lines, mode);
                                Clipboard.SetText(cleaned);
                                System.Media.SystemSounds.Asterisk.Play();
                                App.ShowNotification("Polyglance 文字识别", $"已识别并复制 {cleaned.Length} 个字符到剪贴板。");
                            }
                        });
                    }
                    catch (Exception ex)
                    {
                        await Dispatcher.InvokeAsync(() => workspaceWindow.SetError(ex.Message));
                    }
                });
                break;

            case "Barcode":
                if (_isBarcodeRecognitionInFlight)
                {
                    return;
                }
                _isBarcodeRecognitionInFlight = true;
                _barcodeRecognitionCancellation?.Cancel();
                _barcodeRecognitionCancellation?.Dispose();
                _barcodeRecognitionCancellation = new CancellationTokenSource();
                try
                {
                    var barcodes = await WindowsBarcodeReader.RecognizeAsync(
                        cropped,
                        _barcodeRecognitionCancellation.Token);
                    if (barcodes.Count == 0)
                    {
                        throw new WindowsBarcodeException("当前截图中没有识别到条码。");
                    }
                    var barcodeWindow = new BarcodeResultWindow(
                        barcodes,
                        cropped,
                        SelectedScreenFrame());
                    barcodeWindow.Show();
                    barcodeWindow.Activate();
                    if (IsLoaded)
                    {
                        Close();
                    }
                }
                catch (OperationCanceledException) { }
                catch (Exception error)
                {
                    if (_barcodeRecognitionCancellation?.IsCancellationRequested != true && IsLoaded)
                    {
                        ShowCaptureError("条码识别失败", error);
                    }
                }
                finally
                {
                    _isBarcodeRecognitionInFlight = false;
                }
                break;

            case "OCRTranslate":
                if (Toolbar.IsOcrTranslationBusy)
                {
                    return;
                }
                Toolbar.SetOcrTranslationBusy(true);
                Cursor = Cursors.Wait;
                try
                {
                    var document = await OcrService.RecognizeDocumentAsync(cropped);
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
                finally
                {
                    Toolbar.SetOcrTranslationBusy(false);
                    Cursor = _activeTool == "None" ? Cursors.Arrow : Cursors.Cross;
                }
                break;

            case "ScreenTranslation":
                try
                {
                    var document = await OcrService.RecognizeDocumentAsync(cropped);
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

    private void ShowCaptureError(string title, Exception error)
    {
        // The capture overlay is topmost. An ownerless dialog can open behind it
        // and make a failed OCR or translation request appear to do nothing.
        MessageBox.Show(this, error.Message, title, MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    protected override void OnClosed(EventArgs e)
    {
        _barcodeRecognitionCancellation?.Cancel();
        _barcodeRecognitionCancellation?.Dispose();
        _barcodeRecognitionCancellation = null;
        base.OnClosed(e);
    }

    private BitmapSource? GetRenderedCroppedBitmap()
    {
        Int32Rect region = SelectionBitmapRegion();
        if (region.IsEmpty)
            return null;

        var baseCropped = ScreenCapture.Crop(_fullScreenBitmap, region);

        if (_annotationHistory.Count == 0)
            return baseCropped;

        // Render the live annotation canvas to its own transparent bitmap first.
        // A VisualBrush can lose its live visual when the capture window is closed
        // immediately after Pin/Copy; materialising the layer here makes every
        // output path consume stable pixels.
        Size viewSize = OverlayViewSize();
        AnnotationCanvas.UpdateLayout();
        int overlayWidth = Math.Max(1, (int)Math.Ceiling(viewSize.Width));
        int overlayHeight = Math.Max(1, (int)Math.Ceiling(viewSize.Height));
        var annotationLayer = new RenderTargetBitmap(
            overlayWidth, overlayHeight, 96, 96, PixelFormats.Pbgra32);
        annotationLayer.Render(AnnotationCanvas);
        annotationLayer.Freeze();
        Int32Rect annotationRegion = CaptureRegionGeometry.ToBitmapRegion(
            _selectionRect,
            viewSize,
            annotationLayer.PixelWidth,
            annotationLayer.PixelHeight);
        BitmapSource annotationCrop = ScreenCapture.Crop(annotationLayer, annotationRegion);

        var rtb = new RenderTargetBitmap(region.Width, region.Height, 96, 96, PixelFormats.Pbgra32);
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            dc.DrawImage(baseCropped, new Rect(0, 0, region.Width, region.Height));
            dc.DrawImage(annotationCrop, new Rect(0, 0, region.Width, region.Height));
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

    private Point ClampPointToOverlay(Point point)
    {
        Size view = OverlayViewSize();
        return new Point(
            Math.Clamp(point.X, 0, Math.Max(0, view.Width)),
            Math.Clamp(point.Y, 0, Math.Max(0, view.Height)));
    }

    private Rect ClampSelectionToOverlay(Rect selection)
    {
        if (selection.IsEmpty)
            return Rect.Empty;
        Size view = OverlayViewSize();
        Rect clipped = Rect.Intersect(selection, new Rect(0, 0, view.Width, view.Height));
        return clipped.IsEmpty ? Rect.Empty : clipped;
    }

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
                _redoStack.Clear();
                UpdateUndoRedoButtons();
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
        else if (_phase == SelectionPhase.Selected && !_selectionRect.IsEmpty && _activeTool == "None")
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

    internal bool AreSelectionHandlesVisible =>
        SelectionBorder.Visibility == Visibility.Visible &&
        HandlesCanvas.Visibility == Visibility.Visible;

    internal Rect SelectionRectForTesting => _selectionRect;

    internal int AnnotationCountForTesting => _annotationHistory.Count;

    internal void SetSelectionForTesting(Rect selection)
    {
        _selectionRect = ClampSelectionToOverlay(selection);
        _phase = SelectionPhase.Selected;
        UpdateSelectionDisplay();
        PositionToolbar();
    }

    internal void SelectAnnotationToolForTesting(string tool) => OnToolSelected(tool);

    internal void ClearSelectedToolForTesting() => Toolbar.ClearSelectedTool();

    internal void UpdatePointerForTesting(Point point) => UpdateHoverCursor(point);

    internal bool BeginSelectionEditForTesting(Point point) =>
        TryBeginSelectionEdit(point, allowsMove: false);

    internal void ContinueSelectionEditForTesting(Point point)
    {
        switch (_phase)
        {
            case SelectionPhase.Resizing:
                _selectionRect = ApplyResize(_initialSelection, _currentEditTarget, point);
                break;
            case SelectionPhase.Expanding:
                _selectionRect = ExpandSelectionToward(_initialSelection, point);
                break;
            case SelectionPhase.Moving:
                _selectionRect = ApplySharedEdit(_initialSelection, _currentEditTarget, point);
                break;
        }
        UpdateSelectionDisplay();
    }

    internal void EndSelectionEditForTesting()
    {
        _phase = SelectionPhase.Selected;
        _currentEditTarget = NativeSelectionEditTarget.None;
        PositionToolbar();
    }

    internal void AddRectangleAnnotationForTesting(Rect rect, Color color)
    {
        var element = new Rectangle
        {
            Width = rect.Width,
            Height = rect.Height,
            Stroke = new SolidColorBrush(color),
            StrokeThickness = 4
        };
        Canvas.SetLeft(element, rect.X);
        Canvas.SetTop(element, rect.Y);
        AnnotationCanvas.Children.Add(element);
        _annotationHistory.Add(element);
    }

    internal BitmapSource? RenderedSelectionForTesting() => GetRenderedCroppedBitmap();

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

    protected override void OnPreviewMouseWheel(MouseWheelEventArgs e)
    {
        if (_selectedAnnotationElement != null || (_activeTool != "None" && !string.IsNullOrEmpty(_activeTool)))
        {
            if (_selectedAnnotationElement is TextBox || (_selectedAnnotationElement == null && _activeTool == "Text"))
            {
                Toolbar.AdjustFontSize(e.Delta > 0 ? 1 : -1);
            }
            else
            {
                Toolbar.AdjustStrokeSize(e.Delta > 0 ? 1 : -1);
            }
            e.Handled = true;
            return;
        }
        base.OnPreviewMouseWheel(e);
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
            SyncElementStyleToToolbar(element);
        }
    }

    private void SyncElementStyleToToolbar(UIElement element)
    {
        string toolName = AnnotationSecondaryEditor.GetToolName(element);
        if (toolName != "None")
        {
            _activeTool = toolName;
            Toolbar.SelectTool(toolName);
        }

        if (element is Shape shape)
        {
            if (shape.Stroke is SolidColorBrush sb)
            {
                Toolbar.SetCurrentColor(sb.Color);
            }
            Toolbar.SetCurrentStrokeSize(shape.StrokeThickness);
            if (shape is Path path && path.Tag is ArrowInfo arrow)
            {
                Toolbar.SetCurrentStrokeSize(arrow.StrokeSize);
            }
        }
        else if (element is TextBox tb)
        {
            if (tb.Foreground is SolidColorBrush fb)
            {
                Toolbar.SetCurrentColor(fb.Color);
            }
            Toolbar.SetFontSize(tb.FontSize);
        }
        else if (element is Border border)
        {
            if (border.Background is SolidColorBrush bb && bb != Brushes.Transparent)
            {
                Toolbar.SetCurrentColor(bb.Color);
            }
            else if (border.BorderBrush is SolidColorBrush bbb)
            {
                Toolbar.SetCurrentColor(bbb.Color);
            }
            Toolbar.SetCurrentStrokeSize(Math.Max(1, Math.Round(border.Width / 5.0)));
        }
    }

    private void OnToolbarColorChanged(Color color)
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
                if (Toolbar.IsFilled)
                {
                    shape.Fill = brush;
                }
            }
        }
        else if (_selectedAnnotationElement is TextBox tb)
        {
            tb.Foreground = brush;
            if (Toolbar.HasTextBorder)
            {
                tb.BorderBrush = brush;
            }
        }
        else if (_selectedAnnotationElement is Border border)
        {
            if (Toolbar.NumberStyle == 0)
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

    private void OnToolbarStrokeSizeChanged(double size)
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

    private void OnToolbarSubToolActionTriggered(string action)
    {
        if (_selectedAnnotationElement == null) return;

        if (action == "FillChanged" && _selectedAnnotationElement is Shape shape)
        {
            var brush = new SolidColorBrush(Toolbar.CurrentColor);
            if (shape is Rectangle or Ellipse)
            {
                shape.Fill = Toolbar.IsFilled ? brush : Brushes.Transparent;
            }
            else if (shape is Path path && path.Tag is ArrowInfo arrow)
            {
                arrow.IsFilled = Toolbar.IsFilled;
                path.Fill = (arrow.ArrowStyle == 5 || arrow.ArrowStyle == 7 || arrow.ArrowStyle == 8 || arrow.IsFilled) ? brush : Brushes.Transparent;
                path.Data = AnnotationSecondaryEditor.MakeArrowGeometry(arrow.Start, arrow.End, arrow.StrokeSize, arrow.ArrowStyle, arrow.IsFilled);
            }
        }
        else if (action == "DashChanged" && _selectedAnnotationElement is Shape dashShape)
        {
            dashShape.StrokeDashArray = Toolbar.CurrentDashArray;
        }
        else if (action == "ArrowStyleChanged" && _selectedAnnotationElement is Path arrowPath && arrowPath.Tag is ArrowInfo arrow)
        {
            arrow.ArrowStyle = Toolbar.ArrowStyle;
            arrowPath.StrokeThickness = (arrow.ArrowStyle == 2 || arrow.ArrowStyle == 3) ? Math.Max(arrow.StrokeSize * 1.6, arrow.StrokeSize + 2.0) : arrow.StrokeSize;
            var brush = new SolidColorBrush(Toolbar.CurrentColor);
            arrowPath.Fill = (arrow.ArrowStyle == 5 || arrow.ArrowStyle == 7 || arrow.ArrowStyle == 8 || arrow.IsFilled) ? brush : Brushes.Transparent;
            arrowPath.Data = AnnotationSecondaryEditor.MakeArrowGeometry(arrow.Start, arrow.End, arrow.StrokeSize, arrow.ArrowStyle, arrow.IsFilled);
        }
        else if (_selectedAnnotationElement is TextBox tb)
        {
            if (action == "BoldChanged")
            {
                tb.FontWeight = Toolbar.IsBold ? FontWeights.Bold : FontWeights.Normal;
            }
            else if (action == "ItalicChanged")
            {
                tb.FontStyle = Toolbar.IsItalic ? FontStyles.Italic : FontStyles.Normal;
            }
            else if (action == "BorderChanged")
            {
                tb.Background = Toolbar.HasTextBorder ? new SolidColorBrush(Color.FromArgb(160, 0, 0, 0)) : Brushes.Transparent;
                tb.BorderBrush = Toolbar.HasTextBorder ? new SolidColorBrush(Toolbar.CurrentColor) : Brushes.Transparent;
            }
            else if (action == "FontSizeChanged")
            {
                tb.FontSize = Toolbar.FontSizeValue;
            }
            else if (action == "FontFamilyChanged")
            {
                tb.FontFamily = new FontFamily(Toolbar.CurrentFontFamily);
            }
        }
        else if (action.StartsWith("NumberStyle") && _selectedAnnotationElement is Border border)
        {
            var brush = new SolidColorBrush(Toolbar.CurrentColor);
            if (Toolbar.NumberStyle == 0)
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
}
