using System.Windows.Media.Imaging;
using System.Windows.Media;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using ZXing;

namespace Polyglance.Platform.Barcode;

public sealed class WindowsBarcodeException : Exception
{
    public WindowsBarcodeException(string message) : base(message) { }

    public WindowsBarcodeException(string message, Exception innerException)
        : base(message, innerException) { }
}

/// <summary>
/// ZXing-based barcode recognition, the Windows counterpart of the macOS
/// Vision backend. Decode is CPU-bound and synchronous, so it runs off the
/// UI thread; WPF images must be frozen before a background thread may read
/// their pixels.
/// </summary>
public static class WindowsBarcodeReader
{
    /// <summary>
    /// An explicit allow-list rather than "everything ZXing knows", mirroring
    /// the macOS backend's symbology contract.
    /// </summary>
    private static readonly BarcodeFormat[] Formats =
    [
        BarcodeFormat.QR_CODE,
        BarcodeFormat.AZTEC,
        BarcodeFormat.CODE_128,
        BarcodeFormat.CODE_39,
        BarcodeFormat.DATA_MATRIX,
        BarcodeFormat.EAN_13,
        BarcodeFormat.UPC_A,
        BarcodeFormat.PDF_417,
    ];

    public static Task<IReadOnlyList<BarcodeObservation>> RecognizeAsync(
        BitmapSource bitmap,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(bitmap);
        if (bitmap.CanFreeze && !bitmap.IsFrozen)
        {
            bitmap.Freeze();
        }
        return Task.Run(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            var result = RecognizeFrozen(bitmap);
            cancellationToken.ThrowIfCancellationRequested();
            return result;
        }, cancellationToken);
    }

    private static IReadOnlyList<BarcodeObservation> RecognizeFrozen(BitmapSource bitmap)
    {
        try
        {
            var reader = new BarcodeReaderGeneric();
            reader.Options.TryHarder = true;
            reader.Options.PossibleFormats = Formats;

            BitmapSource bgra = bitmap;
            if (bgra.Format != PixelFormats.Bgra32)
            {
                bgra = new FormatConvertedBitmap(bitmap, PixelFormats.Bgra32, null, 0);
                if (bgra.CanFreeze)
                {
                    bgra.Freeze();
                }
            }

            var stride = checked(bgra.PixelWidth * 4);
            var pixels = new byte[checked(stride * bgra.PixelHeight)];
            bgra.CopyPixels(pixels, stride, 0);
            var results = reader.DecodeMultiple(
                pixels,
                bgra.PixelWidth,
                bgra.PixelHeight,
                RGBLuminanceSource.BitmapFormat.BGRA32) ?? [];
            return Prepare(results, bgra.PixelWidth, bgra.PixelHeight);
        }
        catch (Exception error)
        {
            throw new WindowsBarcodeException($"条码识别失败：{error.Message}", error);
        }
    }

    /// <summary>
    /// Drops empty payloads, removes exact duplicates, converts ZXing's
    /// top-left pixel corner points into the shared normalized lower-left
    /// space, and sorts in reading order (top to bottom, left to right).
    /// </summary>
    internal static IReadOnlyList<BarcodeObservation> Prepare(
        IEnumerable<Result> results,
        int imageWidth,
        int imageHeight)
    {
        var seenPayloads = new HashSet<string>(StringComparer.Ordinal);
        var usable = new List<(int Index, BarcodeObservation Observation)>();

        var index = 0;
        foreach (var result in results)
        {
            var rawPayload = result.Text ?? "";
            var payload = rawPayload.Trim();
            if (payload.Length == 0
                || result.ResultPoints is not { Length: > 0 } points
                || !seenPayloads.Add(payload))
            {
                index++;
                continue;
            }

            usable.Add((index, new BarcodeObservation(
                rawPayload,
                MapFormat(result.BarcodeFormat),
                NormalizeBounds(points, imageWidth, imageHeight),
                NormalizeCorners(points, imageWidth, imageHeight))));
            index++;
        }

        return usable
            // Lower-left origin: "above" means a larger centre Y.
            .OrderByDescending(item => item.Observation.BoundingBox.Y + item.Observation.BoundingBox.Height / 2)
            .ThenBy(item => item.Observation.BoundingBox.X)
            .ThenBy(item => item.Index)
            .Select(item => item.Observation)
            .ToList();
    }

    /// <summary>
    /// ZXing reports corner points in pixel coordinates with the origin at the
    /// top left; the project convention is normalized 0...1 with the origin at
    /// the lower left, so Y is flipped after normalization.
    /// </summary>
    internal static NativeRect NormalizeBounds(
        IReadOnlyList<ResultPoint> points,
        int imageWidth,
        int imageHeight)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(imageWidth);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(imageHeight);
        if (points.Count == 0)
        {
            throw new ArgumentException("至少需要一个条码角点。", nameof(points));
        }

        var minX = Math.Clamp(points.Min(point => point.X), 0, imageWidth);
        var maxX = Math.Clamp(points.Max(point => point.X), 0, imageWidth);
        var minY = Math.Clamp(points.Min(point => point.Y), 0, imageHeight);
        var maxY = Math.Clamp(points.Max(point => point.Y), 0, imageHeight);

        // Some 1D readers return only two points on the same scan line. Keep a
        // one-pixel box so the result remains presentable and sortable.
        if (maxX - minX < 1)
        {
            minX = Math.Max(0, minX - 0.5f);
            maxX = Math.Min(imageWidth, minX + 1);
        }
        if (maxY - minY < 1)
        {
            minY = Math.Max(0, minY - 0.5f);
            maxY = Math.Min(imageHeight, minY + 1);
        }

        return new NativeRect(
            minX / imageWidth,
            1 - maxY / (double)imageHeight,
            (maxX - minX) / imageWidth,
            (maxY - minY) / imageHeight);
    }

    private static IReadOnlyList<NativePoint> NormalizeCorners(
        IReadOnlyList<ResultPoint> points,
        int imageWidth,
        int imageHeight)
    {
        var box = NormalizeBounds(points, imageWidth, imageHeight);
        return
        [
            new NativePoint(box.X, box.Y + box.Height),
            new NativePoint(box.X + box.Width, box.Y + box.Height),
            new NativePoint(box.X + box.Width, box.Y),
            new NativePoint(box.X, box.Y),
        ];
    }

    private static BarcodeSymbology MapFormat(BarcodeFormat format) => format switch
    {
        BarcodeFormat.QR_CODE => BarcodeSymbology.Qr,
        BarcodeFormat.AZTEC => BarcodeSymbology.Aztec,
        BarcodeFormat.CODE_128 => BarcodeSymbology.Code128,
        BarcodeFormat.CODE_39 => BarcodeSymbology.Code39,
        BarcodeFormat.EAN_13 => BarcodeSymbology.Ean13,
        BarcodeFormat.UPC_A => BarcodeSymbology.Upca,
        BarcodeFormat.DATA_MATRIX => BarcodeSymbology.DataMatrix,
        BarcodeFormat.PDF_417 => BarcodeSymbology.Pdf417,
        _ => BarcodeSymbology.Other
    };
}
