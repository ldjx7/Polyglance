using System.Windows;
using Polyglance.Platform.Capture;

namespace Polyglance.Platform.Tests;

public sealed class ScreenCaptureRegionTests
{
    [Fact]
    public void InsetOverlayBorder_RemovesSelectionBorderFromEveryEdge()
    {
        var selection = new Int32Rect(100, 200, 800, 600);

        Int32Rect capture = ScreenCapture.InsetOverlayBorder(selection, 4);

        Assert.Equal(new Int32Rect(104, 204, 792, 592), capture);
    }

    [Fact]
    public void InsetOverlayBorder_ClampsInsetAndPreservesAtLeastOnePixel()
    {
        var selection = new Int32Rect(10, 20, 5, 3);

        Int32Rect capture = ScreenCapture.InsetOverlayBorder(selection, 100);

        Assert.Equal(new Int32Rect(11, 21, 3, 1), capture);
    }

    [Fact]
    public void InsetOverlayBorder_TreatsNegativeInsetAsZero()
    {
        var selection = new Int32Rect(10, 20, 30, 40);

        Int32Rect capture = ScreenCapture.InsetOverlayBorder(selection, -2);

        Assert.Equal(selection, capture);
    }
}
