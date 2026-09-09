using System.Threading.Tasks;
using System.Windows.Media.Imaging;
using Polyglance.Core.Services;

namespace Polyglance.Platform.Ocr;

public interface IOcrEngine
{
    string Id { get; }
    string DisplayName { get; }
    bool IsAvailable { get; }
    Task<OcrTextDocument> RecognizeDocumentAsync(BitmapSource bitmap);
}
