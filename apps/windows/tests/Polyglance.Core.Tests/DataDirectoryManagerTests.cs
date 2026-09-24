using System;
using System.IO;
using Polyglance.Core.Services;
using Xunit;

namespace Polyglance.Core.Tests;

public sealed class DataDirectoryManagerTests : IDisposable
{
    private readonly string _testRoot = Path.Combine(Path.GetTempPath(), $"DataDirTest_{Guid.NewGuid():N}");

    public DataDirectoryManagerTests()
    {
        DataDirectoryManager.ApplyRootDirectory(null);
    }

    public void Dispose()
    {
        DataDirectoryManager.ApplyRootDirectory(null);
        if (Directory.Exists(_testRoot))
        {
            try { Directory.Delete(_testRoot, true); } catch { }
        }
    }

    [Fact]
    public void DefaultDirectories_PointToAppDataPolyglance()
    {
        Assert.Null(DataDirectoryManager.CustomRootDirectory);
        string expectedRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Polyglance");
        Assert.Equal(expectedRoot, DataDirectoryManager.EffectiveRootDirectory);
        Assert.Equal(Path.Combine(expectedRoot, "models"), DataDirectoryManager.ModelsDirectory);
        Assert.Equal(Path.Combine(expectedRoot, "history"), DataDirectoryManager.HistoryDirectory);
        Assert.Equal(Path.Combine(expectedRoot, "history", "translation_history.json"), DataDirectoryManager.TranslationHistoryFilePath);
        Assert.Equal(Path.Combine(expectedRoot, "PinHistory"), DataDirectoryManager.PinHistoryDirectory);
        Assert.Equal(Path.Combine(expectedRoot, "Videos"), DataDirectoryManager.VideosDirectory);
    }

    [Fact]
    public void CustomRoot_OverridesSubdirectoryPaths_AndFiresEvent()
    {
        bool eventFired = false;
        DataDirectoryManager.RootDirectoryChanged += () => eventFired = true;

        DataDirectoryManager.ApplyRootDirectory(_testRoot);

        Assert.True(eventFired);
        Assert.Equal(_testRoot, DataDirectoryManager.CustomRootDirectory);
        Assert.Equal(_testRoot, DataDirectoryManager.EffectiveRootDirectory);
        Assert.Equal(Path.Combine(_testRoot, "models"), DataDirectoryManager.ModelsDirectory);
        Assert.Equal(Path.Combine(_testRoot, "history"), DataDirectoryManager.HistoryDirectory);
        Assert.Equal(Path.Combine(_testRoot, "history", "translation_history.json"), DataDirectoryManager.TranslationHistoryFilePath);
        Assert.Equal(Path.Combine(_testRoot, "PinHistory"), DataDirectoryManager.PinHistoryDirectory);
        Assert.Equal(Path.Combine(_testRoot, "Videos"), DataDirectoryManager.VideosDirectory);
    }

    [Fact]
    public void Migrate_CopiesDataToSubdirectories()
    {
        string sourceDir = Path.Combine(_testRoot, "source");
        string destDir = Path.Combine(_testRoot, "dest");

        Directory.CreateDirectory(Path.Combine(sourceDir, "history"));
        File.WriteAllText(Path.Combine(sourceDir, "history", "translation_history.json"), "{\"test\": true}");

        Directory.CreateDirectory(Path.Combine(sourceDir, "PinHistory"));
        File.WriteAllText(Path.Combine(sourceDir, "PinHistory", "pin_1.png"), "image-data");

        Directory.CreateDirectory(Path.Combine(sourceDir, "models", "translation", "enzh"));
        File.WriteAllText(Path.Combine(sourceDir, "models", "translation", "enzh", "model.onnx"), "onnx-data");

        Directory.CreateDirectory(Path.Combine(sourceDir, "Videos"));
        File.WriteAllText(Path.Combine(sourceDir, "Videos", "record_1.mp4"), "video-data");

        DataDirectoryManager.Migrate(sourceDir, destDir);

        Assert.True(File.Exists(Path.Combine(destDir, "history", "translation_history.json")));
        Assert.Equal("{\"test\": true}", File.ReadAllText(Path.Combine(destDir, "history", "translation_history.json")));

        Assert.True(File.Exists(Path.Combine(destDir, "PinHistory", "pin_1.png")));
        Assert.Equal("image-data", File.ReadAllText(Path.Combine(destDir, "PinHistory", "pin_1.png")));

        Assert.True(File.Exists(Path.Combine(destDir, "models", "translation", "enzh", "model.onnx")));
        Assert.Equal("onnx-data", File.ReadAllText(Path.Combine(destDir, "models", "translation", "enzh", "model.onnx")));

        Assert.True(File.Exists(Path.Combine(destDir, "Videos", "record_1.mp4")));
        Assert.Equal("video-data", File.ReadAllText(Path.Combine(destDir, "Videos", "record_1.mp4")));
    }
}
