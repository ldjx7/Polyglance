using Polyglance.Core.Models;

namespace Polyglance.Core.Tests;

public sealed class PixelSampleTests
{
    [Fact]
    public void HexMatchesMacFormatting()
    {
        var sample = new PixelSample(100, 200, 0x12, 0x34, 0x56);

        Assert.Equal("#123456", sample.Hex);
    }

    [Fact]
    public void RgbMatchesMacFormatting()
    {
        var sample = new PixelSample(100, 200, 18, 52, 86);

        Assert.Equal("RGB(18, 52, 86)", sample.Rgb);
    }

    [Fact]
    public void CoordinateTextReportsPhysicalPixels()
    {
        var sample = new PixelSample(100, 200, 0, 0, 0);

        Assert.Equal("(100, 200) px", sample.CoordinateText);
    }

    [Theory]
    [InlineData(ColorDisplayFormat.Hex, "#123456")]
    [InlineData(ColorDisplayFormat.Rgb, "RGB(18, 52, 86)")]
    public void CopiedTextFollowsTheDisplayedFormat(ColorDisplayFormat format, string expected)
    {
        var sample = new PixelSample(0, 0, 0x12, 0x34, 0x56);

        Assert.Equal(expected, sample.Text(format));
    }

    [Fact]
    public void TogglingReturnsToTheOriginalFormat()
    {
        var format = ColorDisplayFormat.Hex;

        format = format.Toggled();
        Assert.Equal(ColorDisplayFormat.Rgb, format);

        format = format.Toggled();
        Assert.Equal(ColorDisplayFormat.Hex, format);
    }

    [Fact]
    public void ChannelsAreNotReorderedWhenFormatting()
    {
        // Guards against re-introducing a BGRA/RGBA mix-up: red must lead the
        // hex string even when the three channels have distinct values.
        var sample = new PixelSample(0, 0, 0xAA, 0xBB, 0xCC);

        Assert.Equal("#AABBCC", sample.Hex);
        Assert.Equal("RGB(170, 187, 204)", sample.Rgb);
    }
}
