using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Polyglance.Platform.Update;

internal static class PendingUpdateStore
{
    internal sealed class PendingUpdate
    {
        public UpdateInfo Update { get; set; } = new();
        public string PackageName { get; set; } = "";
        public string PackageHash { get; set; } = "";
    }

    internal static string CacheDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Polyglance", "Updates",
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(AppContext.BaseDirectory.ToUpperInvariant())))[..16]);
    private static string StatePath => Path.Combine(CacheDirectory, "pending.json");

    internal static void Save(UpdateInfo info, PreparedUpdate prepared)
    {
        if (prepared.PackagePath == null || prepared.PackageHash == null) throw new InvalidDataException("更新包缓存无效。");
        Directory.CreateDirectory(CacheDirectory);
        var pending = new PendingUpdate
        {
            Update = info,
            PackageName = Path.GetFileName(prepared.PackagePath),
            PackageHash = prepared.PackageHash
        };
        File.WriteAllText(StatePath + ".tmp", JsonSerializer.Serialize(pending));
        File.Move(StatePath + ".tmp", StatePath, true);
    }

    internal static async Task<(UpdateInfo Info, PreparedUpdate Prepared)?> RestoreAsync()
    {
        try
        {
            if (!File.Exists(StatePath)) return null;
            var pending = JsonSerializer.Deserialize<PendingUpdate>(await File.ReadAllTextAsync(StatePath));
            if (pending == null || !Guid.TryParseExact(Path.GetFileNameWithoutExtension(pending.PackageName), "N", out _)
                || !pending.PackageName.EndsWith(".zip", StringComparison.Ordinal)
                || Path.GetFileName(pending.PackageName) != pending.PackageName
                || !IsNewer(pending.Update, AppUpdater.CurrentSemanticVersion, AppUpdater.CurrentVersion))
            {
                Clear();
                return null;
            }
            string path = Path.Combine(CacheDirectory, pending.PackageName);
            await using var package = File.OpenRead(path);
            string hash = Convert.ToHexString(await SHA256.HashDataAsync(package));
            if (!hash.Equals(pending.PackageHash, StringComparison.OrdinalIgnoreCase))
            {
                Clear();
                return null;
            }
            return (pending.Update, AppUpdater.PrepareCachedPackage(path, hash));
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Unable to restore pending update: {error.Message}");
            Clear();
            return null;
        }
    }

    internal static bool IsNewer(UpdateInfo info, string version, Version build)
    {
        if (!Version.TryParse(info.BuildVersion, out var remoteBuild)) return false;
        if (SemanticVersion.TryParse(info.Version, out var remote) && SemanticVersion.TryParse(version, out var current))
        {
            int comparison = remote!.CompareTo(current);
            return comparison > 0 || (comparison == 0 && remoteBuild > build);
        }
        return remoteBuild > build;
    }

    internal static void Clear()
    {
        try { File.Delete(StatePath); }
        catch (Exception error) { Debug.WriteLine(error.Message); }
    }
}
