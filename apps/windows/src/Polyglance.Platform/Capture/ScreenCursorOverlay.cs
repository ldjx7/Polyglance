using System.Runtime.InteropServices;
using System.Windows;
using Polyglance.Platform.Interop;

namespace Polyglance.Platform.Capture;

public interface IScreenCursorNative
{
    bool IsRemoteSession { get; }
    bool GetCursorInfo(ref NativeWin32.CURSORINFO cursorInfo);
    IntPtr CopyIcon(IntPtr cursor);
    IntPtr LoadArrowCursor();
    void DestroyIcon(IntPtr cursor);
    bool GetIconInfo(IntPtr cursor, out NativeWin32.ICONINFO iconInfo);
    bool DrawIcon(IntPtr destination, int x, int y, IntPtr cursor);
    void DeleteObject(IntPtr value);
}

public static class ScreenCursorOverlay
{
    private static readonly IScreenCursorNative Native = new Win32ScreenCursorNative();

    public static bool TryDraw(IntPtr destination, Int32Rect region) =>
        TryDraw(destination, region, Native);

    public static bool TryDraw(
        IntPtr destination,
        Int32Rect region,
        IScreenCursorNative native)
    {
        var cursorInfo = new NativeWin32.CURSORINFO
        {
            cbSize = Marshal.SizeOf<NativeWin32.CURSORINFO>(),
        };
        if (!native.GetCursorInfo(ref cursorInfo))
        {
            return false;
        }
        if ((cursorInfo.flags & NativeWin32.CURSOR_SHOWING) == 0)
        {
            return true;
        }

        var cursorX = cursorInfo.ptScreenPos.X;
        var cursorY = cursorInfo.ptScreenPos.Y;
        if (cursorX < region.X || cursorX >= region.X + region.Width ||
            cursorY < region.Y || cursorY >= region.Y + region.Height)
        {
            return true;
        }
        var ownsDrawableCursor = false;
        var drawableCursor = IntPtr.Zero;
        if (!native.IsRemoteSession)
        {
            drawableCursor = native.CopyIcon(cursorInfo.hCursor);
            ownsDrawableCursor = drawableCursor != IntPtr.Zero;
        }
        if (drawableCursor == IntPtr.Zero)
        {
            // RDP can expose a cursor handle whose alpha/mask data renders as an
            // opaque square in a GDI capture DC. A process-local system cursor is
            // stable and preserves the actual pointer position without corrupting
            // the recorded frame.
            drawableCursor = native.LoadArrowCursor();
        }
        if (drawableCursor == IntPtr.Zero)
        {
            return false;
        }

        NativeWin32.ICONINFO iconInfo = default;
        try
        {
            if (!native.GetIconInfo(drawableCursor, out iconInfo))
            {
                return false;
            }
            return native.DrawIcon(
                destination,
                cursorX - region.X - iconInfo.xHotspot,
                cursorY - region.Y - iconInfo.yHotspot,
                drawableCursor);
        }
        finally
        {
            if (iconInfo.hbmColor != IntPtr.Zero) native.DeleteObject(iconInfo.hbmColor);
            if (iconInfo.hbmMask != IntPtr.Zero) native.DeleteObject(iconInfo.hbmMask);
            if (ownsDrawableCursor) native.DestroyIcon(drawableCursor);
        }
    }

    private sealed class Win32ScreenCursorNative : IScreenCursorNative
    {
        public bool IsRemoteSession =>
            NativeWin32.GetSystemMetrics(NativeWin32.SM_REMOTESESSION) != 0;

        public bool GetCursorInfo(ref NativeWin32.CURSORINFO cursorInfo) =>
            NativeWin32.GetCursorInfo(ref cursorInfo);

        public IntPtr CopyIcon(IntPtr cursor) => NativeWin32.CopyIcon(cursor);

        public IntPtr LoadArrowCursor() =>
            NativeWin32.LoadCursor(IntPtr.Zero, new IntPtr(NativeWin32.IDC_ARROW));

        public void DestroyIcon(IntPtr cursor) => NativeWin32.DestroyIcon(cursor);

        public bool GetIconInfo(IntPtr cursor, out NativeWin32.ICONINFO iconInfo) =>
            NativeWin32.GetIconInfo(cursor, out iconInfo);

        public bool DrawIcon(IntPtr destination, int x, int y, IntPtr cursor) =>
            NativeWin32.DrawIconEx(
                destination,
                x,
                y,
                cursor,
                0,
                0,
                0,
                IntPtr.Zero,
                NativeWin32.DI_NORMAL);

        public void DeleteObject(IntPtr value) => NativeWin32.DeleteObject(value);
    }
}
