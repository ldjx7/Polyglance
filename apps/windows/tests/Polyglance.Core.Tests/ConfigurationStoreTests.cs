using System.Text.Json;
using Polyglance.Core.Models;
using Polyglance.Core.Services;

namespace Polyglance.Core.Tests;

public sealed class ConfigurationStoreTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"Polyglance.Tests.{Guid.NewGuid():N}");

    [Fact]
    public void SaveKeepsTheApiKeyOutOfTheJsonFile()
    {
        var credentials = new InMemoryCredentialStore();
        var store = CreateStore(credentials);

        store.Save(new AppConfiguration { Provider = "openai-compatible", ApiKey = "private-key" });

        string json = File.ReadAllText(Path.Combine(_directory, "config.json"));
        Assert.DoesNotContain("private-key", json, StringComparison.Ordinal);
        Assert.False(JsonDocument.Parse(json).RootElement.TryGetProperty("api_key", out _));
        Assert.Equal("private-key", credentials.Value);
    }

    [Fact]
    public void LoadReadsTheApiKeyFromTheCredentialStore()
    {
        var credentials = new InMemoryCredentialStore { Value = "protected-key" };
        var store = CreateStore(credentials);
        Directory.CreateDirectory(_directory);
        File.WriteAllText(Path.Combine(_directory, "config.json"), "{\"provider\":\"google\"}");

        AppConfiguration configuration = store.Load();

        Assert.Equal("google", configuration.Provider);
        Assert.Equal("protected-key", configuration.ApiKey);
    }

    [Fact]
    public void LoadMigratesTheObsoleteWindowsUpdateFeed()
    {
        var store = CreateStore(new InMemoryCredentialStore());
        Directory.CreateDirectory(_directory);
        File.WriteAllText(
            Path.Combine(_directory, "config.json"),
            "{\"appcast_url\":\"https://raw.githubusercontent.com/ldjx7/Polyglance/main/appcast-windows.xml\"}");

        AppConfiguration configuration = store.Load();

        Assert.Equal(
            "https://github.com/ldjx7/Polyglance/releases/latest/download/appcast-windows.xml",
            configuration.AppcastUrl);
    }

    [Fact]
    public void LoadMigratesAndRemovesALegacyPlaintextApiKey()
    {
        var credentials = new InMemoryCredentialStore();
        var store = CreateStore(credentials);
        Directory.CreateDirectory(_directory);
        File.WriteAllText(
            Path.Combine(_directory, "config.json"),
            "{\"provider\":\"openai-compatible\",\"api_key\":\"legacy-key\"}");

        AppConfiguration configuration = store.Load();

        Assert.Equal("legacy-key", configuration.ApiKey);
        Assert.Equal("legacy-key", credentials.Value);
        Assert.DoesNotContain("legacy-key", File.ReadAllText(Path.Combine(_directory, "config.json")));
    }

    [Fact]
    public void SaveAndLoadPreservesEveryUserFacingJsonSetting()
    {
        var credentials = new InMemoryCredentialStore();
        var store = CreateStore(credentials);
        var expected = new AppConfiguration
        {
            Provider = "free-ai",
            Endpoint = "https://example.test/translate",
            ApiKey = "protected-key",
            Model = "model-name",
            SourceLanguage = "en",
            TargetLanguage = "ja",
            AiStreamingEnabled = false,
            HotkeyScreenshotPin = "Ctrl+F1",
            HotkeyPinClipboardImage = "Ctrl+F2",
            HotkeyScreenTranslate = "Ctrl+F3",
            HotkeyMainTranslator = "Ctrl+F4",
            HotkeySelectedText = "Ctrl+F5",
            HotkeyLongScreenshot = "Ctrl+F6",
            HotkeyScreenRecording = "Ctrl+F7",
            HotkeyRestoreMostRecentPin = "Ctrl+F8",
            AutoCheckUpdates = false,
            AppcastUrl = "https://example.test/appcast.xml",
            DefaultRecordingFormat = "GIF",
            DefaultRecordingFps = 15,
            DefaultRecordingDelaySeconds = 5,
        };

        store.Save(expected);
        AppConfiguration actual = store.Load();

        Assert.Equivalent(expected, actual, strict: true);
    }

    [Fact]
    public void NewConfigurationUsesTheLowConflictCrossPlatformShortcutDefaults()
    {
        var configuration = new AppConfiguration();

        Assert.Equal("Ctrl+Shift+D1", configuration.HotkeyScreenshotPin);
        Assert.Equal("Ctrl+Shift+D2", configuration.HotkeyPinClipboardImage);
        Assert.Equal("Ctrl+Shift+D3", configuration.HotkeySelectedText);
        Assert.Equal("Ctrl+Shift+D4", configuration.HotkeyScreenTranslate);
        Assert.Equal(string.Empty, configuration.HotkeyLongScreenshot);
        Assert.Equal(string.Empty, configuration.HotkeyScreenRecording);
        Assert.Equal(string.Empty, configuration.HotkeyRestoreMostRecentPin);
        Assert.Equal(string.Empty, configuration.HotkeyMainTranslator);
    }

    [Fact]
    public void LoadMigratesTheCompleteLegacyDefaultShortcutSet()
    {
        var store = CreateStore(new InMemoryCredentialStore());
        Directory.CreateDirectory(_directory);
        File.WriteAllText(
            Path.Combine(_directory, "config.json"),
            """
            {
              "hotkey_screenshot_pin":"Alt+A",
              "hotkey_screen_translate":"Alt+W",
              "hotkey_main_translator":"Alt+T",
              "hotkey_selected_text":"Alt+D",
              "hotkey_long_screenshot":"Alt+S"
            }
            """);

        AppConfiguration configuration = store.Load();

        Assert.Equal("Ctrl+Shift+D1", configuration.HotkeyScreenshotPin);
        Assert.Equal("Ctrl+Shift+D2", configuration.HotkeyPinClipboardImage);
        Assert.Equal("Ctrl+Shift+D3", configuration.HotkeySelectedText);
        Assert.Equal("Ctrl+Shift+D4", configuration.HotkeyScreenTranslate);
        Assert.Equal(string.Empty, configuration.HotkeyLongScreenshot);
        Assert.Equal(string.Empty, configuration.HotkeyMainTranslator);
    }

    [Fact]
    public void LoadDoesNotOverwriteAUserCustomizedLegacyShortcutSet()
    {
        var store = CreateStore(new InMemoryCredentialStore());
        Directory.CreateDirectory(_directory);
        File.WriteAllText(
            Path.Combine(_directory, "config.json"),
            """
            {
              "hotkey_screenshot_pin":"Ctrl+F8",
              "hotkey_screen_translate":"Alt+W",
              "hotkey_main_translator":"Alt+T",
              "hotkey_selected_text":"Alt+D",
              "hotkey_long_screenshot":"Alt+S"
            }
            """);

        AppConfiguration configuration = store.Load();

        Assert.Equal("Ctrl+F8", configuration.HotkeyScreenshotPin);
        Assert.Equal("Alt+W", configuration.HotkeyScreenTranslate);
        Assert.Equal("Alt+D", configuration.HotkeySelectedText);
        Assert.Equal(string.Empty, configuration.HotkeyPinClipboardImage);
        Assert.Equal(string.Empty, configuration.HotkeyScreenRecording);
        Assert.Equal(string.Empty, configuration.HotkeyRestoreMostRecentPin);
    }

    [Fact]
    public void SaveSurfacesCredentialFailures()
    {
        var store = CreateStore(new ThrowingCredentialStore());

        ConfigurationStoreException error = Assert.Throws<ConfigurationStoreException>(() =>
            store.Save(new AppConfiguration { ApiKey = "key" }));

        Assert.Contains("凭据", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void DpapiCredentialStoreRoundTripsForTheCurrentWindowsUser()
    {
        if (!OperatingSystem.IsWindows())
            return;

        string path = Path.Combine(_directory, "credentials.dat");
        var store = new DpapiCredentialStore(path);

        store.Save("dpapi-secret");
        Assert.Equal("dpapi-secret", store.Load());
        store.Delete();
        Assert.Null(store.Load());
    }

    private ConfigurationStore CreateStore(ICredentialStore credentials) =>
        new(Path.Combine(_directory, "config.json"), credentials);

    public void Dispose()
    {
        if (Directory.Exists(_directory))
            Directory.Delete(_directory, recursive: true);
    }

    private sealed class InMemoryCredentialStore : ICredentialStore
    {
        public string? Value { get; set; }
        public string? Load() => Value;
        public void Save(string value) => Value = value;
        public void Delete() => Value = null;
    }

    private sealed class ThrowingCredentialStore : ICredentialStore
    {
        public string? Load() => throw new InvalidOperationException("read failed");
        public void Save(string value) => throw new InvalidOperationException("write failed");
        public void Delete() => throw new InvalidOperationException("delete failed");
    }
}
