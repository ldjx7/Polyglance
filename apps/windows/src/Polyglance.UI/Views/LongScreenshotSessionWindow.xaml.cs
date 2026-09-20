using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.Platform.Capture;
using Polyglance.Platform.Dpi;
using Polyglance.Platform.Interop;
using Polyglance.Platform.Pin;

namespace Polyglance.UI.Views;

public partial class LongScreenshotSessionWindow : Window
{
    // The transparent WPF overlay is still included by GDI BitBlt on some
    // Windows/RDP configurations. Capture just inside the selection chrome so
    // its blue border and shadow never become part of every stitched frame.
    private const int CaptureOverlayGuardPixels = 4;

    private enum SessionPhase
    {
        SelectingRegion,
        Capturing
    }

    private readonly BitmapSource _fullScreenBitmap;
    private readonly Rect _screenBounds;
    private readonly TranslationService? _translationService;
    private readonly AppConfiguration? _configuration;
    private readonly DispatcherTimer _captureTimer;
    private LongScreenshotService? _stitcher;
    private SessionPhase _phase = SessionPhase.SelectingRegion;
    private Point _dragStart;
    private Rect _cropRect = Rect.Empty;
    private IntPtr _scrollTarget = IntPtr.Zero;
    private bool _isCapturingFrame;
    private uint _lastPreviewFrameCount;
    private int _captureGuardPixels = CaptureOverlayGuardPixels;
    private int _consecutiveSkippedFrames;
    private bool _isCaptureExcluded;
    private Int32Rect _activeCaptureRegion;

    public LongScreenshotSessionWindow(
        BitmapSource fullScreenBitmap,
        Rect screenBounds,
        TranslationService? translationService = null,
        AppConfiguration? configuration = null)
    {
        InitializeComponent();
        _fullScreenBitmap = fullScreenBitmap;
        _screenBounds = screenBounds;
        _translationService = translationService;
        _configuration = configuration;
        _captureTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(33) };
        _captureTimer.Tick += (_, _) => CaptureAndAppendCurrentFrame();
        SourceInitialized += (_, _) =>
        {
            CoverCapturedArea();
            IntPtr handle = new WindowInteropHelper(this).Handle;
            _isCaptureExcluded = NativeWin32.SetWindowDisplayAffinity(handle, NativeWin32.WDA_EXCLUDEFROMCAPTURE);
            _captureGuardPixels = _isCaptureExcluded
                ? CaptureOverlayGuardPixels
                : CaptureOverlayGuardPixels * 2;
            if (_cropRect.Width > 0 && _cropRect.Height > 0)
            {
                UpdateSelectionDisplay();
                PositionControls();
            }
        };

