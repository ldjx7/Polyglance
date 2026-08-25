using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using Polyglance.Platform.Interop;

namespace Polyglance.Platform.Capture;

public static class ScreenCapture
{
    public static Int32Rect InsetOverlayBorder(Int32Rect region, int inset)
    {
        int requestedInset = Math.Max(0, inset);
        int maximumInset = Math.Min(
            Math.Max(0, (region.Width - 1) / 2),
            Math.Max(0, (region.Height - 1) / 2));
        int appliedInset = Math.Min(requestedInset, maximumInset);

        return new Int32Rect(
            region.X + appliedInset,
            region.Y + appliedInset,
            Math.Max(1, region.Width - appliedInset * 2),
            Math.Max(1, region.Height - appliedInset * 2));
    }

    public static (BitmapSource Bitmap, Rect Bounds) CaptureVirtualScreen()
    {
        int x = NativeWin32.GetSystemMetrics(NativeWin32.SM_XVIRTUALSCREEN);
        int y = NativeWin32.GetSystemMetrics(NativeWin32.SM_YVIRTUALSCREEN);
        int width = NativeWin32.GetSystemMetrics(NativeWin32.SM_CXVIRTUALSCREEN);
        int height = NativeWin32.GetSystemMetrics(NativeWin32.SM_CYVIRTUALSCREEN);

        IntPtr hdcScreen = NativeWin32.GetDC(IntPtr.Zero);
        IntPtr hdcMem = NativeWin32.CreateCompatibleDC(hdcScreen);
        IntPtr hBitmap = NativeWin32.CreateCompatibleBitmap(hdcScreen, width, height);
        IntPtr hOld = NativeWin32.SelectObject(hdcMem, hBitmap);

        NativeWin32.BitBlt(
            hdcMem, 0, 0, width, height,
            hdcScreen, x, y,
            NativeWin32.SRCCOPY | NativeWin32.CAPTUREBLT);

        BitmapSource wpfBitmap = Imaging.CreateBitmapSourceFromHBitmap(
            hBitmap,
            IntPtr.Zero,
            Int32Rect.Empty,
            BitmapSizeOptions.FromEmptyOptions());

        wpfBitmap.Freeze();

        NativeWin32.SelectObject(hdcMem, hOld);
        NativeWin32.DeleteObject(hBitmap);
        NativeWin32.DeleteDC(hdcMem);
        NativeWin32.ReleaseDC(IntPtr.Zero, hdcScreen);

        return (wpfBitmap, new Rect(x, y, width, height));
    }

    public static BitmapSource CaptureRegion(Int32Rect region, bool showCursor = true)
    {
        int width = Math.Max(1, region.Width);
        int height = Math.Max(1, region.Height);

        IntPtr hdcScreen = NativeWin32.GetDC(IntPtr.Zero);
        IntPtr hdcMem = NativeWin32.CreateCompatibleDC(hdcScreen);
        IntPtr hBitmap = NativeWin32.CreateCompatibleBitmap(hdcScreen, width, height);
        IntPtr hOld = NativeWin32.SelectObject(hdcMem, hBitmap);
        try
        {
            if (!NativeWin32.BitBlt(
                    hdcMem, 0, 0, width, height,
                    hdcScreen, region.X, region.Y,
                    NativeWin32.SRCCOPY | NativeWin32.CAPTUREBLT))
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "无法捕获录屏画面");
            }

            if (showCursor)
            {
                // Cursor composition is an optional overlay. A transient cursor API failure
                // (common during RDP cursor-shape changes) must not abort the video capture.
                _ = ScreenCursorOverlay.TryDraw(hdcMem, region);
            }

            BitmapSource wpfBitmap = Imaging.CreateBitmapSourceFromHBitmap(
                hBitmap,
                IntPtr.Zero,
                Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions());
            wpfBitmap.Freeze();
            return wpfBitmap;
        }
        finally
        {
            NativeWin32.SelectObject(hdcMem, hOld);
            NativeWin32.DeleteObject(hBitmap);
            NativeWin32.DeleteDC(hdcMem);
            NativeWin32.ReleaseDC(IntPtr.Zero, hdcScreen);
        }
    }

    public static CroppedBitmap Crop(BitmapSource source, Int32Rect cropArea)
    {
        var cropped = new CroppedBitmap(source, cropArea);
        cropped.Freeze();
        return cropped;
    }

    public static byte[] GetRgbaBytes(BitmapSource bitmap)
    {
        var formatConverted = new FormatConvertedBitmap(bitmap, System.Windows.Media.PixelFormats.Bgra32, null, 0);
        int width = formatConverted.PixelWidth;
        int height = formatConverted.PixelHeight;
        int stride = width * 4;
        byte[] bgra = new byte[height * stride];
        formatConverted.CopyPixels(bgra, stride, 0);

        // Convert BGRA to RGBA (Required by Rust capture-core)
        byte[] rgba = new byte[bgra.Length];
        for (int i = 0; i < bgra.Length; i += 4)
        {
            rgba[i] = bgra[i + 2];     // R
            rgba[i + 1] = bgra[i + 1]; // G
            rgba[i + 2] = bgra[i];     // B
            rgba[i + 3] = bgra[i + 3]; // A
        }
        return rgba;
    }
}
