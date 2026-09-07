using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Polyglance.Platform.Pin;
using Xunit;

namespace Polyglance.Platform.Tests;

public sealed class PinArchiveStoreTests : IDisposable
{
    private readonly string _testDirectory;

    public PinArchiveStoreTests()
    {
        _testDirectory = Path.Combine(Path.GetTempPath(), $"PinArchiveStoreTests_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_testDirectory);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_testDirectory))
                Directory.Delete(_testDirectory, true);
        }
        catch { }
    }

    private static BitmapSource CreateSolidBitmap(int width, int height, byte r = 0xFF, byte g = 0, byte b = 0)
    {
        byte[] pixels = new byte[width * height * 4];
        for (int i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = b;
            pixels[i + 1] = g;
            pixels[i + 2] = r;
            pixels[i + 3] = 0xFF;
        }
        var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    [Fact]
    public void NewItemsAreReturnedInReverseChronologicalOrder()
    {
        var store = new PinArchiveStore(_testDirectory, maxCount: 10, maxTotalBytes: 10 * 1024 * 1024);
        var img1 = CreateSolidBitmap(10, 10);
        var img2 = CreateSolidBitmap(20, 20);

        var item1 = store.Append(img1, PinArchiveSource.Screenshot);
        Thread.Sleep(50);
        var item2 = store.Append(img2, PinArchiveSource.Clipboard);

        Assert.NotNull(item1);
        Assert.NotNull(item2);

        var items = store.List();
        Assert.Equal(2, items.Count);
        Assert.Equal(item2!.Id, items[0].Id);
        Assert.Equal(PinArchiveSource.Clipboard, items[0].Source);
        Assert.Equal(item1!.Id, items[1].Id);
        Assert.Equal(PinArchiveSource.Screenshot, items[1].Source);
    }

    [Fact]
    public void AppendRecoversIndexBeforeWritingNewImage()
    {
        var store = new PinArchiveStore(_testDirectory);
        store.Append(CreateSolidBitmap(10, 10), PinArchiveSource.Screenshot);
        File.WriteAllText(Path.Combine(_testDirectory, "index.json"), "broken");
        var added = store.Append(CreateSolidBitmap(10, 10), PinArchiveSource.Clipboard)!;
        var items = store.List();
        Assert.Equal(2, items.Count);
        Assert.Single(items, i => i.ImageFileName == added.ImageFileName);
    }

    [Fact]
    public void IndexedTruncatedImageIsExcludedAndClearRemovesQuarantine()
    {
        var store = new PinArchiveStore(_testDirectory);
        var item = store.Append(CreateSolidBitmap(10, 10), PinArchiveSource.Screenshot)!;
        string path = store.GetImagePath(item);
        File.WriteAllBytes(path, File.ReadAllBytes(path).Take(33).ToArray());
        Assert.Empty(store.List());
        store.DeleteAll();
        Assert.Empty(Directory.GetFiles(_testDirectory, "pin_*"));
    }

    [Fact]
    public void CapacityCleanupKeepsLockedRecordAndRejectsNewImage()
    {
        var store = new PinArchiveStore(_testDirectory, maxCount: 1);
        var old = store.Append(CreateSolidBitmap(10, 10), PinArchiveSource.Screenshot)!;
        using var held = new FileStream(store.GetImagePath(old), FileMode.Open, FileAccess.Read, FileShare.Read);
        Assert.Null(store.Append(CreateSolidBitmap(10, 10), PinArchiveSource.Clipboard));
        Assert.Equal(old.Id, Assert.Single(store.List()).Id);
    }

    [Fact]
    public void ClearReportsIndexWriteFailure()
    {
        var store = new PinArchiveStore(_testDirectory);
        Directory.CreateDirectory(Path.Combine(_testDirectory, "index.json"));
        Assert.False(store.DeleteAll().IsSuccess);
    }

    [Fact]
    public async Task QueuedWriteThenClearCannotResurrectImage()
    {
        var store = new PinArchiveStore(_testDirectory);
        var write = store.AppendAsync(CreateSolidBitmap(10, 10), PinArchiveSource.Screenshot);
        var clear = store.Schedule(s => s.DeleteAll());
        Assert.NotNull(await write);
        Assert.True((await clear).IsSuccess);
        Assert.Empty(store.List());
    }

    [Fact]
    public void EvictionOnCountLimit()
    {
        var store = new PinArchiveStore(_testDirectory, maxCount: 2, maxTotalBytes: 10 * 1024 * 1024);
        var img = CreateSolidBitmap(10, 10);

        var item1 = store.Append(img, PinArchiveSource.Screenshot);
        Thread.Sleep(20);
        var item2 = store.Append(img, PinArchiveSource.LongScreenshot);
        Thread.Sleep(20);
        var item3 = store.Append(img, PinArchiveSource.Ocr);

        Assert.NotNull(item1);
        Assert.NotNull(item2);
        Assert.NotNull(item3);

        var items = store.List();
        Assert.Equal(2, items.Count);
        Assert.Equal(new[] { item3!.Id, item2!.Id }, items.Select(x => x.Id));

        string file1 = Path.Combine(_testDirectory, item1!.ImageFileName);
        Assert.False(File.Exists(file1));
    }

    [Fact]
    public void EvictionOnByteLimit()
    {
        var img = CreateSolidBitmap(10, 10);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(img));
        using var ms = new MemoryStream();
        encoder.Save(ms);
        long singleSize = ms.Length;

        var store = new PinArchiveStore(_testDirectory, maxCount: 10, maxTotalBytes: singleSize + 10);

        var item1 = store.Append(img, PinArchiveSource.Screenshot);
        Thread.Sleep(20);
        var item2 = store.Append(img, PinArchiveSource.Translation);

        Assert.NotNull(item1);
        Assert.NotNull(item2);

        var items = store.List();
        Assert.Single(items);
        Assert.Equal(item2!.Id, items[0].Id);

        string file1 = Path.Combine(_testDirectory, item1!.ImageFileName);
        Assert.False(File.Exists(file1));
    }

