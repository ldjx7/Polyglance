using System.Windows;
using System.Windows.Media;
using Polyglance.Platform.Recording;

namespace Polyglance.Platform.Tests;

public sealed class ScreenRecordingCaptureGeometryTests
{
    [Fact]
    public void ConvertsLocalDipSelectionToPhysicalDesktopPixels()
    {
        var result = ScreenRecordingCaptureGeometry.ToPhysicalRegion(
            screenOriginInPixels: new Point(-2560, 0),
            localRegionInDips: new Rect(100, 80, 640, 360),
            transformToDevice: new Matrix(1.5, 0, 0, 1.5, 0, 0));

        Assert.Equal(-2410, result.X);
        Assert.Equal(120, result.Y);
        Assert.Equal(960, result.Width);
        Assert.Equal(540, result.Height);
    }

    [Fact]
    public void RoundsOutwardSoThePhysicalSelectionIsNotClipped()
    {
        var result = ScreenRecordingCaptureGeometry.ToPhysicalRegion(
            screenOriginInPixels: new Point(0, 0),
            localRegionInDips: new Rect(0.4, 0.4, 10.2, 10.2),
            transformToDevice: Matrix.Identity);

        Assert.Equal(0, result.X);
        Assert.Equal(0, result.Y);
        Assert.Equal(11, result.Width);
        Assert.Equal(11, result.Height);
    }
}
