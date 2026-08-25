using System;
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
using Polyglance.Platform.Interop;

namespace Polyglance.UI.Views;

public partial class LongScreenshotSessionWindow : Window
{
    // The transparent WPF overlay is still included by GDI BitBlt on some
    // Windows/RDP configurations. Capture just inside the selection chrome so
    // its blue border and shadow never become part of every stitched frame.
    private const int CaptureOverlayGuardPixels = 6;

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
        _captureTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(110) };
        _captureTimer.Tick += (_, _) => CaptureAndAppendCurrentFrame();
        SourceInitialized += (_, _) =>
        {
            IntPtr handle = new WindowInteropHelper(this).Handle;
            _ = NativeWin32.SetWindowDisplayAffinity(handle, NativeWin32.WDA_EXCLUDEFROMCAPTURE);
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

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        Point point = e.GetPosition(this);
        if (ControlToolbar.IsMouseOver || PreviewBorder.IsMouseOver)
        {
            return;
        }

        if (e.RightButton == MouseButtonState.Pressed)
        {
            CloseSession();
            return;
        }

        if (e.LeftButton == MouseButtonState.Pressed && _phase == SessionPhase.SelectingRegion)
        {
            _dragStart = point;
            _cropRect = new Rect(point, new Size(0, 0));
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
        ControlToolbar.Visibility = Visibility.Visible;
        TxtStatus.Text = "滚动页面以继续捕获";
        PositionControls();

        var (centreX, centreY) = CaptureCentreScreenPoint();
        _scrollTarget = UnderlyingWindowScroller.FindTarget(centreX, centreY);

        Dispatcher.BeginInvoke(DispatcherPriority.ContextIdle, () =>
        {
            CaptureAndAppendCurrentFrame();
            _captureTimer.Start();
        });
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
        if (_isCapturingFrame || _stitcher == null || _cropRect.Width <= 0 || _cropRect.Height <= 0)
        {
            return;
        }

        _isCapturingFrame = true;
        try
        {
            Int32Rect selectionRegion = SelectionPhysicalRegion();
            Int32Rect region = ScreenCapture.InsetOverlayBorder(
                selectionRegion,
                CaptureOverlayGuardPixels);
            var frame = ScreenCapture.CaptureRegion(region, showCursor: false);
            byte[] rgba = ScreenCapture.GetRgbaBytes(frame);
            var result = _stitcher.AppendFrame(rgba, (uint)frame.PixelWidth, (uint)frame.PixelHeight);
            if (result.FrameCount != _lastPreviewFrameCount)
            {
                _lastPreviewFrameCount = result.FrameCount;
                UpdatePreview();
            }
            if (result.LimitReached != 0)
            {
                _captureTimer.Stop();
                TxtStatus.Text = "已达到最大长度，请贴图或复制";
            }
        }
        catch (Exception error)
        {
            // A frame without reliable overlap is recoverable while the user is
            // stationary or an animation is running. Keep the session alive.
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
            PreviewImage.Width = Math.Max(1, preview.PixelWidth * scale);
            PreviewImage.Height = Math.Max(1, preview.PixelHeight * scale);
            PreviewBorder.Visibility = Visibility.Visible;
            PositionControls();
        }
        catch (Exception error)
        {
            System.Diagnostics.Debug.WriteLine($"Long screenshot preview skipped: {error.Message}");
        }
    }

    private void OnPinClick(object sender, RoutedEventArgs e) => CompleteCapture(pin: true);

    private void OnCopyClick(object sender, RoutedEventArgs e) => CompleteCapture(pin: false);

    private void CompleteCapture(bool pin)
    {
        _captureTimer.Stop();
        if (_stitcher == null)
        {
            CloseSession();
            return;
        }

        try
        {
            BitmapSource finalBitmap = CreateBitmapSource(_stitcher.Render());
            if (pin)
            {
                var pinWindow = new PinWindow(finalBitmap, _translationService, _configuration)
                {
                    Left = Left + _cropRect.X,
                    Top = Top + _cropRect.Y
                };
                pinWindow.Show();
            }
            else
            {
                Clipboard.SetImage(finalBitmap);
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

    private void CloseSession()
    {
        _captureTimer.Stop();
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