    [Fact]
    public void PersistenceAcrossStoreInstances()
    {
        var store1 = new PinArchiveStore(_testDirectory, maxCount: 10, maxTotalBytes: 10 * 1024 * 1024);
        var img = CreateSolidBitmap(32, 24);
        var item = store1.Append(img, PinArchiveSource.Screenshot);
        Assert.NotNull(item);

        var store2 = new PinArchiveStore(_testDirectory, maxCount: 10, maxTotalBytes: 10 * 1024 * 1024);
        var items = store2.List();
        Assert.Single(items);
        Assert.Equal(item!.Id, items[0].Id);
        Assert.Equal(32, items[0].PixelWidth);
        Assert.Equal(24, items[0].PixelHeight);

        var loadedImage = store2.LoadImage(item.Id);
        Assert.NotNull(loadedImage);
        Assert.Equal(32, loadedImage!.PixelWidth);
        Assert.Equal(24, loadedImage.PixelHeight);
    }

    [Fact]
    public void CorruptedOrMissingImageSkippedAndRepairsIndex()
    {
        var store1 = new PinArchiveStore(_testDirectory, maxCount: 10, maxTotalBytes: 10 * 1024 * 1024);
        var img = CreateSolidBitmap(10, 10);
        var item1 = store1.Append(img, PinArchiveSource.Screenshot);
        Thread.Sleep(20);
        var item2 = store1.Append(img, PinArchiveSource.Clipboard);

        Assert.NotNull(item1);
        Assert.NotNull(item2);

        File.Delete(Path.Combine(_testDirectory, item1!.ImageFileName));

        var store2 = new PinArchiveStore(_testDirectory, maxCount: 10, maxTotalBytes: 10 * 1024 * 1024);
        var items = store2.List();
        Assert.Single(items);
        Assert.Equal(item2!.Id, items[0].Id);

        var store3 = new PinArchiveStore(_testDirectory, maxCount: 10, maxTotalBytes: 10 * 1024 * 1024);
        Assert.Single(store3.List());
    }

    [Fact]
    public void LoadThumbnailLimitsMaxPixelDimensionAndFreezes()
    {
        var store = new PinArchiveStore(_testDirectory, maxCount: 10, maxTotalBytes: 10 * 1024 * 1024);
        var largeImg = CreateSolidBitmap(1200, 800);
        var item = store.Append(largeImg, PinArchiveSource.Screenshot);
        Assert.NotNull(item);

        var thumb = store.LoadThumbnail(item!.Id, maxPixelDimension: 480);
        Assert.NotNull(thumb);
        Assert.True(thumb!.IsFrozen);
        Assert.Equal(480, thumb.PixelWidth);
        Assert.Equal(320, thumb.PixelHeight);
    }

    [Fact]
    public void CorruptedIndexRecoversExistingPngsAndCreatesBackup()
    {
        var store = new PinArchiveStore(_testDirectory, maxCount: 10, maxTotalBytes: 10 * 1024 * 1024);
        var img1 = CreateSolidBitmap(100, 100);
        var img2 = CreateSolidBitmap(200, 150);
        var item1 = store.Append(img1, PinArchiveSource.Screenshot);
        var item2 = store.Append(img2, PinArchiveSource.Clipboard);
        Assert.NotNull(item1);
        Assert.NotNull(item2);

        string indexFile = Path.Combine(_testDirectory, "index.json");
        File.WriteAllText(indexFile, "{ broken json corrupt !");

        // Recreate store or call List: it must backup the corrupted index and reconstruct manifest
        var store2 = new PinArchiveStore(_testDirectory, maxCount: 10, maxTotalBytes: 10 * 1024 * 1024);
        var items = store2.List();

        Assert.Equal(2, items.Count);
        var backupFiles = Directory.GetFiles(_testDirectory, "index.json.corrupted.*");
        Assert.Single(backupFiles);

        // Images can still be loaded and thumbnailed
        var thumb = store2.LoadThumbnail(items[0].Id);
        Assert.NotNull(thumb);
    }

