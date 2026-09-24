using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Polyglance.Core.Native;
using Polyglance.Platform.Capture;
using Polyglance.Platform.Interop;

namespace Polyglance.Platform.Recording;

// 优先采用 Direct3D 11 / Windows.Graphics.Capture 进行 GPU 零阻塞采集；
// 在虚拟机或不支持的环境下平滑回退至 GDI DIBSection + BitBlt。
internal sealed class ScreenRecordingFrameCapture : IDisposable
{
    private readonly Int32Rect _region;
    private readonly IntPtr _screen;
    private readonly IntPtr _memory;
    private readonly IntPtr _bitmap;
    private readonly IntPtr _previous;
    private IntPtr _hardwareCapture;
    private bool _useHardwareCapture;
    private bool _firstFrameCaptured;
    private bool _disposed;
    public IntPtr Pixels { get; }
    public int Length => checked(_region.Width * _region.Height * 4);
    public bool IsHardwareAccelerated => _useHardwareCapture;

    public ScreenRecordingFrameCapture(Int32Rect region)
    {
        _region = new Int32Rect(region.X, region.Y, region.Width & ~1, region.Height & ~1);
        _screen = NativeWin32.GetDC(IntPtr.Zero);
        _memory = NativeWin32.CreateCompatibleDC(_screen);
        var info = new BitmapInfo
        {
            Size = (uint)Marshal.SizeOf<BitmapInfo>(), Width = _region.Width, Height = -_region.Height,
            Planes = 1, BitCount = 32,
        };
        _bitmap = CreateDIBSection(_screen, ref info, 0, out var pixels, IntPtr.Zero, 0);
        Pixels = pixels;
        if (_screen == IntPtr.Zero || _memory == IntPtr.Zero || _bitmap == IntPtr.Zero)
        {
            Dispose();
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "无法初始化录屏像素缓冲区");
        }
        _previous = NativeWin32.SelectObject(_memory, _bitmap);

        try
        {
            int status = NativeMethods.polyglance_windows_capture_new(
                _region.X, _region.Y, _region.Width, _region.Height, true, out _hardwareCapture);
            _useHardwareCapture = (status == 0 && _hardwareCapture != IntPtr.Zero);
        }
        catch
        {
            _useHardwareCapture = false;
            _hardwareCapture = IntPtr.Zero;
        }
    }

    public void Capture(bool showCursor)
    {
        if (_useHardwareCapture)
        {
            int status = NativeMethods.polyglance_windows_capture_frame(
                _hardwareCapture, Pixels, (nuint)Length, showCursor, out bool captured);
            if (status != 0)
            {
                // 运行时硬件采集异常，平滑降级为 GDI
                _useHardwareCapture = false;
                FallbackGdiCapture(showCursor);
            }
            else if (!captured && !_firstFrameCaptured)
            {
                // 首帧若尚未就绪，执行一次 GDI 确保像素缓冲区不为空
                FallbackGdiCapture(showCursor);
                _firstFrameCaptured = true;
            }
            else
            {
                _firstFrameCaptured = true;
            }
            return;
        }

        FallbackGdiCapture(showCursor);
    }

    private void FallbackGdiCapture(bool showCursor)
    {
        if (!NativeWin32.BitBlt(_memory, 0, 0, _region.Width, _region.Height,
                _screen, _region.X, _region.Y, NativeWin32.SRCCOPY | NativeWin32.CAPTUREBLT))
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "无法捕获录屏画面");
        if (showCursor) _ = ScreenCursorOverlay.TryDraw(_memory, _region);
        GdiFlush();
    }

    public BitmapSource CreatePoster()
    {
        var bitmap = BitmapSource.Create(_region.Width, _region.Height, 96, 96,
            PixelFormats.Bgr32, null, Pixels, Length, _region.Width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_hardwareCapture != IntPtr.Zero)
        {
            NativeMethods.polyglance_windows_capture_free(_hardwareCapture);
            _hardwareCapture = IntPtr.Zero;
        }
        if (_previous != IntPtr.Zero) NativeWin32.SelectObject(_memory, _previous);
        if (_bitmap != IntPtr.Zero) NativeWin32.DeleteObject(_bitmap);
        if (_memory != IntPtr.Zero) NativeWin32.DeleteDC(_memory);
        if (_screen != IntPtr.Zero) NativeWin32.ReleaseDC(IntPtr.Zero, _screen);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BitmapInfo
    {
        public uint Size;
        public int Width, Height;
        public ushort Planes, BitCount;
        public uint Compression, SizeImage;
        public int XPelsPerMeter, YPelsPerMeter;
        public uint ClrUsed, ClrImportant;
    }
    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfo info, uint usage,
        out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")]
    private static extern bool GdiFlush();
}
