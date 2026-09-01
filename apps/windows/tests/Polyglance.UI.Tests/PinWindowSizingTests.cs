using System.Windows;
using Polyglance.UI.Views;

namespace Polyglance.UI.Tests;

public sealed class PinWindowSizingTests
{
    [Fact]
    public void WindowOriginOffsetsShadowChromeSoPinnedContentDoesNotMove()
    {
        Point origin = PinWindow.WindowOriginForContentFrame(
            new Rect(100, 200, 640, 360));

        Assert.Equal(new Point(91, 191), origin);
    }

    [Fact]
    public void CapturedDisplaySizePreservesFullScreenWidthAtHighDpi()
    {
        Size size = PinWindow.CalculateInitialDisplaySize(
            bitmapPixelSize: new Size(3840, 2160),
            capturedDisplaySize: new Size(1920, 1080),
            maximumDisplaySize: new Size(1920, 1080));

        Assert.Equal(new Size(1920, 1080), size);
    }

    [Fact]
    public void BitmapWithoutCapturedDisplaySizeFitsOnlyWhenLargerThanScreen()
    {
        Size size = PinWindow.CalculateInitialDisplaySize(
            bitmapPixelSize: new Size(2400, 1200),
            capturedDisplaySize: null,
            maximumDisplaySize: new Size(1920, 1080));

        Assert.Equal(new Size(1920, 960), size);
    }
}
