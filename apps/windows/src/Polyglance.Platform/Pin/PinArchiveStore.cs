using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media.Imaging;

namespace Polyglance.Platform.Pin;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum PinArchiveSource
{
    Screenshot,
    LongScreenshot,
    Clipboard,
    Ocr,
    Translation,
    Legacy
}

public static class PinArchiveSourceExtensions
{
    public static string GetDisplayName(this PinArchiveSource source) => source switch
    {
        PinArchiveSource.Screenshot => "截图",
        PinArchiveSource.LongScreenshot => "长截图",
        PinArchiveSource.Clipboard => "剪贴板",
        PinArchiveSource.Ocr => "文字识别",
        PinArchiveSource.Translation => "截屏翻译",
        PinArchiveSource.Legacy => "历史导入",
        _ => "贴图"
    };
}

public sealed class PinArchiveItem
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = Guid.NewGuid().ToString("N");

    [JsonPropertyName("createdAt")]
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;

    [JsonPropertyName("pixelWidth")]
    public int PixelWidth { get; set; }

    [JsonPropertyName("pixelHeight")]
    public int PixelHeight { get; set; }

    [JsonPropertyName("source")]
    public PinArchiveSource Source { get; set; } = PinArchiveSource.Screenshot;

    [JsonPropertyName("imageFileName")]
    public string ImageFileName { get; set; } = "";
}

public sealed class PinArchiveManifest
{
    [JsonPropertyName("version")]
    public int Version { get; set; } = 1;

    [JsonPropertyName("items")]
    public List<PinArchiveItem> Items { get; set; } = new();
}

public sealed class PinArchiveOperationResult
{
    public bool IsSuccess { get; init; }
    public int AffectedCount { get; init; }
    public int FailedCount { get; init; }
    public string? ErrorMessage { get; init; }

    public static PinArchiveOperationResult Success(int count = 1) => new() { IsSuccess = true, AffectedCount = count };
    public static PinArchiveOperationResult Partial(int affected, int failed, string? error = null) =>
        new() { IsSuccess = false, AffectedCount = affected, FailedCount = failed, ErrorMessage = error };
    public static PinArchiveOperationResult Failure(string error) => new() { IsSuccess = false, ErrorMessage = error };
}

