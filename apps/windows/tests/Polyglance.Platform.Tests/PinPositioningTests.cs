using System;
using Polyglance.Platform.Pin;
using Xunit;

namespace Polyglance.Platform.Tests;

public sealed class PinPositioningTests
{
    private const double ContentInset = 9.0;

    [Fact]
    public void PlacementAt100PercentScaleCentered()
    {
        // 100% scale (DPI = 1.0)
        var placement = PinPositioning.CalculatePlacement(
            pixelWidth: 800,
            pixelHeight: 600,
            cursorPhysicalX: 960,
            cursorPhysicalY: 540,
            workAreaPhysicalX: 0,
            workAreaPhysicalY: 0,
            workAreaPhysicalWidth: 1920,
            workAreaPhysicalHeight: 1080,
            dpiScale: 1.0,
            contentInsetDips: ContentInset);

        Assert.Equal(800, placement.ImageWidthDips);
        Assert.Equal(600, placement.ImageHeightDips);
        Assert.Equal(818, placement.WindowWidthDips);
        Assert.Equal(618, placement.WindowHeightDips);
        Assert.Equal(551, placement.WindowLeftDips);
        Assert.Equal(231, placement.WindowTopDips);
    }

    [Fact]
    public void PlacementAt125PercentScale()
    {
        // 125% scale (DPI = 1.25)
        var placement = PinPositioning.CalculatePlacement(
            pixelWidth: 1000,
            pixelHeight: 500,
            cursorPhysicalX: 960,
            cursorPhysicalY: 540,
            workAreaPhysicalX: 0,
            workAreaPhysicalY: 0,
            workAreaPhysicalWidth: 1920,
            workAreaPhysicalHeight: 1080,
            dpiScale: 1.25,
            contentInsetDips: ContentInset);

        // Work area DIP: 1920 / 1.25 = 1536, 1080 / 1.25 = 864
        // Cursor DIP: 960 / 1.25 = 768, 540 / 1.25 = 432
        Assert.Equal(1000, placement.ImageWidthDips);
        Assert.Equal(500, placement.ImageHeightDips);
        Assert.Equal(1018, placement.WindowWidthDips);
        Assert.Equal(518, placement.WindowHeightDips);
        Assert.Equal(259, placement.WindowLeftDips);
        Assert.Equal(173, placement.WindowTopDips);
    }

    [Fact]
    public void PlacementAt150PercentScale_ConstrainedWhenImageTooLarge()
    {
        // 150% scale (DPI = 1.5)
        // Work area DIP: 1920 / 1.5 = 1280, 1080 / 1.5 = 720
        // Available for image: 1280 - 18 = 1262, 720 - 18 = 702
        var placement = PinPositioning.CalculatePlacement(
            pixelWidth: 2524,
            pixelHeight: 1404,
            cursorPhysicalX: 960,
            cursorPhysicalY: 540,
            workAreaPhysicalX: 0,
            workAreaPhysicalY: 0,
            workAreaPhysicalWidth: 1920,
            workAreaPhysicalHeight: 1080,
            dpiScale: 1.5,
            contentInsetDips: ContentInset);

        Assert.Equal(1262, Math.Round(placement.ImageWidthDips));
        Assert.Equal(702, Math.Round(placement.ImageHeightDips));
        Assert.Equal(1280, Math.Round(placement.WindowWidthDips));
        Assert.Equal(720, Math.Round(placement.WindowHeightDips));
        Assert.Equal(0, Math.Round(placement.WindowLeftDips));
        Assert.Equal(0, Math.Round(placement.WindowTopDips));
    }

    [Fact]
    public void PlacementAt200PercentScale()
    {
        // 200% scale (DPI = 2.0)
        // 4K monitor: 3840x2160 physical -> 1920x1080 DIP
        var placement = PinPositioning.CalculatePlacement(
            pixelWidth: 800,
            pixelHeight: 600,
            cursorPhysicalX: 1920,
            cursorPhysicalY: 1080,
            workAreaPhysicalX: 0,
            workAreaPhysicalY: 0,
            workAreaPhysicalWidth: 3840,
            workAreaPhysicalHeight: 2160,
            dpiScale: 2.0,
            contentInsetDips: ContentInset);

        // Cursor DIP: 1920 / 2 = 960, 1080 / 2 = 540
        Assert.Equal(800, placement.ImageWidthDips);
        Assert.Equal(600, placement.ImageHeightDips);
        Assert.Equal(818, placement.WindowWidthDips);
        Assert.Equal(618, placement.WindowHeightDips);
        Assert.Equal(960 - 409, placement.WindowLeftDips);
        Assert.Equal(540 - 309, placement.WindowTopDips);
    }

    [Fact]
    public void PlacementOnSecondaryMonitorWithNegativeCoordinates()
    {
        // Secondary monitor on left: X = -1920, Y = 0, Width = 1920, Height = 1080, DPI = 1.0
        var placement = PinPositioning.CalculatePlacement(
            pixelWidth: 600,
            pixelHeight: 400,
            cursorPhysicalX: -960,
            cursorPhysicalY: 540,
            workAreaPhysicalX: -1920,
            workAreaPhysicalY: 0,
            workAreaPhysicalWidth: 1920,
            workAreaPhysicalHeight: 1080,
            dpiScale: 1.0,
            contentInsetDips: ContentInset);

        Assert.Equal(600, placement.ImageWidthDips);
        Assert.Equal(400, placement.ImageHeightDips);
        Assert.Equal(618, placement.WindowWidthDips);
        Assert.Equal(418, placement.WindowHeightDips);
        Assert.Equal(-960 - 309, placement.WindowLeftDips);
        Assert.Equal(540 - 209, placement.WindowTopDips);

        Assert.True(placement.WindowLeftDips >= -1920);
        Assert.True(placement.WindowLeftDips + placement.WindowWidthDips <= 0);
        Assert.True(placement.WindowTopDips >= 0);
        Assert.True(placement.WindowTopDips + placement.WindowHeightDips <= 1080);
    }

    [Fact]
    public void PlacementClampedWhenCursorAtScreenEdge()
    {
        // Near top-left edge
        var placementTopLeft = PinPositioning.CalculatePlacement(
            pixelWidth: 400,
            pixelHeight: 300,
            cursorPhysicalX: 10,
            cursorPhysicalY: 10,
            workAreaPhysicalX: 0,
            workAreaPhysicalY: 0,
            workAreaPhysicalWidth: 1920,
            workAreaPhysicalHeight: 1080,
            dpiScale: 1.0,
            contentInsetDips: ContentInset);

        Assert.Equal(0, placementTopLeft.WindowLeftDips);
        Assert.Equal(0, placementTopLeft.WindowTopDips);

        // Near bottom-right edge
        var placementBottomRight = PinPositioning.CalculatePlacement(
            pixelWidth: 400,
            pixelHeight: 300,
            cursorPhysicalX: 1910,
            cursorPhysicalY: 1070,
            workAreaPhysicalX: 0,
            workAreaPhysicalY: 0,
            workAreaPhysicalWidth: 1920,
            workAreaPhysicalHeight: 1080,
            dpiScale: 1.0,
            contentInsetDips: ContentInset);

        Assert.Equal(1920 - 418, placementBottomRight.WindowLeftDips);
        Assert.Equal(1080 - 318, placementBottomRight.WindowTopDips);
    }
}
