using System.Windows;
using Polyglance.Platform.Capture;
using Polyglance.Platform.Interop;

namespace Polyglance.Platform.Tests;

public sealed class ScreenCursorOverlayTests
{
    [Fact]
    public void InitializesCursorInfoAndTreatsQueryFailureAsBestEffort()
    {
        var native = new FakeCursorNative { CursorInfoSucceeds = false };

        var result = ScreenCursorOverlay.TryDraw(
            IntPtr.Zero,
            new Int32Rect(0, 0, 640, 480),
            native);

        Assert.False(result);
        Assert.Equal(
            System.Runtime.InteropServices.Marshal.SizeOf<NativeWin32.CURSORINFO>(),
            native.ReceivedCursorInfoSize);
    }

    [Fact]
    public void DrawsAtHotspotAdjustedPositionAndAlwaysReleasesCursorBitmaps()
    {
        var native = new FakeCursorNative
        {
            CopiedCursor = new IntPtr(8),
            CursorInfo = new NativeWin32.CURSORINFO
            {
                flags = NativeWin32.CURSOR_SHOWING,
                hCursor = new IntPtr(3),
                ptScreenPos = new NativeWin32.POINT { X = 130, Y = 85 },
            },
            IconInfo = new NativeWin32.ICONINFO
            {
                xHotspot = 4,
                yHotspot = 5,
                hbmColor = new IntPtr(4),
                hbmMask = new IntPtr(5),
            },
        };

        var result = ScreenCursorOverlay.TryDraw(
            IntPtr.Zero,
            new Int32Rect(100, 50, 640, 480),
            native);

        Assert.True(result);
        Assert.Equal((26, 30), native.DrawPosition);
        Assert.Equal(new IntPtr(8), native.DrawnCursor);
        Assert.Equal([new IntPtr(8)], native.DestroyedIcons);
        Assert.Equal([new IntPtr(4), new IntPtr(5)], native.DeletedObjects);
    }

    [Fact]
    public void RemoteSessionUsesStableArrowInsteadOfRemoteCursorBitmap()
    {
        var native = new FakeCursorNative
        {
            IsRemoteSession = true,
            ArrowCursor = new IntPtr(9),
            CursorInfo = new NativeWin32.CURSORINFO
            {
                flags = NativeWin32.CURSOR_SHOWING,
                hCursor = new IntPtr(3),
                ptScreenPos = new NativeWin32.POINT { X = 130, Y = 85 },
            },
            IconInfo = new NativeWin32.ICONINFO
            {
                xHotspot = 4,
                yHotspot = 5,
                hbmColor = new IntPtr(4),
                hbmMask = new IntPtr(5),
            },
        };

        var result = ScreenCursorOverlay.TryDraw(
            IntPtr.Zero,
            new Int32Rect(100, 50, 640, 480),
            native);

        Assert.True(result);
        Assert.Equal(new IntPtr(9), native.DrawnCursor);
        Assert.Empty(native.CopiedIcons);
        Assert.Empty(native.DestroyedIcons);
    }

    [Fact]
    public void LocalCursorCopyFailureFallsBackToStableArrow()
    {
        var native = new FakeCursorNative
        {
            CopiedCursor = IntPtr.Zero,
            ArrowCursor = new IntPtr(9),
            CursorInfo = new NativeWin32.CURSORINFO
            {
                flags = NativeWin32.CURSOR_SHOWING,
                hCursor = new IntPtr(3),
                ptScreenPos = new NativeWin32.POINT { X = 130, Y = 85 },
            },
            IconInfo = new NativeWin32.ICONINFO(),
        };

        var result = ScreenCursorOverlay.TryDraw(
            IntPtr.Zero,
            new Int32Rect(100, 50, 640, 480),
            native);

        Assert.True(result);
        Assert.Equal(new IntPtr(9), native.DrawnCursor);
        Assert.Equal([new IntPtr(3)], native.CopiedIcons);
        Assert.Empty(native.DestroyedIcons);
    }

    private sealed class FakeCursorNative : IScreenCursorNative
    {
        public bool IsRemoteSession { get; init; }
        public IntPtr ArrowCursor { get; init; } = new IntPtr(9);
        public IntPtr CopiedCursor { get; init; } = new IntPtr(8);
        public bool CursorInfoSucceeds { get; init; } = true;
        public NativeWin32.CURSORINFO CursorInfo { get; init; }
        public NativeWin32.ICONINFO IconInfo { get; init; }
        public int ReceivedCursorInfoSize { get; private set; }
        public (int X, int Y)? DrawPosition { get; private set; }
        public IntPtr? DrawnCursor { get; private set; }
        public List<IntPtr> CopiedIcons { get; } = [];
        public List<IntPtr> DestroyedIcons { get; } = [];
        public List<IntPtr> DeletedObjects { get; } = [];

        public IntPtr CopyIcon(IntPtr cursor)
        {
            CopiedIcons.Add(cursor);
            return CopiedCursor;
        }

        public IntPtr LoadArrowCursor() => ArrowCursor;

        public void DestroyIcon(IntPtr cursor) => DestroyedIcons.Add(cursor);

        public bool GetCursorInfo(ref NativeWin32.CURSORINFO cursorInfo)
        {
            ReceivedCursorInfoSize = cursorInfo.cbSize;
            if (!CursorInfoSucceeds) return false;
            var initializedSize = cursorInfo.cbSize;
            cursorInfo = CursorInfo;
            cursorInfo.cbSize = initializedSize;
            return true;
        }

        public bool GetIconInfo(IntPtr cursor, out NativeWin32.ICONINFO iconInfo)
        {
            iconInfo = IconInfo;
            return true;
        }

        public bool DrawIcon(IntPtr destination, int x, int y, IntPtr cursor)
        {
            DrawPosition = (x, y);
            DrawnCursor = cursor;
            return true;
        }

        public void DeleteObject(IntPtr value) => DeletedObjects.Add(value);
    }
}
