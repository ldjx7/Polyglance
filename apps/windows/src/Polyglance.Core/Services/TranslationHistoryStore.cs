using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Polyglance.Core.Services;

public sealed class TranslationRecord
{
    [JsonPropertyName("id")]
    public Guid Id { get; set; } = Guid.NewGuid();

    [JsonPropertyName("timestamp")]
    public DateTimeOffset Timestamp { get; set; } = DateTimeOffset.UtcNow;

    [JsonPropertyName("source_text")]
    public string SourceText { get; set; } = "";

    [JsonPropertyName("target_text")]
    public string TargetText { get; set; } = "";

    [JsonPropertyName("source_lang")]
    public string SourceLang { get; set; } = "";

    [JsonPropertyName("target_lang")]
    public string TargetLang { get; set; } = "";

    [JsonPropertyName("provider")]
    public string Provider { get; set; } = "";

    [JsonPropertyName("is_favorite")]
    public bool IsFavorite { get; set; }
}

public sealed class TranslationHistoryStore
{
    private static readonly Lazy<TranslationHistoryStore> _shared = new(() => new TranslationHistoryStore());
    public static TranslationHistoryStore Shared => _shared.Value;

    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private readonly string _filePath;
    private readonly object _lock = new();
    private List<TranslationRecord> _records = new();

    public TranslationHistoryStore(string? filePath = null)
    {
        if (!string.IsNullOrWhiteSpace(filePath))
        {
            _filePath = filePath;
        }
        else
        {
            string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            _filePath = Path.Combine(appData, "Polyglance", "translation_history.json");
        }

        Load();
    }

    public IReadOnlyList<TranslationRecord> GetRecords()
    {
        lock (_lock)
        {
            return _records.ToList();
        }
    }

    public IReadOnlyList<TranslationRecord> GetFavorites()
    {
        lock (_lock)
        {
            return _records.Where(r => r.IsFavorite).ToList();
        }
    }

    public void AddRecord(string sourceText, string targetText, string sourceLang, string targetLang, string provider)
    {
        string trimmedSource = (sourceText ?? "").Trim();
        string trimmedTarget = (targetText ?? "").Trim();
        if (string.IsNullOrEmpty(trimmedSource) || string.IsNullOrEmpty(trimmedTarget))
            return;

        lock (_lock)
        {
            if (_records.Count > 0 && _records[0].SourceText == trimmedSource && _records[0].TargetText == trimmedTarget)
                return;

            var record = new TranslationRecord
            {
                Id = Guid.NewGuid(),
                Timestamp = DateTimeOffset.UtcNow,
                SourceText = trimmedSource,
                TargetText = trimmedTarget,
                SourceLang = sourceLang ?? "",
                TargetLang = targetLang ?? "",
                Provider = provider ?? "",
                IsFavorite = false
            };

            _records.Insert(0, record);
            if (_records.Count > 100)
            {
                _records = _records.Take(100).ToList();
            }

            Save();
        }
    }

    public void ToggleFavorite(Guid id)
    {
        lock (_lock)
        {
            var item = _records.FirstOrDefault(r => r.Id == id);
            if (item != null)
            {
                item.IsFavorite = !item.IsFavorite;
                Save();
            }
        }
    }

    public void ToggleFavoriteForCurrent(string sourceText, string targetText)
    {
        string trimmed = (sourceText ?? "").Trim();
        if (string.IsNullOrEmpty(trimmed))
            return;

        lock (_lock)
        {
            var item = _records.FirstOrDefault(r => r.SourceText == trimmed);
            if (item != null)
            {
                item.IsFavorite = !item.IsFavorite;
                Save();
            }
            else if (!string.IsNullOrEmpty(targetText?.Trim()))
            {
                var record = new TranslationRecord
                {
                    Id = Guid.NewGuid(),
                    Timestamp = DateTimeOffset.UtcNow,
                    SourceText = trimmed,
                    TargetText = targetText.Trim(),
                    SourceLang = "",
                    TargetLang = "",
                    Provider = "",
                    IsFavorite = true
                };
                _records.Insert(0, record);
                Save();
            }
        }
    }

    public bool IsFavorite(string sourceText)
    {
        string trimmed = (sourceText ?? "").Trim();
        if (string.IsNullOrEmpty(trimmed))
            return false;

        lock (_lock)
        {
            return _records.FirstOrDefault(r => r.SourceText == trimmed)?.IsFavorite ?? false;
        }
    }

    public void DeleteRecord(Guid id)
    {
        lock (_lock)
        {
            _records.RemoveAll(r => r.Id == id);
            Save();
        }
    }

    public void ClearAll()
    {
        lock (_lock)
        {
            _records.Clear();
            Save();
        }
    }

    private void Load()
    {
        lock (_lock)
        {
            try
            {
                if (File.Exists(_filePath))
                {
                    string json = File.ReadAllText(_filePath);
                    _records = JsonSerializer.Deserialize<List<TranslationRecord>>(json) ?? new();
                }
            }
            catch
            {
                _records = new();
            }
        }
    }

    private void Save()
    {
        try
        {
            string? dir = Path.GetDirectoryName(_filePath);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
            {
                Directory.CreateDirectory(dir);
            }

            string json = JsonSerializer.Serialize(_records, JsonOptions);
            File.WriteAllText(_filePath, json);
        }
        catch
        {
            // Ignore persistence errors
        }
    }
}
