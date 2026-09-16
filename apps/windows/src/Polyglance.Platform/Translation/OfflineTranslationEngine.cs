using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Threading.Tasks;
using Polyglance.Core.Models;
using Polyglance.Core.Services;

namespace Polyglance.Platform.Translation;

public sealed class OfflineTranslationEngine : IOfflineTranslationHandler, IDisposable
{
    private readonly ConcurrentDictionary<string, MarianOnnxTranslator> _translators = new();
    private bool _disposed;

    public bool IsModelAvailable(string sourceLanguage, string targetLanguage)
    {
        var model = OfflineModelManager.Instance.ResolveModel(sourceLanguage, targetLanguage);
        return model != null && OfflineModelManager.FindModelDirectory(model.Id) != null;
    }

    public async Task<TranslationResult> TranslateAsync(string text, string targetLanguage, string? sourceLanguage)
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(OfflineTranslationEngine));
        }

        if (string.IsNullOrWhiteSpace(text))
        {
            return new TranslationResult
            {
                Text = string.Empty,
                Provider = "offline",
                ElapsedMs = 0
            };
        }

        var model = OfflineModelManager.Instance.ResolveModel(sourceLanguage, targetLanguage);
        if (model == null)
        {
            throw new InvalidOperationException($"当前不支持从 {sourceLanguage ?? "自动检测"} 到 {targetLanguage} 的离线翻译模型。");
        }

        string? modelDir = OfflineModelManager.FindModelDirectory(model.Id);
        if (modelDir == null)
        {
            throw new InvalidOperationException($"尚未下载离线翻译模型 [{model.Name}]，请前往设置的本地离线翻译管理界面下载或导入模型。");
        }

        var translator = _translators.GetOrAdd(model.Id, _ => new MarianOnnxTranslator(modelDir));
        var sw = Stopwatch.StartNew();
        string translated = await translator.TranslateAsync(text);
        sw.Stop();

        return new TranslationResult
        {
            Text = translated,
            Provider = "offline",
            ElapsedMs = (ulong)sw.ElapsedMilliseconds
        };
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        foreach (var translator in _translators.Values)
        {
            translator.Dispose();
        }
        _translators.Clear();
    }
}
