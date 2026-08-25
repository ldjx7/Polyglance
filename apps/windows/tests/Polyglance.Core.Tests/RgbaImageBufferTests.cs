using Polyglance.Core.Models;

namespace Polyglance.Core.Tests;

public sealed class RgbaImageBufferTests
{
    [Fact]
    public void ConstructorPreservesDimensionsAndCalculatesStride()
    {
        byte[] pixels = new byte[3 * 2 * 4];

        var image = new RgbaImageBuffer(pixels, width: 3, height: 2);

        Assert.Same(pixels, image.Pixels);
        Assert.Equal((uint)3, image.Width);
        Assert.Equal((uint)2, image.Height);
        Assert.Equal(12, image.Stride);
    }

    [Theory]
    [InlineData(0, 2)]
    [InlineData(3, 0)]
    public void ConstructorRejectsEmptyDimensions(uint width, uint height)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            new RgbaImageBuffer([], width, height));
    }

    [Fact]
    public void ConstructorRejectsPixelLengthThatDoesNotMatchDimensions()
    {
        Assert.Throws<ArgumentException>(() =>
            new RgbaImageBuffer(new byte[7], width: 2, height: 1));
    }

    [Fact]
    public void CopyBgraPixelsSwapsRedAndBlueWithoutChangingAlpha()
    {
        var image = new RgbaImageBuffer(
            [0x11, 0x22, 0x33, 0x44, 0xAA, 0xBB, 0xCC, 0xDD],
            width: 2,
            height: 1);

        Assert.Equal(
            [0x33, 0x22, 0x11, 0x44, 0xCC, 0xBB, 0xAA, 0xDD],
            image.CopyBgraPixels());
    }
}
