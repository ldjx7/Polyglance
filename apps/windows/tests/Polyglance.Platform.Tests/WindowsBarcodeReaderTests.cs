using Polyglance.Platform.Barcode;
using Polyglance.Core.Services;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ZXing;
using ZXing.Common;
using ZXing.QrCode;

namespace Polyglance.Platform.Tests;

public sealed class WindowsBarcodeReaderTests
{
    [Fact]
    public async Task DecodeReadsARealQrBitmapSource()
    {
        const string payload = "Polyglance-QR-Test";
        var pixels = new BarcodeWriterPixelData
        {
            Format = BarcodeFormat.QR_CODE,
            Options = new QrCodeEncodingOptions
            {
                Width = 256,
                Height = 256,
                Margin = 4,
                CharacterSet = "UTF-8"
            }
        }.Write(payload);
        var bitmap = BitmapSource.Create(
            pixels.Width,
            pixels.Height,
            96,
            96,
            PixelFormats.Bgra32,
            null,
            pixels.Pixels,
            pixels.Width * 4);

        var observations = await WindowsBarcodeReader.RecognizeAsync(bitmap);

        var observation = Assert.Single(observations);
        Assert.Equal(payload, observation.Payload);
        Assert.Equal(BarcodeSymbology.Qr, observation.Symbology);
    }

    [Fact]
    public void NormalizeBoundsFlipsIntoLowerLeftNormalizedSpace()
    {
        // A code covering the top-left quarter of a 100×200 image.
        var points = new[]
        {
            new ResultPoint(0, 0),
            new ResultPoint(50, 0),
            new ResultPoint(50, 50),
            new ResultPoint(0, 50),
        };

        var box = WindowsBarcodeReader.NormalizeBounds(points, 100, 200);

        // Top-left pixel space spans y 0..50. Normalized to height 50/200 =
        // 0.25 in lower-left space, the box sits at y = 1 - 0.25 = 0.75.
        Assert.Equal(0.0, box.X, 6);
        Assert.Equal(0.75, box.Y, 6);
        Assert.Equal(0.5, box.Width, 6);
        Assert.Equal(0.25, box.Height, 6);
    }

    [Fact]
    public void PrepareDeduplicatesAndSortsInReadingOrder()
    {
        var results = new[]
        {
            Result("bottom-left", 10, 150),
            Result("top-right", 70, 10),
            Result("top-left", 10, 10),
            Result("top-left", 90, 190), // duplicate payload
        };

        var prepared = WindowsBarcodeReader.Prepare(results, 100, 200);

        Assert.Equal(
            new[] { "top-left", "top-right", "bottom-left" },
            prepared.Select(observation => observation.Payload).ToArray());
    }

    [Fact]
    public void PrepareDropsResultsWithoutUsablePointsOrPayload()
    {
        var results = new[]
        {
            Result("", 0, 0),
            Result("   ", 0, 0),
            Result("kept", 0, 0),
        };

        var prepared = WindowsBarcodeReader.Prepare(results, 100, 100);

        Assert.Single(prepared);
        Assert.Equal("kept", prepared[0].Payload);
    }

    [Fact]
    public void OneDimensionalBarcodesStillReceiveAUsableBoundingBox()
    {
        var points = new[]
        {
            new ResultPoint(10, 50),
            new ResultPoint(90, 50),
        };

        var box = WindowsBarcodeReader.NormalizeBounds(points, 100, 100);

        Assert.True(box.Width > 0);
        Assert.True(box.Height > 0);
        Assert.InRange(box.X, 0, 1);
        Assert.InRange(box.Y, 0, 1);
    }

    [Fact]
    public void UpcaResultsKeepTheirSymbology()
    {
        var prepared = WindowsBarcodeReader.Prepare(
            [Result("012345678905", 10, 10, BarcodeFormat.UPC_A)],
            100,
            100);

        Assert.Equal(BarcodeSymbology.Upca, Assert.Single(prepared).Symbology);
    }

    [Fact]
    public void PrepareDeduplicatesByTrimmedValueButPreservesTheDecodedPayload()
    {
        var prepared = WindowsBarcodeReader.Prepare(
            [Result("  payload  ", 10, 10), Result("payload", 40, 40)],
            100,
            100);

        Assert.Equal("  payload  ", Assert.Single(prepared).Payload);
    }

    private static Result Result(
        string text,
        float x,
        float y,
        BarcodeFormat format = BarcodeFormat.QR_CODE) =>
        new(
            text,
            null,
            [
                new ResultPoint(x, y),
                new ResultPoint(x + 20, y),
                new ResultPoint(x + 20, y + 20),
                new ResultPoint(x, y + 20),
            ],
            format);
}
