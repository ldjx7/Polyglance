using System;
using System.IO;
using System.Linq;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Polyglance.Platform.Pin;
using Xunit;

namespace Polyglance.Platform.Tests;

public sealed class PinSessionTests : IDisposable
{
    [Fact]
    public void SessionMemoryBudgetUsesDecodedImageDimensions()
    {
        var store = new PinArchiveStore(_directory);
        Assert.NotNull(store.Append(Image(), PinArchiveSource.Clipboard));
        string path = Path.Combine(_directory, "index.json");
        var json = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(path))!;
        json["items"]![0]!["pixelWidth"] = int.MaxValue;
        json["items"]![0]!["pixelHeight"] = int.MaxValue;
        File.WriteAllText(path, json.ToJsonString());
        var item = Assert.Single(store.List());
        Assert.Equal(8, item.PixelWidth);
        Assert.Equal(8, item.PixelHeight);
    }
    [Fact]
    public void MissingIndexDoesNotLetDestroyOrClearLeaveOrphanImages()
    {
        var store = new PinArchiveStore(_directory);
        var item = store.Append(Image(), PinArchiveSource.Clipboard)!;
        File.Delete(Path.Combine(_directory, "index.json"));
        Assert.True(store.Delete(item.Id).IsSuccess);
        Assert.Empty(store.List());
        Assert.NotNull(store.Append(Image(), PinArchiveSource.Clipboard));
        File.Delete(Path.Combine(_directory, "index.json"));
        Assert.True(store.DeleteAll().IsSuccess);
        Assert.Empty(store.List());
    }
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "PolyglanceSessionTest-" + Guid.NewGuid());
    private static BitmapSource Image()
    {
        var image = BitmapSource.Create(8, 8, 96, 96, PixelFormats.Bgra32, null, new byte[8 * 8 * 4], 32);
        image.Freeze();
        return image;
    }

    [Fact]
    public void SessionRoundTripAndDestroyRemovesOriginalText()
    {
        var store = new PinArchiveStore(_directory);
        var item = store.Append(Image(), PinArchiveSource.Clipboard)!;
        var state = new PinSessionRecord { ArchiveId = item.Id, Text = "original text", X = -500, Y = 90, Width = 300, Height = 200, Opacity = .6 };
        Assert.True(store.SaveSession(state));
        var loaded = new PinArchiveStore(_directory).LoadSessions().Single();
        Assert.Equal(state.Text, loaded.Text);
        Assert.Equal(state.X, loaded.X);
        Assert.Equal(state.Opacity, loaded.Opacity);
        Assert.True(store.Delete(item.Id).IsSuccess);
        Assert.Empty(store.LoadSessions());
        Assert.False(store.SaveSession(state));
        Assert.DoesNotContain("original text", File.ReadAllText(Path.Combine(_directory, "sessions.json")));
    }

    [Fact]
    public void ActiveImageIsNotEvictedByNewHistory()
    {
        var store = new PinArchiveStore(_directory, maxCount: 2);
        var active = store.Append(Image(), PinArchiveSource.Clipboard)!;
        Assert.True(store.SaveSession(new PinSessionRecord { ArchiveId = active.Id, Width = 100, Height = 100 }));
        var old = store.Append(Image(), PinArchiveSource.Screenshot)!;
        Assert.NotNull(store.Append(Image(), PinArchiveSource.Screenshot));
        Assert.NotNull(store.LoadImage(active.Id));
        Assert.Null(store.LoadImage(old.Id));
    }

    public void Dispose() { if (Directory.Exists(_directory)) Directory.Delete(_directory, true); }

    [Fact]
    public void ClosedHistoryIsBoundedAndClearRemovesText()
    {
        var store = new PinArchiveStore(_directory);
        var item = store.Append(Image(), PinArchiveSource.Clipboard)!;
        for (int number = 0; number < 25; number++)
            Assert.True(store.SaveSession(new PinSessionRecord { ArchiveId = item.Id, Text = "text-" + number, Status = PinSessionStatus.Closed }));
        Assert.Equal(20, store.LoadSessions().Count(s => s.Status == PinSessionStatus.Closed));
        Assert.Equal("text-24", store.LoadSessions().Last().Text);
        Assert.True(store.DeleteAll().IsSuccess);
        Assert.Empty(store.LoadSessions());
        Assert.DoesNotContain("text-", File.ReadAllText(Path.Combine(_directory, "sessions.json")));
    }

    [Fact]
    public void FullActiveArchiveRejectsNewImageWithoutEviction()
    {
        var store = new PinArchiveStore(_directory, maxCount: 1);
        var active = store.Append(Image(), PinArchiveSource.Clipboard)!;
        Assert.True(store.SaveSession(new PinSessionRecord { ArchiveId = active.Id }));
        Assert.Null(store.Append(Image(), PinArchiveSource.Screenshot));
        Assert.Equal(active.Id, Assert.Single(store.List()).Id);
    }

    [Fact]
    public void InvalidStateIsRejectedAndReplacementCannotRecreateDeletedImage()
    {
        var store = new PinArchiveStore(_directory);
        var item = store.Append(Image(), PinArchiveSource.Clipboard)!;
        Assert.False(store.SaveSession(new PinSessionRecord { ArchiveId = item.Id, Opacity = double.NaN }));
        Assert.True(store.ReplaceImage(Image(), item.Id));
        Assert.True(store.Delete(item.Id).IsSuccess);
        Assert.False(store.ReplaceImage(Image(), item.Id));
        Assert.True(store.Delete(item.Id).IsSuccess);
    }

    [Fact]
    public void CorruptIndexRecoveryKeepsSessionIdentity()
    {
        var store = new PinArchiveStore(_directory);
        var item = store.Append(Image(), PinArchiveSource.Clipboard)!;
        Assert.True(store.SaveSession(new PinSessionRecord { ArchiveId = item.Id, Text = "recover me" }));
        File.WriteAllText(Path.Combine(_directory, "index.json"), "damaged index");
        Assert.Equal(item.Id, Assert.Single(store.List()).Id);
        Assert.Equal("recover me", Assert.Single(store.LoadSessions()).Text);
    }

    [Fact]
    public void CorruptSessionMetadataIsNotOverwritten()
    {
        var store = new PinArchiveStore(_directory);
        var item = store.Append(Image(), PinArchiveSource.Clipboard)!;
        string path = Path.Combine(_directory, "sessions.json");
        File.WriteAllText(path, "damaged metadata");
        Assert.False(store.SaveSession(new PinSessionRecord { ArchiveId = item.Id }));
        Assert.Equal("damaged metadata", File.ReadAllText(path));
    }
}