public sealed class PinArchiveStore
{
    public static string DefaultDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "Polyglance",
        "PinHistory"
    );

    private static readonly Lazy<PinArchiveStore> _shared = new(() => new PinArchiveStore());
    public static PinArchiveStore Shared => _shared.Value;

    private readonly object _lock = new();
    private readonly JsonSerializerOptions _jsonOptions;
    private readonly object _queueLock = new();
    private Task _pending = Task.CompletedTask;
    private readonly Dictionary<string, (long Size, DateTime Modified, int Width, int Height)> _verifiedImages = new(StringComparer.OrdinalIgnoreCase);

    public Task<T> Schedule<T>(Func<PinArchiveStore, T> operation)
    {
        lock (_queueLock)
        {
            var next = _pending.ContinueWith(_ => operation(this), default,
                TaskContinuationOptions.None, TaskScheduler.Default);
            _pending = next;
            return next;
        }
    }

    public Task<PinArchiveItem?> AppendAsync(BitmapSource bitmap, PinArchiveSource source, string? id = null)
    {
        var snapshot = bitmap.IsFrozen ? bitmap : bitmap.Clone();
        if (!snapshot.IsFrozen) snapshot.Freeze();
        return Schedule(store => store.Append(snapshot, source, id));
    }

    public Task DrainAsync() => Schedule(_ => true);

    public bool ReplaceImage(BitmapSource bitmap, string id)
    {
        lock (_lock)
        {
            var items = LoadManifestLocked().Items;
            var item = items.FirstOrDefault(i => i.Id == id);
            if (item == null || !IsValidImageFileName(item.ImageFileName) || !File.Exists(GetImagePath(item))
                || bitmap.PixelWidth != item.PixelWidth || bitmap.PixelHeight != item.PixelHeight) return false;
            try
            {
                var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using var stream = new MemoryStream(); encoder.Save(stream);
                if (stream.Length + TotalBytes(items.Where(i => i.Id != id)) + QuarantineBytes() > MaxTotalBytes) return false;
                string path = GetImagePath(item);
                File.WriteAllBytes(path + ".tmp", stream.ToArray());
                File.Move(path + ".tmp", path, overwrite: true);
                return true;
            }
            catch { return false; }
        }
    }

    private string SessionPath => Path.Combine(DirectoryPath, "sessions.json");

    private List<PinSessionRecord> ReadSessionsLocked()
    {
        try
        {
            if (!File.Exists(SessionPath) || new FileInfo(SessionPath).Length > 40 * 1048576) return new();
            return (JsonSerializer.Deserialize<List<PinSessionRecord>>(File.ReadAllText(SessionPath), _jsonOptions) ?? new())
                .Where(s => s != null && s.IsValid).DistinctBy(s => s.Id).ToList();
        }
        catch { return new(); }
    }

    public IReadOnlyList<PinSessionRecord> LoadSessions()
    {
        lock (_lock)
        {
            var ids = LoadManifestLocked().Items.Where(i => IsValidImageFileName(i.ImageFileName) && File.Exists(GetImagePath(i)))
                .Select(i => i.Id).ToHashSet();
            return ReadSessionsLocked().Where(s => ids.Contains(s.ArchiveId)).ToList();
        }
    }

    private bool WriteSessionsLocked(IEnumerable<PinSessionRecord> sessions)
    {
        try
        {
            if (File.Exists(SessionPath) && (new FileInfo(SessionPath).Length > 40 * 1048576
                || JsonSerializer.Deserialize<List<PinSessionRecord>>(File.ReadAllText(SessionPath), _jsonOptions) == null)) return false;
            var archivedIds = new HashSet<string>();
            var compact = sessions.Reverse().Where(s => s.Status != PinSessionStatus.Archived || archivedIds.Add(s.ArchiveId)).Reverse().ToArray();
            var json = JsonSerializer.Serialize(compact, _jsonOptions);
            if (System.Text.Encoding.UTF8.GetByteCount(json) > 40 * 1048576) return false;
            File.WriteAllText(SessionPath + ".tmp", json);
            File.Move(SessionPath + ".tmp", SessionPath, overwrite: true);
            return true;
        }
        catch { return false; }
    }

    public bool SaveSession(PinSessionRecord record)
    {
        lock (_lock)
        {
            if (!record.IsValid || !LoadManifestLocked().Items.Any(i => i.Id == record.ArchiveId
                && IsValidImageFileName(i.ImageFileName) && File.Exists(GetImagePath(i)))) return false;
            var records = LoadSessions().Where(s => s.Id != record.Id).Append(record).ToList();
            var oldestClosed = records.Where(s => s.Status == PinSessionStatus.Closed).Reverse().Skip(20).Select(s => s.Id).ToHashSet();
            records = records.Select(s => oldestClosed.Contains(s.Id) ? s with { Status = PinSessionStatus.Archived } : s).ToList();
            records = records.Where(s => s.Status != PinSessionStatus.Archived || !records.Any(other => other.Id != s.Id
                && other.ArchiveId == s.ArchiveId && other.Status != PinSessionStatus.Archived)).ToList();
            return WriteSessionsLocked(records);
        }
    }

    public string DirectoryPath { get; }
    public int MaxCount { get; }
    public long MaxTotalBytes { get; }

    public PinArchiveStore(string? directoryPath = null, int maxCount = 30, long maxTotalBytes = 512 * 1024 * 1024)
    {
        DirectoryPath = directoryPath ?? DefaultDirectory;
        MaxCount = Math.Max(0, maxCount);
        MaxTotalBytes = Math.Max(0, maxTotalBytes);

        _jsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true,
            PropertyNameCaseInsensitive = true,
            Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
        };

        EnsureDirectoryExists();
    }

    private void EnsureDirectoryExists()
    {
        try
        {
            if (!Directory.Exists(DirectoryPath))
            {
                Directory.CreateDirectory(DirectoryPath);
            }
            CleanupStaleTempFiles();
        }
        catch { }
    }

    private void CleanupStaleTempFiles()
    {
        try
        {
            var dirInfo = new DirectoryInfo(DirectoryPath);
            var tempFiles = dirInfo.GetFiles("*.tmp*");
            var threshold = DateTime.UtcNow.AddHours(-1);
            foreach (var file in tempFiles)
            {
                if (file.CreationTimeUtc < threshold)
                {
                    try { file.Delete(); } catch { }
                }
            }
        }
        catch { }
    }

    public bool IsValidImageFileName(string? fileName)
    {
        if (string.IsNullOrWhiteSpace(fileName)) return false;
        if (!fileName.StartsWith("pin_", StringComparison.OrdinalIgnoreCase)) return false;
        if (fileName.Contains(Path.DirectorySeparatorChar) || fileName.Contains(Path.AltDirectorySeparatorChar))
            return false;
        if (fileName.Contains("..")) return false;
        if (!fileName.EndsWith(".png", StringComparison.OrdinalIgnoreCase)) return false;

        try
        {
            string fullPath = Path.GetFullPath(Path.Combine(DirectoryPath, fileName));
            string fullDir = Path.GetFullPath(DirectoryPath);
            if (!string.Equals(Path.GetDirectoryName(fullPath), fullDir, StringComparison.OrdinalIgnoreCase))
                return false;
            if (File.Exists(fullPath) && (File.GetAttributes(fullPath) & FileAttributes.ReparsePoint) != 0)
                return false;
            return true;
        }
        catch
        {
            return false;
        }
    }

    public string GetImagePath(PinArchiveItem item) =>
        Path.Combine(DirectoryPath, item.ImageFileName);

    private static string IdFromFileName(string name)
    {
        var stem = Path.GetFileNameWithoutExtension(name);
        var candidate = stem[(stem.LastIndexOf('_') + 1)..];
        return Guid.TryParse(candidate, out _) ? candidate : Guid.NewGuid().ToString("N");
    }

    public IReadOnlyList<PinArchiveItem> List()
    {
        lock (_lock)
        {
            EnsureDirectoryExists();
            var manifest = LoadManifestLocked();
            bool hasChanges = false;

            // 1. Scan directory for unindexed PNG files to support legacy pin_*.png files idempotently
            try
            {
                var dirInfo = new DirectoryInfo(DirectoryPath);
                var existingFiles = dirInfo.GetFiles("*.png");
                var knownFileNames = new HashSet<string>(
                    manifest.Items.Select(i => i.ImageFileName),
                    StringComparer.OrdinalIgnoreCase);

                foreach (var file in existingFiles)
                {
                    if (!IsValidImageFileName(file.Name))
                        continue;

                    if (!knownFileNames.Contains(file.Name))
                    {
                        var (w, h) = GetPngDimensions(file.FullName);
                        if (w <= 0 || h <= 0)
                        {
                            IsolateCorruptedFile(file.FullName);
                            continue;
                        }

                        var legacyItem = new PinArchiveItem
                        {
                            Id = IdFromFileName(file.Name),
                            CreatedAt = file.CreationTimeUtc,
                            PixelWidth = w,
                            PixelHeight = h,
                            Source = PinArchiveSource.Legacy,
                            ImageFileName = file.Name
                        };
                        manifest.Items.Add(legacyItem);
                        knownFileNames.Add(file.Name);
                        hasChanges = true;
                    }
                }
            }
            catch { }

            // 2. Filter out missing or 0-byte images, or invalid names
            var validItems = new List<PinArchiveItem>(manifest.Items.Count);
            var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var item in manifest.Items)
            {
                if (item == null || string.IsNullOrWhiteSpace(item.Id) || !ids.Add(item.Id)
                    || !names.Add(item.ImageFileName) || !IsValidImageFileName(item.ImageFileName))
                {
                    hasChanges = true;
                    continue;
                }

                string fullPath = GetImagePath(item);
                if (File.Exists(fullPath))
                {
                    try
                    {
                        var fi = new FileInfo(fullPath);
                        if (fi.Length > 0 && GetPngDimensions(fullPath) is var dimensions && dimensions.width > 0)
                        {
                            if (item.PixelWidth != dimensions.width || item.PixelHeight != dimensions.height)
                            {
                                item.PixelWidth = dimensions.width;
                                item.PixelHeight = dimensions.height;
                                hasChanges = true;
                            }
                            validItems.Add(item);
                            continue;
                        }
                        else
                        {
                            IsolateCorruptedFile(fullPath);
                        }
                    }
                    catch { }
                }
                hasChanges = true;
            }

            // 3. Sort newest first
            validItems = validItems.OrderByDescending(i => i.CreatedAt).ToList();

            // 4. Prune to limits (oldest records first)
            var prunedItems = PruneToLimitsLocked(validItems, out bool pruned);
            if (pruned)
            {
                hasChanges = true;
            }

            manifest.Items = prunedItems;

            if (hasChanges)
            {
                SaveManifestLocked(manifest);
            }

            if (File.Exists(SessionPath)) WriteSessionsLocked(LoadSessions());
            return manifest.Items.ToList();
        }
    }

    public BitmapSource? LoadImage(string id)
    {
        lock (_lock)
        {
            var manifest = LoadManifestLocked();
            var item = manifest.Items.FirstOrDefault(i => string.Equals(i.Id, id, StringComparison.OrdinalIgnoreCase));
            if (item == null || !IsValidImageFileName(item.ImageFileName))
                return null;

            string fullPath = GetImagePath(item);
            if (!File.Exists(fullPath))
                return null;

            try
            {
                using var stream = File.OpenRead(fullPath);
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.StreamSource = stream;
                bitmap.EndInit();
                bitmap.Freeze();
                return bitmap;
            }
            catch
            {
                IsolateCorruptedFile(fullPath);
                return null;
            }
        }
    }

    public BitmapSource? LoadThumbnail(string id, int maxPixelDimension = 480)
    {
        lock (_lock)
        {
            var manifest = LoadManifestLocked();
            var item = manifest.Items.FirstOrDefault(i => string.Equals(i.Id, id, StringComparison.OrdinalIgnoreCase));
            if (item == null || !IsValidImageFileName(item.ImageFileName))
                return null;

            string fullPath = GetImagePath(item);
            if (!File.Exists(fullPath))
                return null;

            try
            {
                using var stream = File.OpenRead(fullPath);
                var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None);
                if (decoder.Frames.Count == 0)
                {
                    IsolateCorruptedFile(fullPath);
                    return null;
                }

                var frame = decoder.Frames[0];
                int origW = frame.PixelWidth;
                int origH = frame.PixelHeight;
                if (origW <= 0 || origH <= 0)
                {
                    IsolateCorruptedFile(fullPath);
                    return null;
                }

                int decodeWidth = 0;
                int decodeHeight = 0;
                if (origW >= origH && origW > maxPixelDimension)
                {
                    decodeWidth = maxPixelDimension;
                }
                else if (origH > origW && origH > maxPixelDimension)
                {
                    decodeHeight = maxPixelDimension;
                }

                stream.Position = 0;
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                if (decodeWidth > 0) bitmap.DecodePixelWidth = decodeWidth;
                if (decodeHeight > 0) bitmap.DecodePixelHeight = decodeHeight;
                bitmap.StreamSource = stream;
                bitmap.EndInit();
                bitmap.Freeze();
                return bitmap;
            }
            catch
            {
                IsolateCorruptedFile(fullPath);
                return null;
            }
        }
    }

    public PinArchiveItem? Append(BitmapSource bitmap, PinArchiveSource source, string? reservedId = null)
    {
        lock (_lock)
        {
            if (MaxCount <= 0 || MaxTotalBytes <= 0)
                return null;

            EnsureDirectoryExists();

            // Recover/import before writing the PNG: recovery must not import the new image twice.
            var manifest = new PinArchiveManifest { Items = List().ToList() };

            byte[] pngBytes;
            try
            {
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using var ms = new MemoryStream();
                encoder.Save(ms);
                pngBytes = ms.ToArray();
            }
            catch
            {
                return null;
            }

            if (pngBytes.Length > MaxTotalBytes)
                return null;

            string id = reservedId ?? Guid.NewGuid().ToString("N");
            if (!Guid.TryParse(id, out _) || manifest.Items.Any(i => i.Id == id)) return null;
            string fileName = $"pin_{DateTime.UtcNow:yyyyMMdd_HHmmss}_{id}.png";
            string filePath = Path.Combine(DirectoryPath, fileName);

            try
            {
                string tempFile = Path.Combine(DirectoryPath, $"{fileName}.tmp");
                File.WriteAllBytes(tempFile, pngBytes);
                File.Move(tempFile, filePath, overwrite: true);
            }
            catch
            {
                return null;
            }

            var newItem = new PinArchiveItem
            {
                Id = id,
                CreatedAt = DateTime.UtcNow,
                PixelWidth = bitmap.PixelWidth,
                PixelHeight = bitmap.PixelHeight,
                Source = source,
                ImageFileName = fileName
            };

            manifest.Items.Insert(0, newItem);
            if (!SaveManifestLocked(manifest))
            {
                // Rollback newly written PNG if manifest save fails
                try
                {
                    if (File.Exists(filePath))
                        File.Delete(filePath);
                }
                catch { }
                return null;
            }

            manifest.Items = PruneToLimitsLocked(manifest.Items, out _);
            if (manifest.Items.Count > MaxCount || TotalBytes(manifest.Items) + QuarantineBytes() > MaxTotalBytes)
            {
                try
                {
                    File.Delete(filePath);
                    manifest.Items.RemoveAll(i => i.Id == id);
                }
                catch { /* Keep a failed rollback visible and manageable. */ }
                SaveManifestLocked(manifest);
                return null;
            }
            if (!SaveManifestLocked(manifest)) return null;
            if (!manifest.Items.Any(i => i.Id == id)) return null;

            return newItem;
        }
    }

    public PinArchiveOperationResult Delete(string id)
    {
        lock (_lock)
        {
            var manifest = LoadManifestLocked();
            int index = manifest.Items.FindIndex(i => string.Equals(i.Id, id, StringComparison.OrdinalIgnoreCase));
            if (index < 0)
            {
                if (Guid.TryParse(id, out _))
                {
                    try
                    {
                        foreach (var orphanPath in Directory.GetFiles(DirectoryPath, "pin_*.png"))
                            if (IsValidImageFileName(Path.GetFileName(orphanPath)) && string.Equals(IdFromFileName(Path.GetFileName(orphanPath)), id, StringComparison.OrdinalIgnoreCase))
                                File.Delete(orphanPath);
                    }
                    catch { return PinArchiveOperationResult.Failure("无法删除磁盘图片文件，请重试。"); }
                    return WriteSessionsLocked(ReadSessionsLocked().Where(s => s.ArchiveId != id))
                        ? PinArchiveOperationResult.Success(0) : PinArchiveOperationResult.Failure("贴图状态清理失败，请重试。");
                }
                return PinArchiveOperationResult.Failure("未找到对应的贴图记录。");
            }

            var item = manifest.Items[index];
            if (!IsValidImageFileName(item.ImageFileName))
                return PinArchiveOperationResult.Failure("历史文件路径无效。");
            string path = GetImagePath(item);
            if (File.Exists(path))
            {
                try
                {
                    File.Delete(path);
                }
                catch (Exception ex)
                {
                    return PinArchiveOperationResult.Failure($"删除图片文件失败：{ex.Message}");
                }
            }

            manifest.Items.RemoveAt(index);
            if (!SaveManifestLocked(manifest))
            {
                return PinArchiveOperationResult.Failure("更新历史索引文件失败。");
            }

            if (!WriteSessionsLocked(LoadSessions().Where(s => s.ArchiveId != id)))
                return PinArchiveOperationResult.Failure("图片已删除，但贴图状态清理失败，请重试。");
            return PinArchiveOperationResult.Success(1);
        }
    }

    public PinArchiveOperationResult DeleteAll()
    {
        lock (_lock)
        {
            var manifest = LoadManifestLocked();
            try
            {
                var known = manifest.Items.Select(i => i.ImageFileName).ToHashSet(StringComparer.OrdinalIgnoreCase);
                foreach (var path in Directory.GetFiles(DirectoryPath, "pin_*.png"))
                {
                    string name = Path.GetFileName(path);
                    if (IsValidImageFileName(name) && !known.Contains(name))
                        manifest.Items.Add(new PinArchiveItem { Id = IdFromFileName(name), ImageFileName = name, Source = PinArchiveSource.Legacy });
                }
            }
            catch { return PinArchiveOperationResult.Failure("无法读取历史目录，请检查权限后重试。"); }
            int total = manifest.Items.Count;
            int failed = 0;
            var remainingItems = new List<PinArchiveItem>();

            foreach (var item in manifest.Items)
            {
                if (item == null || !IsValidImageFileName(item.ImageFileName))
                {
                    failed++;
                    if (item != null) remainingItems.Add(item);
                    continue;
                }
                string path = GetImagePath(item);
                if (File.Exists(path))
                {
                    try
                    {
                        File.Delete(path);
                    }
                    catch
                    {
                        failed++;
                        remainingItems.Add(item);
                        continue;
                    }
                }
            }

            manifest.Items = remainingItems;
            try
            {
                foreach (var path in Directory.GetFiles(DirectoryPath, "pin_*.png.corrupted"))
                {
                    total++;
                    try { File.Delete(path); } catch { failed++; }
                }
            }
            catch { failed++; }
            if (!SaveManifestLocked(manifest))
                return PinArchiveOperationResult.Partial(Math.Max(0, total - failed), failed, "历史索引文件保存失败，请重试。");
            if (!WriteSessionsLocked(LoadSessions()))
                return PinArchiveOperationResult.Partial(Math.Max(0, total - failed), failed, "贴图状态清理失败，请重试。");

            if (failed > 0)
            {
                return PinArchiveOperationResult.Partial(total - failed, failed, $"部分文件正在被占用或无权删除，剩余 {failed} 项未能删除。");
            }

            return PinArchiveOperationResult.Success(total);
        }
    }

    private PinArchiveManifest LoadManifestLocked()
    {
        string indexPath = Path.Combine(DirectoryPath, "index.json");
        if (File.Exists(indexPath))
        {
            try
            {
                string json = File.ReadAllText(indexPath);
                var manifest = JsonSerializer.Deserialize<PinArchiveManifest>(json, _jsonOptions);
                if (manifest != null && manifest.Items != null)
                {
                    return manifest;
                }
            }
            catch
            {
                // Corrupted index: backup it and reconstruct from existing valid PNG files
                BackupCorruptedIndex(indexPath);
                return ReconstructManifestFromDirectoryLocked();
            }
        }

        return new PinArchiveManifest();
    }

    private void BackupCorruptedIndex(string indexPath)
    {
        try
        {
            string timestamp = DateTime.UtcNow.ToString("yyyyMMdd_HHmmss");
            string backupName = $"index.json.corrupted.{timestamp}_{Guid.NewGuid().ToString("N")[..6]}";
            string backupPath = Path.Combine(DirectoryPath, backupName);
            File.Move(indexPath, backupPath, overwrite: true);

            // Retain at most 3 corrupted backups
            var dir = new DirectoryInfo(DirectoryPath);
            var corruptedFiles = dir.GetFiles("index.json.corrupted.*")
                .OrderByDescending(f => f.CreationTimeUtc)
                .ToList();

            for (int i = 3; i < corruptedFiles.Count; i++)
            {
                try { corruptedFiles[i].Delete(); } catch { }
            }
        }
        catch { }
    }

    private PinArchiveManifest ReconstructManifestFromDirectoryLocked()
    {
        var manifest = new PinArchiveManifest();
        try
        {
            var dirInfo = new DirectoryInfo(DirectoryPath);
            var pngFiles = dirInfo.GetFiles("*.png")
                .OrderByDescending(f => f.CreationTimeUtc)
                .ToList();

            foreach (var file in pngFiles)
            {
                if (!IsValidImageFileName(file.Name))
                    continue;

                var (w, h) = GetPngDimensions(file.FullName);
                if (w <= 0 || h <= 0)
                {
                    IsolateCorruptedFile(file.FullName);
                    continue;
                }

                manifest.Items.Add(new PinArchiveItem
                {
                    Id = IdFromFileName(file.Name),
                    CreatedAt = file.CreationTimeUtc,
                    PixelWidth = w,
                    PixelHeight = h,
                    Source = PinArchiveSource.Legacy,
                    ImageFileName = file.Name
                });
            }

            SaveManifestLocked(manifest);
        }
        catch { }

        return manifest;
    }

    private bool SaveManifestLocked(PinArchiveManifest manifest)
    {
        try
        {
            EnsureDirectoryExists();
            string tempFile = Path.Combine(DirectoryPath, $"index.json.tmp.{Guid.NewGuid():N}");
            string json = JsonSerializer.Serialize(manifest, _jsonOptions);
            File.WriteAllText(tempFile, json);
            string targetFile = Path.Combine(DirectoryPath, "index.json");
            File.Move(tempFile, targetFile, overwrite: true);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private List<PinArchiveItem> PruneToLimitsLocked(List<PinArchiveItem> items, out bool changed)
    {
        var current = new List<PinArchiveItem>(items);
        changed = false;
        if (!PruneQuarantine(TotalBytes(current))) return current;
        var activeIds = ReadSessionsLocked().Where(s => s.Status == PinSessionStatus.Active).Select(s => s.ArchiveId).ToHashSet();

        // Prune oldest items first
        while (current.Count > MaxCount)
        {
            int index = current.FindLastIndex(i => !activeIds.Contains(i.Id));
            if (index < 0) break;
            var oldest = current[index];
            current.RemoveAt(index);
            try
            {
                string path = GetImagePath(oldest);
                if (File.Exists(path))
                    File.Delete(path);
            }
            catch
            {
                current.Add(oldest);
                break;
            }
            changed = true;
        }

        long totalBytes = QuarantineBytes();
        foreach (var item in current)
        {
            try
            {
                string path = GetImagePath(item);
                if (File.Exists(path))
                    totalBytes += new FileInfo(path).Length;
            }
            catch { }
        }

        while (totalBytes > MaxTotalBytes && current.Count > 0)
        {
            int index = current.FindLastIndex(i => !activeIds.Contains(i.Id));
            if (index < 0) break;
            var oldest = current[index];
            current.RemoveAt(index);
            try
            {
                string path = GetImagePath(oldest);
                if (File.Exists(path))
                {
                    var fi = new FileInfo(path);
                    long size = fi.Length;
                    fi.Delete();
                    totalBytes -= size;
                }
            }
            catch
            {
                current.Add(oldest);
                break;
            }
            changed = true;
        }

        return current;
    }

    private long TotalBytes(IEnumerable<PinArchiveItem> items) => items.Sum(item => SafeLength(GetImagePath(item)));

    private static long SafeLength(string path)
    {
        try { return File.Exists(path) ? new FileInfo(path).Length : 0; }
        catch { return 0; } // The subsequent deletion/write still reports its own failure.
    }

    private FileInfo[] QuarantineFiles()
    {
        try { return new DirectoryInfo(DirectoryPath).GetFiles("pin_*.png.corrupted"); }
        catch { return Array.Empty<FileInfo>(); }
    }

    private long QuarantineBytes() => QuarantineFiles().Sum(file => SafeLength(file.FullName));

    private bool PruneQuarantine(long imageBytes)
    {
        try
        {
            var files = QuarantineFiles().OrderBy(file => file.LastWriteTimeUtc).ToList();
            long bytes = files.Sum(file => file.Length);
            while (files.Count > 0 && (files.Count > 3 || bytes + imageBytes > MaxTotalBytes))
            {
                var oldest = files[0];
                long size = oldest.Length;
                oldest.Delete();
                bytes -= size;
                files.RemoveAt(0);
            }
            return true;
        }
        catch { return false; }
    }

    private static void IsolateCorruptedFile(string fullPath)
    {
        try
        {
            if (File.Exists(fullPath) && !fullPath.EndsWith(".corrupted", StringComparison.OrdinalIgnoreCase))
            {
                string corruptedPath = $"{fullPath}.corrupted";
                if (File.Exists(corruptedPath))
                    File.Delete(corruptedPath);
                File.Move(fullPath, corruptedPath);
            }
        }
        catch { }
    }

    private (int width, int height) GetPngDimensions(string filePath)
    {
        try
        {
            var file = new FileInfo(filePath);
            if (_verifiedImages.TryGetValue(filePath, out var cached) && cached.Size == file.Length && cached.Modified == file.LastWriteTimeUtc)
                return (cached.Width, cached.Height);
            using var stream = File.OpenRead(filePath);
            var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
            if (decoder.Frames.Count == 0) return (0, 0);
            var frame = decoder.Frames[0];
            int width = frame.PixelWidth, height = frame.PixelHeight;
            if (width <= 0 || height <= 0) return (0, 0);
            // Force all pixel rows to decode; a plausible PNG header is not enough.
            int stride = checked((width * frame.Format.BitsPerPixel + 7) / 8);
            int rows = Math.Min(64, height);
            var buffer = new byte[checked(stride * rows)];
            for (int y = 0; y < height; y += rows)
                frame.CopyPixels(new Int32Rect(0, y, width, Math.Min(rows, height - y)), buffer, stride, 0);
            _verifiedImages[filePath] = (file.Length, file.LastWriteTimeUtc, width, height);
            return (width, height);
        }
        catch { return (0, 0); }
    }
}
