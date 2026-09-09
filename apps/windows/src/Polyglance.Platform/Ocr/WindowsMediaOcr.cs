using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using WpfBitmapFrame = System.Windows.Media.Imaging.BitmapFrame;
using WinRtBitmapDecoder = Windows.Graphics.Imaging.BitmapDecoder;

namespace Polyglance.Platform.Ocr;

public sealed class WindowsOcrException : Exception
{
    public WindowsOcrException(string message) : base(message) { }

    public WindowsOcrException(string message, Exception innerException)
        : base(message, innerException) { }
}

public static class WindowsMediaOcr
{
    public static async Task<OcrTextDocument> RecognizeDocumentAsync(BitmapSource bitmap)
    {
        ArgumentNullException.ThrowIfNull(bitmap);

        var lines = new List<LayoutTextLine>();
        int tileLimit = checked((int)Math.Min(OcrEngine.MaxImageDimension, 4096u));

        try
        {
            var engine = CreateEngine();
            for (int y = 0; y < bitmap.PixelHeight; y += tileLimit)
            {
                int tileHeight = Math.Min(tileLimit, bitmap.PixelHeight - y);
                for (int x = 0; x < bitmap.PixelWidth; x += tileLimit)
                {
                    int tileWidth = Math.Min(tileLimit, bitmap.PixelWidth - x);
                    var tile = new CroppedBitmap(bitmap, new Int32Rect(x, y, tileWidth, tileHeight));
                    tile.Freeze();
                    lines.AddRange(await RecognizeTileAsync(engine, tile, x, y));
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

    private static OcrEngine CreateEngine()
    {
        var engine = OcrEngine.TryCreateFromUserProfileLanguages();
        if (engine != null)
        {
            return engine;
        }

        string[] candidateTags =
        [
            "zh-Hans", "zh-CN", "zh-Hans-CN",
            "zh-Hant", "zh-TW", "zh-HK",
            "en-US", "en-GB", "en",
            "ja-JP", "ja",
            "ko-KR", "ko"
        ];

        foreach (string languageTag in candidateTags)
        {
            try
            {
                var language = new Windows.Globalization.Language(languageTag);
                if (OcrEngine.IsLanguageSupported(language))
                {
                    var fallback = OcrEngine.TryCreateFromLanguage(language);
                    if (fallback != null)
                    {
                        return fallback;
                    }
                }
            }
            catch
            {
                // Ignore unsupported language tag errors
            }
        }

        foreach (var language in OcrEngine.AvailableRecognizerLanguages)
        {
            var fallback = OcrEngine.TryCreateFromLanguage(language);
            if (fallback != null)
            {
                return fallback;
            }
        }

        throw new WindowsOcrException(
            "Windows 没有可用的 OCR 语言包。请在“设置 → 时间和语言 → 语言和区域”中安装中文或英文语言功能。");
    }

    private static async Task<IReadOnlyList<LayoutTextLine>> RecognizeTileAsync(
        OcrEngine engine,
        BitmapSource bitmap,
        int offsetX,
        int offsetY)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(WpfBitmapFrame.Create(bitmap));

        using var memoryStream = new MemoryStream();
        encoder.Save(memoryStream);
        memoryStream.Position = 0;

        using var randomAccessStream = memoryStream.AsRandomAccessStream();
        var decoder = await WinRtBitmapDecoder.CreateAsync(randomAccessStream);
        using var softwareBitmap = await decoder.GetSoftwareBitmapAsync(
            BitmapPixelFormat.Bgra8,
            BitmapAlphaMode.Premultiplied);

        var result = await engine.RecognizeAsync(softwareBitmap);
        var lines = new List<LayoutTextLine>();
        foreach (var line in result.Lines)
        {
            var words = new List<LayoutTextWord>();
            double minX = double.MaxValue;
            double minY = double.MaxValue;
            double maxX = double.MinValue;
            double maxY = double.MinValue;

            foreach (var word in line.Words)
            {
                var box = word.BoundingRect;
                minX = Math.Min(minX, box.X);
                minY = Math.Min(minY, box.Y);
                maxX = Math.Max(maxX, box.X + box.Width);
                maxY = Math.Max(maxY, box.Y + box.Height);

                words.AddRange(SubdivideWord(
                    word.Text,
                    box.X + offsetX,
                    box.Y + offsetY,
                    box.Width,
                    box.Height));
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
