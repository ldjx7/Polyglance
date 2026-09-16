using System.Threading.Tasks;
using Polyglance.Core.Models;

namespace Polyglance.Core.Services;

public interface IOfflineTranslationHandler
{
    Task<TranslationResult> TranslateAsync(string text, string targetLanguage, string? sourceLanguage);
    bool IsModelAvailable(string sourceLanguage, string targetLanguage);
}
