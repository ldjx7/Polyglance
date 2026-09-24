using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media.Imaging;
using Polyglance.Core.Models;
using Polyglance.Core.Native;
using Polyglance.Core.Services;

namespace Polyglance.Platform.Ocr;

public sealed class WindowsOcrException : Exception
{
    public WindowsOcrException(string message) : base(message) { }

    public WindowsOcrException(string message, Exception innerException)
        : base(message, innerException) { }
}

public static class WindowsMediaOcr
{
    private sealed class NativeOcrWord
    {
        [JsonPropertyName("text")]
        public string Text { get; set; } = string.Empty;

        [JsonPropertyName("x")]
        public double X { get; set; }

        [JsonPropertyName("y")]
        public double Y { get; set; }

        [JsonPropertyName("width")]
        public double Width { get; set; }

        [JsonPropertyName("height")]
        public double Height { get; set; }
    }

    private sealed class NativeOcrLine
    {
        [JsonPropertyName("text")]
        public string Text { get; set; } = string.Empty;

        [JsonPropertyName("words")]
        public List<NativeOcrWord> Words { get; set; } = [];
    }

    public static async Task<OcrTextDocument> RecognizeDocumentAsync(BitmapSource bitmap)
    {
        ArgumentNullException.ThrowIfNull(bitmap);

        var lines = new List<LayoutTextLine>();
        const int tileLimit = 4096;

        try
        {
            for (int y = 0; y < bitmap.PixelHeight; y += tileLimit)
            {
                int tileHeight = Math.Min(tileLimit, bitmap.PixelHeight - y);
                for (int x = 0; x < bitmap.PixelWidth; x += tileLimit)
                {
                    int tileWidth = Math.Min(tileLimit, bitmap.PixelWidth - x);
                    var tile = new CroppedBitmap(bitmap, new Int32Rect(x, y, tileWidth, tileHeight));
                    tile.Freeze();
                    lines.AddRange(await RecognizeTileAsync(tile, x, y));
                }
            }
        }
        catch (WindowsOcrException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new WindowsOcrException($"OCR 识别失败：{error.Message}", error);
        }

        var organizedLines = OcrLayoutService.OrganizeLines(lines, bitmap.PixelWidth, bitmap.PixelHeight);
        return new OcrTextDocument(organizedLines);
    }

    public static async Task<List<LayoutTextLine>> RecognizeLinesAsync(BitmapSource bitmap) =>
        [.. (await RecognizeDocumentAsync(bitmap)).Lines];

    private static async Task<IReadOnlyList<LayoutTextLine>> RecognizeTileAsync(
        BitmapSource bitmap,
        int offsetX,
        int offsetY)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));

        using var memoryStream = new MemoryStream();
        encoder.Save(memoryStream);
        byte[] pngBytes = memoryStream.ToArray();

        string json = await Task.Run(() =>
        {
            IntPtr outJsonPtr = IntPtr.Zero;
            int status;
            unsafe
            {
                fixed (byte* p = pngBytes)
                {
                    status = NativeMethods.polyglance_windows_ocr_recognize(p, (nuint)pngBytes.Length, out outJsonPtr);
                }
            }

            if (status != 0 || outJsonPtr == IntPtr.Zero)
            {
                throw new WindowsOcrException($"Windows OCR 识别失败 (错误码 {status})。");
            }

            string result = Marshal.PtrToStringUTF8(outJsonPtr) ?? "[]";
            NativeMethods.polyglance_free_string(outJsonPtr);
            return result;
        });

        var nativeLines = JsonSerializer.Deserialize<List<NativeOcrLine>>(json) ?? [];
        var lines = new List<LayoutTextLine>();

        foreach (var line in nativeLines)
        {
            var words = new List<LayoutTextWord>();
            double minX = double.MaxValue;
            double minY = double.MaxValue;
            double maxX = double.MinValue;
            double maxY = double.MinValue;

            foreach (var word in line.Words)
            {
                minX = Math.Min(minX, word.X);
                minY = Math.Min(minY, word.Y);
                maxX = Math.Max(maxX, word.X + word.Width);
                maxY = Math.Max(maxY, word.Y + word.Height);

                words.AddRange(SubdivideWord(
                    word.Text,
                    word.X + offsetX,
                    word.Y + offsetY,
                    word.Width,
                    word.Height));
            }

            if (minX < maxX && minY < maxY)
            {
                lines.Add(new LayoutTextLine
                {
                    Text = line.Text,
                    X = minX + offsetX,
                    Y = minY + offsetY,
                    Width = maxX - minX,
                    Height = maxY - minY,
                    Words = words
                });
            }
        }

        return lines;
    }

    private static IEnumerable<LayoutTextWord> SubdivideWord(
        string text,
        double x,
        double y,
        double width,
        double height)
    {
        if (string.IsNullOrEmpty(text))
        {
            yield break;
        }

        bool hasCjk = false;
        var runes = new List<string>();
        var weights = new List<double>();
        double totalWeight = 0;

        for (int i = 0; i < text.Length; i++)
        {
            string element;
            if (char.IsHighSurrogate(text[i]) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
            {
                element = text.Substring(i, 2);
                i++;
            }
            else
            {
                element = text[i].ToString();
            }
            runes.Add(element);

            bool isCjkChar = element.Length == 1 && IsCjk(element[0]);
            if (isCjkChar)
            {
                hasCjk = true;
            }
            double w = isCjkChar ? 1.0 : 0.55;
            weights.Add(w);
            totalWeight += w;
        }

        if (!hasCjk || runes.Count <= 1)
        {
            yield return new LayoutTextWord
            {
                Text = text,
                X = x,
                Y = y,
                Width = width,
                Height = height
            };
            yield break;
        }

        if (totalWeight <= 0) totalWeight = runes.Count;

        double unitWidth = width / totalWeight;
        double currentX = x;

        for (int i = 0; i < runes.Count; i++)
        {
            double charWidth = (i == runes.Count - 1)
                ? (x + width - currentX)
                : (unitWidth * weights[i]);

            yield return new LayoutTextWord
            {
                Text = runes[i],
                X = currentX,
                Y = y,
                Width = Math.Max(1.0, charWidth),
                Height = height
            };

            currentX += charWidth;
        }
    }

    private static bool IsCjk(char value) =>
        value is >= '\u3400' and <= '\u9FFF'
        or >= '\uF900' and <= '\uFAFF'
        or >= '\u3040' and <= '\u30FF'
        or >= '\uAC00' and <= '\uD7AF';
}
