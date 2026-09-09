using System.Threading.Tasks;
using System.Windows.Media.Imaging;
using Polyglance.Core.Services;

namespace Polyglance.Platform.Ocr;

public sealed class WindowsMediaOcrEngine : IOcrEngine
{
    public string Id => "system";
    public string DisplayName => "Windows 系统原生 OCR";
    public bool IsAvailable => true;

    public Task<OcrTextDocument> RecognizeDocumentAsync(BitmapSource bitmap) =>
        WindowsMediaOcr.RecognizeDocumentAsync(bitmap);
}