    [Fact]
    public void CorruptedImageFileIsIsolatedAndSkipped()
    {
        var store = new PinArchiveStore(_testDirectory, maxCount: 10, maxTotalBytes: 10 * 1024 * 1024);
        var validImg = CreateSolidBitmap(50, 50);
        var item = store.Append(validImg, PinArchiveSource.Screenshot);
        Assert.NotNull(item);

        // Put a fake broken PNG file
        string brokenFileName = "pin_broken_test.png";
        string brokenFilePath = Path.Combine(_testDirectory, brokenFileName);
        File.WriteAllText(brokenFilePath, "NOT A REAL PNG FILE AT ALL");

        var items = store.List();
        Assert.Single(items);
        Assert.Equal(item!.Id, items[0].Id);

        // Broken file should have been renamed to .corrupted
        Assert.False(File.Exists(brokenFilePath));
        Assert.True(File.Exists($"{brokenFilePath}.corrupted"));

        // Subsequent list should not re-import the corrupted file
        var items2 = store.List();
        Assert.Single(items2);
    }

    [Fact]
    public void PathSecurityRejectsPathTraversal()
    {
        var store = new PinArchiveStore(_testDirectory);
        Assert.False(store.IsValidImageFileName("../secret.png"));
        Assert.False(store.IsValidImageFileName("..\\secret.png"));
        Assert.False(store.IsValidImageFileName("C:\\Windows\\system32\\cmd.png"));
        Assert.False(store.IsValidImageFileName("/etc/passwd.png"));
        Assert.False(store.IsValidImageFileName("photo.jpg"));
        Assert.True(store.IsValidImageFileName("pin_20260101_120000_abc.png"));
    }

    [Fact]
    public void DeleteSingleItemReturnsSuccess()
    {
        var store = new PinArchiveStore(_testDirectory, maxCount: 10, maxTotalBytes: 10 * 1024 * 1024);
        var img = CreateSolidBitmap(10, 10);
        var item1 = store.Append(img, PinArchiveSource.Screenshot);
        var item2 = store.Append(img, PinArchiveSource.Clipboard);

        Assert.NotNull(item1);
        Assert.NotNull(item2);

        var result = store.Delete(item1!.Id);
        Assert.True(result.IsSuccess);
        Assert.Equal(1, result.AffectedCount);

        var items = store.List();
        Assert.Single(items);
        Assert.Equal(item2!.Id, items[0].Id);
        Assert.False(File.Exists(Path.Combine(_testDirectory, item1.ImageFileName)));

        var notFoundResult = store.Delete("non_existent_id");
        Assert.False(notFoundResult.IsSuccess);
    }

    [Fact]
    public void DeleteAllReturnsSuccess()
    {
        var store = new PinArchiveStore(_testDirectory, maxCount: 10, maxTotalBytes: 10 * 1024 * 1024);
        var img = CreateSolidBitmap(10, 10);
        var item1 = store.Append(img, PinArchiveSource.Screenshot);
        var item2 = store.Append(img, PinArchiveSource.Clipboard);

        Assert.NotNull(item1);
        Assert.NotNull(item2);

        var result = store.DeleteAll();
        Assert.True(result.IsSuccess);
        Assert.Equal(2, result.AffectedCount);

        Assert.Empty(store.List());
        Assert.False(File.Exists(Path.Combine(_testDirectory, item1!.ImageFileName)));
        Assert.False(File.Exists(Path.Combine(_testDirectory, item2!.ImageFileName)));
    }

    [Fact]
    public void LegacyMigrationIsIdempotent()
    {
        // Place a legacy pin_*.png into directory without index.json
        string legacyFileName = "pin_20260101_120000_legacy123.png";
        string legacyFilePath = Path.Combine(_testDirectory, legacyFileName);
        var bitmap = CreateSolidBitmap(45, 30);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using (var stream = File.Create(legacyFilePath))
        {
            encoder.Save(stream);
        }

        var store = new PinArchiveStore(_testDirectory, maxCount: 10, maxTotalBytes: 10 * 1024 * 1024);
        var items = store.List();

        Assert.Single(items);
        Assert.Equal(PinArchiveSource.Legacy, items[0].Source);
        Assert.Equal(legacyFileName, items[0].ImageFileName);
        Assert.Equal(45, items[0].PixelWidth);
        Assert.Equal(30, items[0].PixelHeight);

        // Restart another store instance: must be idempotent and not create duplicate items
        var store2 = new PinArchiveStore(_testDirectory, maxCount: 10, maxTotalBytes: 10 * 1024 * 1024);
        var items2 = store2.List();
        Assert.Single(items2);
        Assert.Equal(items[0].Id, items2[0].Id);
    }
}
