using System;
using System.IO;
using System.Threading.Tasks;
using Polyglance.Platform.Translation;
using Xunit;

namespace Polyglance.Platform.Tests;

public class OfflineTranslationTests
{
    [Fact]
    public void OfflineModelManager_HasPredefinedModels()
    {
        var manager = OfflineModelManager.Instance;
        Assert.NotNull(manager.Models);
        Assert.True(manager.Models.Count >= 4);

        var enzh = manager.ResolveModel("en", "zh-CN");
        Assert.NotNull(enzh);
        Assert.Equal("enzh", enzh.Id);

        var zhen = manager.ResolveModel("zh", "en");
        Assert.NotNull(zhen);
        Assert.Equal("zhen", zhen.Id);
    }

    [Theory]
    [InlineData("zh-CN", "zh-CN")]
    [InlineData("zh-Hans", "zh-CN")]
    [InlineData("en-US", "en")]
    [InlineData("ja", "ja")]
    [InlineData("ko", "ko")]
    public void NormalizeLanguage_NormalizesCorrectly(string input, string expected)
    {
        string norm = OfflineModelManager.NormalizeLanguage(input);
        Assert.Equal(expected, norm);
    }

    [Fact]
    public async Task OfflineTranslationEngine_ThrowsWhenModelNotInstalled()
    {
        using var engine = new OfflineTranslationEngine();
        var ex = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            engine.TranslateAsync("こんにちは", "zh-CN", "ja"));

        Assert.Contains("尚未下载", ex.Message);
    }

    [Fact]
    public async Task OfflineTranslationEngine_ReturnsEmptyWhenInputEmpty()
    {
        using var engine = new OfflineTranslationEngine();
        var result = await engine.TranslateAsync("   ", "zh-CN", "en");
        Assert.Equal(string.Empty, result.Text);
        Assert.Equal("offline", result.Provider);
    }

    [Fact]
    public async Task OfflineTranslationEngine_TranslatesSuccessfullyWhenInstalled()
    {
        using var engine = new OfflineTranslationEngine();
        if (engine.IsModelAvailable("en", "zh-CN"))
        {
            var result = await engine.TranslateAsync("Hello", "zh-CN", "en");
            Assert.NotEmpty(result.Text);
            Assert.Equal("offline", result.Provider);
        }
    }

    [Fact]
    public void CustomModelDirectory_OverridesRootPath()
    {
        string tempDir = Path.Combine(Path.GetTempPath(), $"PolyglanceModelsTest_{Guid.NewGuid():N}");
        try
        {
            OfflineModelManager.CustomModelDirectory = tempDir;
            Assert.Equal(tempDir, OfflineModelManager.EffectiveModelDirectory);
            Assert.Equal(Path.Combine(tempDir, "translation"), OfflineModelManager.GetModelRootDirectory());
        }
        finally
        {
            OfflineModelManager.CustomModelDirectory = string.Empty;
            if (Directory.Exists(tempDir))
            {
                try { Directory.Delete(tempDir, true); } catch { }
            }
        }
    }
}
