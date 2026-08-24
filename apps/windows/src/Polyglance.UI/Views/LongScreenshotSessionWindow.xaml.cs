using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.Platform.Capture;

namespace Polyglance.UI.Views;

public partial class LongScreenshotSessionWindow : Window
{
    private enum SessionPhase
    {
        SelectingRegion,
        Stitching
    }

    private readonly BitmapSource _fullScreenBitmap;
    private readonly Rect _screenBounds;
    private LongScreenshotService? _stitcher;
    private SessionPhase _phase = SessionPhase.SelectingRegion;
    private Point _dragStart;
    private Rect _cropRect = Rect.Empty;
    private DispatcherTimer? _autoScrollTimer;
    private uint _frameCount = 0;
    private uint _stitchedHeight = 0;

    public LongScreenshotSessionWindow(BitmapSource fullScreenBitmap, Rect screenBounds)
    {
        InitializeComponent();

        _fullScreenBitmap = fullScreenBitmap;
        _screenBounds = screenBounds;

        Left = screenBounds.X;
        Top = screenBounds.Y;
        Width = screenBounds.Width;
        Height = screenBounds.Height;

        BackgroundImage.Source = fullScreenBitmap;
        UpdateMask(Rect.Empty);
    }

    public LongScreenshotSessionWindow(BitmapSource fullScreenBitmap, Rect screenBounds, Rect initialCropRect) : this(fullScreenBitmap, screenBounds)
    {
        if (initialCropRect.Width > 20 && initialCropRect.Height > 20)
        {
            _cropRect = initialCropRect;
            UpdateSelectionDisplay();
            StartStitchingSession();
        }
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        Point pt = e.GetPosition(this);
        if (ControlToolbar.IsMouseOver) return;

        if (e.RightButton == MouseButtonState.Pressed)
        {
            CloseSession();
            return;
        }

        if (e.LeftButton == MouseButtonState.Pressed && _phase == SessionPhase.SelectingRegion)
        {
            _dragStart = pt;
            _cropRect = new Rect(pt, new Size(0, 0));
        }
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (_phase == SessionPhase.SelectingRegion && e.LeftButton == MouseButtonState.Pressed)
        {
            Point pt = e.GetPosition(this);
            double x = Math.Min(_dragStart.X, pt.X);
            double y = Math.Min(_dragStart.Y, pt.Y);
            double w = Math.Abs(pt.X - _dragStart.X);
            double h = Math.Abs(pt.Y - _dragStart.Y);

            _cropRect = new Rect(x, y, w, h);
            UpdateSelectionDisplay();
        }
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_phase == SessionPhase.SelectingRegion && _cropRect.Width > 50 && _cropRect.Height > 50)
        {
            StartStitchingSession();
        }
    }

    private void StartStitchingSession()
    {
        _phase = SessionPhase.Stitching;
        _stitcher = new LongScreenshotService();

        ControlToolbar.Visibility = Visibility.Visible;
        double left = Math.Clamp(_cropRect.Right - 280, 10, Width - 290);
        double top = _cropRect.Bottom + 12;
        if (top + 50 > Height) top = _cropRect.Top - 50;

        Canvas.SetLeft(ControlToolbar, left);
        Canvas.SetTop(ControlToolbar, top);

        // Capture initial frame
        CaptureAndAppendCurrentFrame();
    }

    private void OnMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (_phase == SessionPhase.Stitching)
        {
            CaptureAndAppendCurrentFrame();
        }
    }

    private void CaptureAndAppendCurrentFrame()
    {
        if (_stitcher == null || _cropRect.Width <= 0 || _cropRect.Height <= 0) return;

        try
        {
            // Capture fresh screen
            var (freshFull, _) = ScreenCapture.CaptureVirtualScreen();
            var cropped = ScreenCapture.Crop(freshFull, new Int32Rect((int)_cropRect.X, (int)_cropRect.Y, (int)_cropRect.Width, (int)_cropRect.Height));

            // Convert to RGBA
            int width = cropped.PixelWidth;
            int height = cropped.PixelHeight;
            int stride = width * 4;
            byte[] pixels = new byte[height * stride];
            cropped.CopyPixels(pixels, stride, 0);

            // BGR to RGBA conversion
            for (int i = 0; i < pixels.Length; i += 4)
            {
                byte b = pixels[i];
                byte r = pixels[i + 2];
                pixels[i] = r;
                pixels[i + 2] = b;
            }

            var result = _stitcher.AppendFrame(pixels, (uint)width, (uint)height);
            _frameCount++;
            _stitchedHeight = result.TotalHeight;

            TxtStatus.Text = $"已拼接 {_frameCount} 帧 · 总高 {_stitchedHeight}px (继续滚动或完成)";
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Append frame error: {ex.Message}");
        }
    }

    private void OnToggleAutoScrollClick(object sender, RoutedEventArgs e)
    {
        if (_autoScrollTimer == null)
        {
            _autoScrollTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) };
            _autoScrollTimer.Tick += (s, ev) =>
            {
                // Simulate mouse wheel down
                CaptureAndAppendCurrentFrame();
            };
            _autoScrollTimer.Start();
            BtnAutoScroll.Content = "暂停滚动";
        }
        else
        {
            _autoScrollTimer.Stop();
            _autoScrollTimer = null;
            BtnAutoScroll.Content = "自动滚动";
        }
    }

    private void OnFinishClick(object sender, RoutedEventArgs e)
    {
        _autoScrollTimer?.Stop();
        if (_stitcher == null)
        {
            CloseSession();
            return;
        }

        try
        {
            var rawPngBytes = _stitcher.Render();
            if (rawPngBytes.Length > 0)
            {
                using var ms = new MemoryStream(rawPngBytes);
                var decoder = new PngBitmapDecoder(ms, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                var finalBmp = decoder.Frames[0];

                Clipboard.SetImage(finalBmp);

                var pin = new PinWindow(finalBmp);
                pin.Left = Left + _cropRect.X;
                pin.Top = Top + _cropRect.Y;
                pin.Show();
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show($"拼接完成生成失败: {ex.Message}", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        CloseSession();
    }

    private void OnCancelClick(object sender, RoutedEventArgs e)
    {
        CloseSession();
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            CloseSession();
        }
        else if (e.Key == Key.Enter && _phase == SessionPhase.Stitching)
        {
            OnFinishClick(sender, new RoutedEventArgs());
        }
    }

    private void CloseSession()
    {
        _autoScrollTimer?.Stop();
        _stitcher?.Dispose();
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
        if (badgeTop < 6) badgeTop = _cropRect.Bottom + 6;

        Canvas.SetLeft(StatusBadge, _cropRect.Left + 4);
        Canvas.SetTop(StatusBadge, badgeTop);

        UpdateMask(_cropRect);
    }

    private void UpdateMask(Rect hole)
    {
        if (hole.IsEmpty || hole.Width <= 0 || hole.Height <= 0)
        {
            Canvas.SetLeft(MaskTop, 0);
            Canvas.SetTop(MaskTop, 0);
            MaskTop.Width = Width;
            MaskTop.Height = Height;
            MaskBottom.Width = 0; MaskLeft.Width = 0; MaskRight.Width = 0;
            return;
        }

        Canvas.SetLeft(MaskTop, 0); Canvas.SetTop(MaskTop, 0);
        MaskTop.Width = Width; MaskTop.Height = Math.Max(0, hole.Top);

        Canvas.SetLeft(MaskBottom, 0); Canvas.SetTop(MaskBottom, hole.Bottom);
        MaskBottom.Width = Width; MaskBottom.Height = Math.Max(0, Height - hole.Bottom);

        Canvas.SetLeft(MaskLeft, 0); Canvas.SetTop(MaskLeft, hole.Top);
        MaskLeft.Width = Math.Max(0, hole.Left); MaskLeft.Height = hole.Height;

        Canvas.SetLeft(MaskRight, hole.Right); Canvas.SetTop(MaskRight, hole.Top);
        MaskRight.Width = Math.Max(0, Width - hole.Right); MaskRight.Height = hole.Height;
    }
}
