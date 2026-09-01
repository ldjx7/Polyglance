using System.Windows;
using Polyglance.Platform.Capture;

namespace Polyglance.Platform.Tests;

public sealed class CaptureRegionGeometryTests
{
    [Fact]
    public void AtHundredPercentScalingDipsAreAlreadyBitmapPixels()
    {
        var region = CaptureRegionGeometry.ToBitmapRegion(
            new Rect(100, 80, 640, 360),
            new Size(1920, 1080),
            bitmapPixelWidth: 1920,
            bitmapPixelHeight: 1080);

        Assert.Equal(new Int32Rect(100, 80, 640, 360), region);
    }

    [Theory]
    [InlineData(1.25)]
    [InlineData(1.5)]
    [InlineData(2.0)]
    public void ScaledDisplaysMapTheSelectionOntoTheLargerBitmap(double scale)
    {
        // The overlay lays out in DIPs while the bitmap holds physical pixels, so
        // the same selection must land proportionally further into the bitmap.
        var viewSize = new Size(1600, 900);
        int bitmapWidth = (int)(viewSize.Width * scale);
        int bitmapHeight = (int)(viewSize.Height * scale);

        var region = CaptureRegionGeometry.ToBitmapRegion(
            new Rect(200, 100, 400, 200),
            viewSize,
            bitmapWidth,
            bitmapHeight);

        Assert.Equal((int)(200 * scale), region.X);
        Assert.Equal((int)(100 * scale), region.Y);
        Assert.Equal((int)(400 * scale), region.Width);
        Assert.Equal((int)(200 * scale), region.Height);
    }

    [Fact]
    public void FractionalSelectionsRoundOutwardSoEdgeContentSurvives()
    {
        var region = CaptureRegionGeometry.ToBitmapRegion(
            new Rect(0.4, 0.4, 10.2, 10.2),
            new Size(100, 100),
            bitmapPixelWidth: 100,
            bitmapPixelHeight: 100);

        Assert.Equal(0, region.X);
        Assert.Equal(0, region.Y);
        Assert.Equal(11, region.Width);
        Assert.Equal(11, region.Height);
    }

    [Fact]
    public void SelectionsAreClippedToTheBitmapInsteadOfOverrunningIt()
    {
        var region = CaptureRegionGeometry.ToBitmapRegion(
            new Rect(900, 900, 400, 400),
            new Size(1000, 1000),
            bitmapPixelWidth: 1000,
            bitmapPixelHeight: 1000);

        Assert.Equal(new Int32Rect(900, 900, 100, 100), region);
    }

    [Fact]
    public void DegenerateInputsYieldAnEmptyRegionRatherThanThrowing()
    {
        Assert.Equal(
            Int32Rect.Empty,
            CaptureRegionGeometry.ToBitmapRegion(
                new Rect(10, 10, 10, 10), new Size(0, 100), 100, 100));

        Assert.Equal(
            Int32Rect.Empty,
            CaptureRegionGeometry.ToBitmapRegion(
                new Rect(10, 10, 10, 10), new Size(100, 100), 0, 100));

        Assert.Equal(
            Int32Rect.Empty,
            CaptureRegionGeometry.ToBitmapRegion(
                Rect.Empty, new Size(100, 100), 100, 100));
    }

    [Fact]
    public void SelectionFullyOutsideTheViewIsEmpty()
    {
        Assert.Equal(
            Int32Rect.Empty,
            CaptureRegionGeometry.ToBitmapRegion(
                new Rect(200, 200, 50, 50), new Size(100, 100), 100, 100));
    }

    [Theory]
    [InlineData(1.0, 50, 40, 50, 40)]
    [InlineData(1.5, 50, 40, 75, 60)]
    [InlineData(2.0, 50, 40, 100, 80)]
    public void PointerSamplingFollowsTheSameScaleAsCropping(
        double scale,
        double dipX,
        double dipY,
        int expectedX,
        int expectedY)
    {
        var viewSize = new Size(800, 600);

        var (x, y) = CaptureRegionGeometry.ToBitmapPoint(
            new Point(dipX, dipY),
            viewSize,
            (int)(viewSize.Width * scale),
            (int)(viewSize.Height * scale));

        Assert.Equal(expectedX, x);
        Assert.Equal(expectedY, y);
    }

    [Fact]
    public void PointerSamplingStaysInsideTheBitmapAtTheFarEdge()
    {
        var (x, y) = CaptureRegionGeometry.ToBitmapPoint(
            new Point(800, 600),
            new Size(800, 600),
            bitmapPixelWidth: 1200,
            bitmapPixelHeight: 900);

        Assert.Equal(1199, x);
        Assert.Equal(899, y);
    }

    [Fact]
    public void NonUniformScaleIsHandledPerAxis()
    {
        // A stretched background can scale differently on each axis; the mapping
        // must not assume a single uniform factor.
        var region = CaptureRegionGeometry.ToBitmapRegion(
            new Rect(10, 10, 20, 20),
            new Size(100, 200),
            bitmapPixelWidth: 200,
            bitmapPixelHeight: 200);

        Assert.Equal(new Int32Rect(20, 10, 40, 20), region);
    }

    [Fact]
    public void SelectionCanCrossTheSeamBetweenTwoDisplays()
    {
        var region = CaptureRegionGeometry.ToBitmapRegion(
            new Rect(1800, 120, 400, 600),
            new Size(3840, 1080),
            bitmapPixelWidth: 3840,
            bitmapPixelHeight: 1080);

        Assert.Equal(new Int32Rect(1800, 120, 400, 600), region);
    }
}
