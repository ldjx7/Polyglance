using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Polyglance.Core.Models;

namespace Polyglance.Platform.Ocr;

public static class WindowsMediaOcr
{
    public static async Task<List<LayoutTextLine>> RecognizeLinesAsync(BitmapSource bitmap)
    {
        var lines = new List<LayoutTextLine>();
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));

        using var memoryStream = new MemoryStream();
        encoder.Save(memoryStream);
        memoryStream.Seek(0, SeekOrigin.Begin);

        var randomAccessStream = memoryStream.AsRandomAccessStream();
        var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(randomAccessStream);
        using var softwareBitmap = await decoder.GetSoftwareBitmapAsync(
            BitmapPixelFormat.Bgra8,
            BitmapAlphaMode.Premultiplied);

        var engine = OcrEngine.TryCreateFromUserProfileLanguages()
                     ?? OcrEngine.TryCreateFromLanguage(new Windows.Globalization.Language("en-US"));

        if (engine == null)
            return lines;

        var ocrResult = await engine.RecognizeAsync(softwareBitmap);
        if (ocrResult == null)
            return lines;

        foreach (var line in ocrResult.Lines)
        {
            var box = line.Words.Count > 0 ? line.Words[0].BoundingRect : Windows.Foundation.Rect.Empty;
            double minX = double.MaxValue;
            double minY = double.MaxValue;
            double maxX = double.MinValue;
            double maxY = double.MinValue;

            foreach (var word in line.Words)
            {
                minX = Math.Min(minX, word.BoundingRect.X);
                minY = Math.Min(minY, word.BoundingRect.Y);
                maxX = Math.Max(maxX, word.BoundingRect.X + word.BoundingRect.Width);
                maxY = Math.Max(maxY, word.BoundingRect.Y + word.BoundingRect.Height);
            }

            if (minX < maxX && minY < maxY)
            {
                lines.Add(new LayoutTextLine
                {
                    Text = line.Text,
                    X = minX,
                    Y = minY,
                    Width = maxX - minX,
                    Height = maxY - minY
                });
            }
        }

        return lines;
    }
}
