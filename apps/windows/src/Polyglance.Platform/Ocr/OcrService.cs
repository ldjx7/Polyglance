using System;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;
using Polyglance.Core.Services;

namespace Polyglance.Platform.Ocr;

public static class OcrService
{
    private static readonly IOcrEngine s_systemEngine = new WindowsMediaOcrEngine();
    private static IOcrEngine? s_ppOcrEngine;
    private static bool s_ppOcrChecked;
    private static readonly object s_lock = new();

    public static IOcrEngine GetEngine(string? preferredEngineId = null)
    {
        if (preferredEngineId == "system")
        {
            return s_systemEngine;
        }

        var ppOcr = GetPpOcrEngine();
        if (ppOcr != null && ppOcr.IsAvailable)
        {
            return ppOcr;
        }

        return s_systemEngine;
    }

    public static async Task<OcrTextDocument> RecognizeDocumentAsync(
        BitmapSource bitmap,
        string? preferredEngineId = null)
    {
        var primary = GetEngine(preferredEngineId);
        try
        {
            var doc = await primary.RecognizeDocumentAsync(bitmap);
            if (doc.Lines.Count > 0 || primary == s_systemEngine)
            {
                return doc;
            }
        }
        catch (Exception)
        {
            if (primary == s_systemEngine)
            {
                throw;
            }
        }

        // Automatic fallback to system engine if custom engine fails or produces no lines
        return await s_systemEngine.RecognizeDocumentAsync(bitmap);
    }

    private static IOcrEngine? GetPpOcrEngine()
    {
        if (!s_ppOcrChecked)
        {
            lock (s_lock)
            {
                if (!s_ppOcrChecked)
                {
                    s_ppOcrChecked = true;
                    try
                    {
                        var engine = new PpOcrEngine();
                        if (engine.IsAvailable)
                        {
                            s_ppOcrEngine = engine;
                        }
                    }
                    catch
                    {
                        s_ppOcrEngine = null;
                    }
                }
            }
        }
        return s_ppOcrEngine;
    }
}
