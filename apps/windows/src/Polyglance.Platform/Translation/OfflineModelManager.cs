using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Polyglance.Core.Services;

namespace Polyglance.Platform.Translation;

public sealed class OfflineModelManager
{
    private static readonly Lazy<OfflineModelManager> s_instance = new(() => new OfflineModelManager());
    public static OfflineModelManager Instance => s_instance.Value;

    private readonly List<OfflineModelInfo> _models = [];
    private readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromMinutes(15) };
    private readonly object _lock = new();

    public IReadOnlyList<OfflineModelInfo> Models => _models;

    public OfflineModelManager()
    {
        _models.Add(new OfflineModelInfo
        {
            Id = "enzh",
            Name = "英语 ➔ 中文 (MarianMT)",
            Description = "适用于英文到中文的高性能离线神经机器翻译",
            SourceLanguage = "en",
            TargetLanguage = "zh-CN",
            SizeBytes = 185_000_000,
            DownloadUrls =
            [
                "https://hf-mirror.com/onnx-community/opus-mt-en-zh/resolve/main/vocab.json",
                "https://hf-mirror.com/onnx-community/opus-mt-en-zh/resolve/main/onnx/encoder_model_quantized.onnx",
                "https://hf-mirror.com/onnx-community/opus-mt-en-zh/resolve/main/onnx/decoder_model_quantized.onnx"
            ]
        });

        _models.Add(new OfflineModelInfo
        {
            Id = "zhen",
            Name = "中文 ➔ 英语 (MarianMT)",
            Description = "适用于中文到英文的高性能离线神经机器翻译",
            SourceLanguage = "zh-CN",
            TargetLanguage = "en",
            SizeBytes = 185_000_000,
            DownloadUrls =
            [
                "https://hf-mirror.com/onnx-community/opus-mt-zh-en/resolve/main/vocab.json",
                "https://hf-mirror.com/onnx-community/opus-mt-zh-en/resolve/main/onnx/encoder_model_quantized.onnx",
                "https://hf-mirror.com/onnx-community/opus-mt-zh-en/resolve/main/onnx/decoder_model_quantized.onnx"
            ]
        });

        _models.Add(new OfflineModelInfo
        {
            Id = "jazh",
            Name = "日语 ➔ 中文 (MarianMT)",
            Description = "适用于日文到中文的轻量离线神经网络翻译 (支持导入)",
            SourceLanguage = "ja",
            TargetLanguage = "zh-CN",
            SizeBytes = 185_000_000
        });

        _models.Add(new OfflineModelInfo
        {
            Id = "kozh",
            Name = "韩语 ➔ 中文 (MarianMT)",
            Description = "适用于韩文到中文的轻量离线神经网络翻译 (支持导入)",
            SourceLanguage = "ko",
            TargetLanguage = "zh-CN",
            SizeBytes = 185_000_000
        });

        RefreshInstalledStatus();
    }

    static OfflineModelManager()
    {
        DataDirectoryManager.RootDirectoryChanged += () => Instance.RefreshInstalledStatus();
    }

    private static string? _customModelDirectory;
    public static string CustomModelDirectory
    {
        get => _customModelDirectory ?? (!string.IsNullOrWhiteSpace(DataDirectoryManager.CustomRootDirectory) ? DataDirectoryManager.ModelsDirectory : string.Empty);
        set => _customModelDirectory = value;
    }

    public static string DefaultModelDirectory => DataDirectoryManager.ModelsDirectory;

    public static string EffectiveModelDirectory =>
        !string.IsNullOrWhiteSpace(CustomModelDirectory) ? CustomModelDirectory : DefaultModelDirectory;

    public static string GetModelRootDirectory()
    {
        string path = Path.Combine(EffectiveModelDirectory, "translation");
        Directory.CreateDirectory(path);
        return path;
    }

    public static string? FindModelDirectory(string modelId)
    {
        List<string> candidates = [];
        if (!string.IsNullOrWhiteSpace(CustomModelDirectory))
        {
            candidates.Add(Path.Combine(CustomModelDirectory, "translation", modelId));
            candidates.Add(Path.Combine(CustomModelDirectory, modelId));
        }
        candidates.Add(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "models", "translation", modelId));
        candidates.Add(Path.Combine(DefaultModelDirectory, "translation", modelId));
        candidates.Add(Path.Combine(DefaultModelDirectory, modelId));

        foreach (var dir in candidates)
        {
            if (Directory.Exists(dir))
            {
                if (Directory.EnumerateFiles(dir, "*.onnx", SearchOption.AllDirectories).Any())
                {
                    return dir;
                }
            }
        }
        return null;
    }

    public void RefreshInstalledStatus()
    {
        lock (_lock)
        {
            foreach (var model in _models)
            {
                string? dir = FindModelDirectory(model.Id);
                model.IsInstalled = dir != null;
                if (model.IsInstalled)
                {
                    model.StatusText = "已安装";
                }
                else if (!model.IsDownloading)
                {
                    model.StatusText = "未安装";
                }
            }
        }
    }

    public OfflineModelInfo? ResolveModel(string? sourceLanguage, string targetLanguage)
    {
        string normTarget = NormalizeLanguage(targetLanguage);
        string? normSource = string.IsNullOrEmpty(sourceLanguage) ? null : NormalizeLanguage(sourceLanguage);

        return _models.FirstOrDefault(m =>
            NormalizeLanguage(m.TargetLanguage) == normTarget &&
            (normSource == null || NormalizeLanguage(m.SourceLanguage) == normSource));
    }

    public static string NormalizeLanguage(string lang)
    {
        string lower = lang.Trim().ToLowerInvariant();
        if (lower.StartsWith("zh")) return "zh-CN";
        if (lower.StartsWith("en")) return "en";
        if (lower.StartsWith("ja")) return "ja";
        if (lower.StartsWith("ko")) return "ko";
        return lower;
    }

    public async Task DownloadModelAsync(OfflineModelInfo model, IProgress<double>? progress = null, CancellationToken ct = default)
    {
        model.IsDownloading = true;
        model.DownloadProgress = 0.0;
        model.StatusText = "准备下载...";

        string targetDir = Path.Combine(GetModelRootDirectory(), model.Id);
        Directory.CreateDirectory(targetDir);

        try
        {
            if (model.DownloadUrls != null && model.DownloadUrls.Count > 0)
            {
                long totalEstimatedBytes = model.SizeBytes > 0 ? model.SizeBytes : 185_000_000;
                long totalReadAccum = 0;

                for (int i = 0; i < model.DownloadUrls.Count; i++)
                {
                    string primaryUrl = model.DownloadUrls[i];
                    string fallbackUrl = primaryUrl.Contains("hf-mirror.com")
                        ? primaryUrl.Replace("hf-mirror.com", "huggingface.co")
                        : primaryUrl;

                    string fileName = GetTargetFileName(primaryUrl);
                    string targetFilePath = Path.Combine(targetDir, fileName);
                    string tempFilePath = targetFilePath + ".tmp";

                    model.StatusText = $"正在下载组件 {fileName} ({i + 1}/{model.DownloadUrls.Count})...";

                    bool downloaded = false;
                    string[] attemptUrls = [primaryUrl, fallbackUrl];

                    foreach (var url in attemptUrls)
                    {
                        try
                        {
                            using var response = await _httpClient.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
                            if (!response.IsSuccessStatusCode) continue;

                            await using (var contentStream = await response.Content.ReadAsStreamAsync(ct))
                            await using (var fileStream = new FileStream(tempFilePath, FileMode.Create, FileAccess.Write, FileShare.None, 81920, true))
                            {
                                var buffer = new byte[81920];
                                int bytesRead;
                                while ((bytesRead = await contentStream.ReadAsync(buffer, ct)) > 0)
                                {
                                    await fileStream.WriteAsync(buffer.AsMemory(0, bytesRead), ct);
                                    totalReadAccum += bytesRead;
                                    double frac = Math.Clamp((double)totalReadAccum / totalEstimatedBytes, 0.0, 0.99);
                                    model.DownloadProgress = frac;
                                    model.StatusText = $"正在下载 ({i + 1}/{model.DownloadUrls.Count}) {(int)(frac * 100)}%";
                                    progress?.Report(frac);
                                }
                            }

                            if (File.Exists(targetFilePath)) File.Delete(targetFilePath);
                            File.Move(tempFilePath, targetFilePath);
                            downloaded = true;
                            break;
                        }
                        catch when (!ct.IsCancellationRequested)
                        {
                            if (File.Exists(tempFilePath)) { try { File.Delete(tempFilePath); } catch { } }
                        }
                    }

                    if (!downloaded)
                    {
                        throw new HttpRequestException($"无法从下载源获取模型组件: {fileName}");
                    }
                }

                model.IsInstalled = true;
                model.StatusText = "已安装";
                model.DownloadProgress = 1.0;
            }
            else if (!string.IsNullOrEmpty(model.DownloadUrl))
            {
                string tempZip = Path.Combine(Path.GetTempPath(), $"polyglance_{model.Id}_{Guid.NewGuid():N}.zip");
                try
                {
                    using (var response = await _httpClient.GetAsync(model.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, ct))
                    {
                        response.EnsureSuccessStatusCode();
                        long totalBytes = response.Content.Headers.ContentLength ?? model.SizeBytes;

                        await using (var contentStream = await response.Content.ReadAsStreamAsync(ct))
                        await using (var fileStream = new FileStream(tempZip, FileMode.Create, FileAccess.Write, FileShare.None, 81920, true))
                        {
                            var buffer = new byte[81920];
                            long totalRead = 0;
                            int bytesRead;

                            while ((bytesRead = await contentStream.ReadAsync(buffer, ct)) > 0)
                            {
                                await fileStream.WriteAsync(buffer.AsMemory(0, bytesRead), ct);
                                totalRead += bytesRead;
                                if (totalBytes > 0)
                                {
                                    double frac = Math.Clamp((double)totalRead / totalBytes, 0.0, 1.0);
                                    model.DownloadProgress = frac;
                                    model.StatusText = $"正在下载 {(int)(frac * 100)}%";
                                    progress?.Report(frac);
                                }
                            }
                        }
                    }

                    model.StatusText = "正在解压模型...";
                    ZipFile.ExtractToDirectory(tempZip, targetDir, true);
                    model.IsInstalled = true;
                    model.StatusText = "已安装";
                    model.DownloadProgress = 1.0;
                }
                finally
                {
                    if (File.Exists(tempZip)) { try { File.Delete(tempZip); } catch { } }
                }
            }
        }
        catch (OperationCanceledException)
        {
            model.StatusText = "已取消下载";
            model.DownloadProgress = 0.0;
            throw;
        }
        catch (Exception ex)
        {
            model.StatusText = $"下载失败: {ex.Message}";
            throw;
        }
        finally
        {
            model.IsDownloading = false;
            RefreshInstalledStatus();
        }
    }

    private static string GetTargetFileName(string url)
    {
        string lower = url.ToLowerInvariant();
        if (lower.EndsWith("vocab.json")) return "vocab.json";
        if (lower.Contains("encoder")) return "encoder.onnx";
        if (lower.Contains("decoder")) return "decoder.onnx";
        return Path.GetFileName(new Uri(url).AbsolutePath);
    }

    public async Task<string> ImportZipAsync(string zipFilePath, string? targetModelId = null)
    {
        if (!File.Exists(zipFilePath))
        {
            throw new FileNotFoundException("未找到选定的模型压缩包", zipFilePath);
        }

        string root = GetModelRootDirectory();
        string modelId = targetModelId ?? "enzh";

        if (string.IsNullOrEmpty(targetModelId))
        {
            string fileName = Path.GetFileNameWithoutExtension(zipFilePath).ToLowerInvariant();
            if (fileName.Contains("zh-en") || fileName.Contains("zhen")) modelId = "zhen";
            else if (fileName.Contains("en-zh") || fileName.Contains("enzh")) modelId = "enzh";
            else if (fileName.Contains("ja-zh") || fileName.Contains("jazh")) modelId = "jazh";
            else if (fileName.Contains("ko-zh") || fileName.Contains("kozh")) modelId = "kozh";
        }

        string targetDir = Path.Combine(root, modelId);
        if (Directory.Exists(targetDir))
        {
            Directory.Delete(targetDir, true);
        }
        Directory.CreateDirectory(targetDir);

        await Task.Run(() => ZipFile.ExtractToDirectory(zipFilePath, targetDir, true));
        RefreshInstalledStatus();
        return modelId;
    }

    public void DeleteModel(string modelId)
    {
        string? existingDir = FindModelDirectory(modelId);
        if (existingDir != null && Directory.Exists(existingDir))
        {
            try { Directory.Delete(existingDir, true); } catch { }
        }
        string targetDir = Path.Combine(GetModelRootDirectory(), modelId);
        if (Directory.Exists(targetDir))
        {
            try { Directory.Delete(targetDir, true); } catch { }
        }
        RefreshInstalledStatus();
    }

    public static void OpenModelsDirectory()
    {
        string path = EffectiveModelDirectory;
        Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo
        {
            FileName = path,
            UseShellExecute = true
        });
    }

    public static void MigrateModels(string sourceDir, string destinationDir)
    {
        if (string.IsNullOrWhiteSpace(sourceDir) || string.IsNullOrWhiteSpace(destinationDir)) return;
        if (!Directory.Exists(sourceDir)) return;
        try
        {
            if (string.Equals(Path.GetFullPath(sourceDir).TrimEnd('\\', '/'), Path.GetFullPath(destinationDir).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase)) return;
            CopyDirectory(sourceDir, destinationDir);
        }
        catch
        {
            // Ignore migration errors on locked files
        }
    }

    private static void CopyDirectory(string sourceDir, string destinationDir)
    {
        Directory.CreateDirectory(destinationDir);

        foreach (string file in Directory.GetFiles(sourceDir))
        {
            string destFile = Path.Combine(destinationDir, Path.GetFileName(file));
            if (!File.Exists(destFile))
            {
                File.Copy(file, destFile, true);
            }
        }

        foreach (string subDir in Directory.GetDirectories(sourceDir))
        {
            string destSubDir = Path.Combine(destinationDir, Path.GetFileName(subDir));
            CopyDirectory(subDir, destSubDir);
        }
    }
}