        Left = screenBounds.X;
        Top = screenBounds.Y;
        Width = screenBounds.Width;
        Height = screenBounds.Height;
        BackgroundImage.Source = fullScreenBitmap;
        UpdateMask(Rect.Empty);
    }

    public LongScreenshotSessionWindow(
        BitmapSource fullScreenBitmap,
        Rect screenBounds,
        Rect initialCropRect,
        TranslationService? translationService = null,
        AppConfiguration? configuration = null)
        : this(fullScreenBitmap, screenBounds, translationService, configuration)
    {
        if (initialCropRect.Width > 20 && initialCropRect.Height > 20)
        {
            _cropRect = initialCropRect;
            UpdateSelectionDisplay();
            Loaded += (_, _) => StartCapturingSession();
        }
    }

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

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        Point point = e.GetPosition(this);
        if (ControlToolbar.IsMouseOver || PreviewBorder.IsMouseOver)
        {
            return;
        }

        if (e.RightButton == MouseButtonState.Pressed)
        {
            e.Handled = true;
            return;
        }

        if (e.LeftButton == MouseButtonState.Pressed && _phase == SessionPhase.SelectingRegion)
        {
            _dragStart = point;
            _cropRect = new Rect(point, new Size(0, 0));
            CaptureMouse();
        }
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (_phase != SessionPhase.SelectingRegion || e.LeftButton != MouseButtonState.Pressed)
        {
            return;
        }

        Point point = e.GetPosition(this);
        _cropRect = new Rect(
            new Point(Math.Min(_dragStart.X, point.X), Math.Min(_dragStart.Y, point.Y)),
            new Point(Math.Max(_dragStart.X, point.X), Math.Max(_dragStart.Y, point.Y)));
        UpdateSelectionDisplay();
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (IsMouseCaptured)
        {
            ReleaseMouseCapture();
        }

        if (e.ChangedButton == MouseButton.Right)
        {
            e.Handled = true;
            CloseSession();
            return;
        }

        if (_phase == SessionPhase.SelectingRegion && _cropRect.Width > 50 && _cropRect.Height > 50)
        {
            StartCapturingSession();
        }
    }

    private void StartCapturingSession()
    {
        if (_phase == SessionPhase.Capturing)
        {
            return;
        }

        _phase = SessionPhase.Capturing;
        _stitcher = new LongScreenshotService();
        BackgroundImage.Visibility = Visibility.Collapsed;
        MaskCanvas.Visibility = Visibility.Visible;
        SelectionBorder.Visibility = Visibility.Visible;
        ControlToolbar.Visibility = Visibility.Visible;
        TxtStatus.Text = "请慢速平稳滚动页面";
        PositionControls();

        var (centreX, centreY) = CaptureCentreScreenPoint();
        _scrollTarget = UnderlyingWindowScroller.FindTarget(centreX, centreY);

        Int32Rect selectionRegion = SelectionPhysicalRegion();
        ConfigureCaptureRegion(selectionRegion);

        Dispatcher.BeginInvoke(DispatcherPriority.ContextIdle, () =>
        {
            CaptureAndAppendCurrentFrame();
            _captureTimer.Start();
        });
    }

    private void ConfigureCaptureRegion(Int32Rect selectionRegion)
    {
        _activeCaptureRegion = ScreenCapture.InsetOverlayBorder(selectionRegion, _captureGuardPixels);
        _stitcher?.SetCropInsets(0, 0, 0, 0);
    }

    private void OnMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (_phase != SessionPhase.Capturing)
        {
            return;
        }

        var (screenX, screenY) = CaptureCentreScreenPoint();
        bool forwarded = UnderlyingWindowScroller.ForwardWheel(
            _scrollTarget,
            e.Delta,
            screenX,
            screenY);
        if (!forwarded)
        {
            _scrollTarget = UnderlyingWindowScroller.FindTarget(screenX, screenY);
            _ = UnderlyingWindowScroller.ForwardWheel(_scrollTarget, e.Delta, screenX, screenY);
        }
        e.Handled = true;
    }

    private Int32Rect SelectionPhysicalRegion()
    {
        // PointToScreen is the authoritative WPF conversion to desktop device
        // pixels. Combining a physical virtual-screen origin with a DIP matrix
        // is unreliable when Windows applies RDP/system-DPI virtualization.
        Point topLeft = PointToScreen(_cropRect.TopLeft);
        Point bottomRight = PointToScreen(_cropRect.BottomRight);
        int left = checked((int)Math.Floor(Math.Min(topLeft.X, bottomRight.X)));
        int top = checked((int)Math.Floor(Math.Min(topLeft.Y, bottomRight.Y)));
        int right = checked((int)Math.Ceiling(Math.Max(topLeft.X, bottomRight.X)));
        int bottom = checked((int)Math.Ceiling(Math.Max(topLeft.Y, bottomRight.Y)));
        return new Int32Rect(
            left,
            top,
            Math.Max(1, right - left),
            Math.Max(1, bottom - top));
    }

    private (int X, int Y) CaptureCentreScreenPoint()
    {
        Int32Rect region = SelectionPhysicalRegion();
        return (
            checked(region.X + region.Width / 2),
            checked(region.Y + region.Height / 2));
    }

    private void CaptureAndAppendCurrentFrame()
    {
        if (_activeCaptureRegion.Width <= 0 || _activeCaptureRegion.Height <= 0)
        {
            _activeCaptureRegion = ScreenCapture.InsetOverlayBorder(SelectionPhysicalRegion(), _captureGuardPixels);
        }
        if (_activeCaptureRegion.Width <= 0 || _activeCaptureRegion.Height <= 0)
        {
            int left = (int)Math.Round(Left + _cropRect.X);
            int top = (int)Math.Round(Top + _cropRect.Y);
            int width = (int)Math.Round(_cropRect.Width);
            int height = (int)Math.Round(_cropRect.Height);
            _activeCaptureRegion = ScreenCapture.InsetOverlayBorder(new Int32Rect(left, top, width, height), _captureGuardPixels);
        }

        if (_isCapturingFrame || _stitcher == null || _activeCaptureRegion.Width <= 0 || _activeCaptureRegion.Height <= 0)
        {
            return;
        }

        _isCapturingFrame = true;
        try
        {
            var stitcher = _stitcher;
            if (stitcher == null)
            {
                return;
            }

            var region = _activeCaptureRegion;
            var frame = ScreenCapture.CaptureRegion(region, showCursor: false);
            byte[] rgba = ScreenCapture.GetRgbaBytes(frame);
            var result = stitcher.AppendFrame(rgba, (uint)frame.PixelWidth, (uint)frame.PixelHeight);

            _consecutiveSkippedFrames = 0;
            if (result.FrameCount != _lastPreviewFrameCount)
            {
                _lastPreviewFrameCount = result.FrameCount;
                TxtStatus.Text = "请慢速平稳滚动页面";
                UpdatePreview();
            }
            else
            {
                if (TxtStatus.Text.StartsWith("滚动过快"))
                {
                    TxtStatus.Text = "请慢速平稳滚动页面";
                }
                UpdateViewportIndicator();
            }

            if (result.LimitReached != 0)
            {
                _captureTimer.Stop();
                TxtStatus.Text = "已达到最大长度，请贴图或复制";
            }
        }
        catch (Exception error)
        {
            _consecutiveSkippedFrames++;
            if (_consecutiveSkippedFrames >= 20)
            {
                TxtStatus.Text = "滚动过快，请放慢速度";
            }
            System.Diagnostics.Debug.WriteLine($"Long screenshot frame skipped: {error.Message}");
        }
        finally
        {
            _isCapturingFrame = false;
        }
    }

    private void UpdatePreview()
    {
        if (_stitcher == null)
        {
            return;
        }

        try
        {
            BitmapSource preview = CreateBitmapSource(_stitcher.RenderPreview());
            PreviewImage.Source = preview;
            double scale = Math.Min(1, Math.Min(180d / preview.PixelWidth, 300d / preview.PixelHeight));
            double previewWidth = Math.Max(1, preview.PixelWidth * scale);
            double previewHeight = Math.Max(1, preview.PixelHeight * scale);
            PreviewImage.Width = previewWidth;
            PreviewImage.Height = previewHeight;
            PreviewContainer.Width = previewWidth;
            PreviewContainer.Height = previewHeight;
            ViewportCanvas.Width = previewWidth;
            ViewportCanvas.Height = previewHeight;

            PreviewBorder.Visibility = Visibility.Visible;
            UpdateViewportIndicator();
            PositionControls();
        }
        catch (Exception error)
        {
            System.Diagnostics.Debug.WriteLine($"Long screenshot preview skipped: {error.Message}");
        }
    }

    private void UpdateViewportIndicator()
    {
        if (_stitcher == null || PreviewBorder.Visibility != Visibility.Visible || PreviewImage.Height <= 0)
        {
            return;
        }

        try
        {
            var dims = _stitcher.GetDimensions();
            if (dims.Height > 0)
            {
                double previewWidth = PreviewImage.Width;
                double previewHeight = PreviewImage.Height;
                double viewportHeight = _activeCaptureRegion.Height > 0
                    ? _activeCaptureRegion.Height
                    : _cropRect.Height;
                double viewportFraction = Math.Min(1.0, viewportHeight / dims.Height);
                double offsetFraction = Math.Clamp((double)dims.Offset / dims.Height, 0.0, 1.0);

                double indicatorHeight = Math.Max(8, Math.Min(previewHeight, previewHeight * viewportFraction));
                double indicatorTop = Math.Clamp(previewHeight * offsetFraction, 0, Math.Max(0, previewHeight - indicatorHeight));

                Canvas.SetLeft(ViewportIndicator, 0);
                Canvas.SetTop(ViewportIndicator, indicatorTop);
                ViewportIndicator.Width = previewWidth;
                ViewportIndicator.Height = indicatorHeight;
                ViewportIndicator.Visibility = Visibility.Visible;
            }
            else
            {
                ViewportIndicator.Visibility = Visibility.Collapsed;
            }
        }
        catch (Exception error)
        {
            System.Diagnostics.Debug.WriteLine($"Viewport indicator update skipped: {error.Message}");
        }
    }

    private void OnPinClick(object sender, RoutedEventArgs e) => CompleteCapture(pin: true);

    private void OnCopyClick(object sender, RoutedEventArgs e) => CompleteCapture(pin: false);

    private async void CompleteCapture(bool pin)
    {
        _captureTimer.Stop();
        while (_isCapturingFrame)
        {
            await Task.Delay(20);
        }

        if (_stitcher == null)
        {
            CloseSession();
            return;
        }

        try
        {
            var stitcher = _stitcher;
            BitmapSource finalBitmap = await Task.Run(() => CreateBitmapSource(stitcher.Render()));
            if (pin)
            {
                var pinWindow = new PinWindow(
                    finalBitmap,
                    _translationService,
                    _configuration,
                    source: PinArchiveSource.LongScreenshot,
                    saveToHistory: true);

                Rect workArea = SystemParameters.WorkArea;
                double targetWidth = pinWindow.PinImage.Width;
                double targetHeight = pinWindow.PinImage.Height;

                double targetX = Left + _cropRect.X;
                if (targetX + targetWidth > workArea.Right - 10)
                {
                    targetX = workArea.Right - 10 - targetWidth;
                }
                if (targetX < workArea.Left + 10)
                {
                    targetX = workArea.Left + 10;
                }

                double targetY = Top + _cropRect.Y;
                if (targetY + targetHeight > workArea.Bottom - 10)
                {
                    targetY = workArea.Bottom - 10 - targetHeight;
                }
                if (targetY < workArea.Top + 10)
                {
                    targetY = workArea.Top + 10;
                }

                Point pinOrigin = PinWindow.WindowOriginForContentFrame(
                    new Rect(targetX, targetY, targetWidth, targetHeight));
                pinWindow.Left = pinOrigin.X;
                pinWindow.Top = pinOrigin.Y;
                pinWindow.Show();
            }
            else
            {
                Clipboard.SetImage(finalBitmap);
                if (_configuration?.SaveCompletedScreenshotsToHistory == true)
                {
                    PinArchiveRecording.Record(finalBitmap, PinArchiveSource.LongScreenshot);
                }
            }
            CloseSession();
        }
        catch (Exception error)
        {
            MessageBox.Show($"长截图生成失败：{error.Message}", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Warning);
            _captureTimer.Start();
        }
    }

    private static BitmapSource CreateBitmapSource(RgbaImageBuffer image)
    {
        byte[] bgraPixels = image.CopyBgraPixels();
        var bitmap = BitmapSource.Create(
            checked((int)image.Width),
            checked((int)image.Height),
            96,
            96,
            PixelFormats.Bgra32,
            palette: null,
            bgraPixels,
            image.Stride);
        bitmap.Freeze();
        return bitmap;
    }

    private void OnCancelClick(object sender, RoutedEventArgs e) => CloseSession();

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            CloseSession();
        }
        else if (e.Key == Key.Enter && _phase == SessionPhase.Capturing)
        {
            CompleteCapture(pin: false);
        }
    }

    private async void CloseSession()
    {
        if (IsMouseCaptured)
        {
            ReleaseMouseCapture();
        }
        _captureTimer.Stop();
        while (_isCapturingFrame)
        {
            await Task.Delay(20);
        }
        _stitcher?.Dispose();
        _stitcher = null;
        Close();
    }

    private void UpdateSelectionDisplay()
    {
        SelectionBorder.Visibility = Visibility.Visible;
        StatusBadge.Visibility = Visibility.Visible;
        Canvas.SetLeft(SelectionBorder, _cropRect.X);
        Canvas.SetTop(SelectionBorder, _cropRect.Y);
        SelectionBorder.Width = _cropRect.Width;
        SelectionBorder.Height = _cropRect.Height;

        double badgeTop = _cropRect.Top - 34;
        if (badgeTop < 6)
        {
            badgeTop = _cropRect.Bottom + 6;
        }
        Canvas.SetLeft(StatusBadge, _cropRect.Left + 4);
        Canvas.SetTop(StatusBadge, badgeTop);
        UpdateMask(_cropRect);
    }

    private void PositionControls()
    {
        const double toolbarWidth = 132;
        const double toolbarHeight = 44;
        double toolbarLeft = Math.Clamp(
            _cropRect.Right - toolbarWidth,
            10,
            Math.Max(10, Width - toolbarWidth - 10));
        double toolbarTop = _cropRect.Bottom + 10;
        if (toolbarTop + toolbarHeight > Height - 10)
        {
            toolbarTop = Math.Max(10, _cropRect.Top - toolbarHeight - 10);
        }
        Canvas.SetLeft(ControlToolbar, toolbarLeft);
        Canvas.SetTop(ControlToolbar, toolbarTop);

        if (PreviewBorder.Visibility == Visibility.Visible)
        {
            double previewWidth = PreviewImage.Width + 12;
            double previewHeight = PreviewImage.Height + 12;
            const double gap = 10;
            const double margin = 8;
            double previewLeft;
            double previewTop;

            if (_cropRect.Right + gap + previewWidth <= Width - margin)
            {
                previewLeft = _cropRect.Right + gap;
                previewTop = Math.Clamp(
                    _cropRect.Top,
                    margin,
                    Math.Max(margin, Height - previewHeight - margin));
            }
            else if (_cropRect.Left - gap - previewWidth >= margin)
            {
                previewLeft = _cropRect.Left - gap - previewWidth;
                previewTop = Math.Clamp(
                    _cropRect.Top,
                    margin,
                    Math.Max(margin, Height - previewHeight - margin));
            }
            else if (_cropRect.Bottom + gap + previewHeight <= Height - margin)
            {
                previewLeft = Math.Clamp(
                    _cropRect.Left,
                    margin,
                    Math.Max(margin, Width - previewWidth - margin));
                previewTop = _cropRect.Bottom + gap;
            }
            else if (_cropRect.Top - gap - previewHeight >= margin)
            {
                previewLeft = Math.Clamp(
                    _cropRect.Left,
                    margin,
                    Math.Max(margin, Width - previewWidth - margin));
                previewTop = _cropRect.Top - gap - previewHeight;
            }
            else
            {
                // A full-screen selection leaves nowhere to show a thumbnail
                // without recording it. Prefer an uncontaminated screenshot.
                PreviewBorder.Visibility = Visibility.Collapsed;
                return;
            }

            Canvas.SetLeft(PreviewBorder, previewLeft);
            Canvas.SetTop(PreviewBorder, previewTop);
        }
    }

    private void UpdateMask(Rect hole)
    {
        if (hole.IsEmpty || hole.Width <= 0 || hole.Height <= 0)
        {
            Canvas.SetLeft(MaskTop, 0);
            Canvas.SetTop(MaskTop, 0);
            MaskTop.Width = Width;
            MaskTop.Height = Height;
            MaskBottom.Width = 0;
            MaskLeft.Width = 0;
            MaskRight.Width = 0;
            return;
        }

        Canvas.SetLeft(MaskTop, 0);
        Canvas.SetTop(MaskTop, 0);
        MaskTop.Width = Width;
        MaskTop.Height = Math.Max(0, hole.Top);
        Canvas.SetLeft(MaskBottom, 0);
        Canvas.SetTop(MaskBottom, hole.Bottom);
        MaskBottom.Width = Width;
        MaskBottom.Height = Math.Max(0, Height - hole.Bottom);
        Canvas.SetLeft(MaskLeft, 0);
        Canvas.SetTop(MaskLeft, hole.Top);
        MaskLeft.Width = Math.Max(0, hole.Left);
        MaskLeft.Height = hole.Height;
        Canvas.SetLeft(MaskRight, hole.Right);
        Canvas.SetTop(MaskRight, hole.Top);
        MaskRight.Width = Math.Max(0, Width - hole.Right);
        MaskRight.Height = hole.Height;
    }
}
