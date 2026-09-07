using System;
using System.Collections.Generic;
using System.Linq;
using System.IO;
using System.Windows.Media.Imaging;

namespace Polyglance.Platform.Pin;

public sealed class PinHistoryItem
{
    public string FilePath { get; set; } = "";
    public DateTime CreatedAt { get; set; } = DateTime.Now;
    public int Width { get; set; }
    public int Height { get; set; }
}

public static class PinHistoryManager
{
    private static PinArchiveStore? _overrideStore;
    private static readonly Lazy<PinArchiveStore> _defaultStore = new(() =>
    {
        // Existing UI tests create pins without supplying a store; never write to real history.
        bool testing = AppDomain.CurrentDomain.GetAssemblies().Any(assembly =>
            assembly.GetName().Name?.StartsWith("xunit", StringComparison.OrdinalIgnoreCase) == true);
        return testing
            ? new PinArchiveStore(Path.Combine(Path.GetTempPath(), "PolyglanceTestArchive-" + Guid.NewGuid().ToString("N")))
            : PinArchiveStore.Shared;
    });
    public static PinArchiveStore DefaultStore => _overrideStore ?? _defaultStore.Value;

    public static void SetOverrideStore(PinArchiveStore? store) => _overrideStore = store;

    public static void SavePinToHistory(BitmapSource bitmap, PinArchiveSource source = PinArchiveSource.Screenshot)
    {
        DefaultStore.Append(bitmap, source);
    }

    public static List<PinHistoryItem> GetRecentPins()
    {
        var store = DefaultStore;
        return store.List().Select(item => new PinHistoryItem
        {
            FilePath = store.GetImagePath(item),
            CreatedAt = item.CreatedAt.ToLocalTime(),
            Width = item.PixelWidth,
            Height = item.PixelHeight
        }).ToList();
    }
}
