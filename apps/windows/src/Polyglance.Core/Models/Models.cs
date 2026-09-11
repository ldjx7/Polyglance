using System.Text.Json.Serialization;

namespace Polyglance.Core.Models;

public enum ScreenshotCaptureIntent
{
    Standard,
    ScreenshotAndCopy,
    ScreenTranslation,
    LongScreenshot,
    ScreenRecording,
    OcrTranslate,
    OcrWorkspace,
    OcrTranslationCard
}

public enum ScreenshotSelectionAction
{
    None,
    Copy,
    ScreenTranslation,
    LongScreenshot,
    ScreenRecording,
    OcrTranslate,
    OcrWorkspace,
    OcrTranslationCard
}

public static class ScreenshotCaptureIntentExtensions
{
    public static ScreenshotSelectionAction ActionAfterSelection(this ScreenshotCaptureIntent intent) =>
        intent switch
        {
            ScreenshotCaptureIntent.ScreenshotAndCopy => ScreenshotSelectionAction.Copy,
            ScreenshotCaptureIntent.ScreenTranslation => ScreenshotSelectionAction.ScreenTranslation,
            ScreenshotCaptureIntent.LongScreenshot => ScreenshotSelectionAction.LongScreenshot,
            ScreenshotCaptureIntent.ScreenRecording => ScreenshotSelectionAction.ScreenRecording,
            ScreenshotCaptureIntent.OcrTranslate => ScreenshotSelectionAction.OcrTranslate,
            ScreenshotCaptureIntent.OcrWorkspace => ScreenshotSelectionAction.OcrWorkspace,
            ScreenshotCaptureIntent.OcrTranslationCard => ScreenshotSelectionAction.OcrTranslationCard,
            _ => ScreenshotSelectionAction.None
        };
}

public enum TranslationProvider
{
    FreeAI,
    Microsoft,
    Google,
    DeepL,
    Baidu,
    Youdao,
    Volcano,
    OpenAICompatible,
    DeepLX
}

public enum ProviderDisplayMode
{
    Normal,
    RememberFold,
    AlwaysFold,
    PinToBar,
    Closed
}

public static class ProviderDisplayModeExtensions
{
    public static string ToConfigString(this ProviderDisplayMode mode) => mode switch
    {
        ProviderDisplayMode.RememberFold => "remember",
        ProviderDisplayMode.AlwaysFold => "alwaysFold",
        ProviderDisplayMode.PinToBar => "pinToBar",
        ProviderDisplayMode.Closed => "closed",
        _ => "normal"
    };

    public static ProviderDisplayMode FromConfigString(string? raw) => raw switch
    {
        "remember" => ProviderDisplayMode.RememberFold,
        "alwaysFold" => ProviderDisplayMode.AlwaysFold,
        "pinToBar" => ProviderDisplayMode.PinToBar,
        "closed" => ProviderDisplayMode.Closed,
        _ => ProviderDisplayMode.Normal
    };

    public static string GetTitle(this ProviderDisplayMode mode) => mode switch
    {
        ProviderDisplayMode.Normal => "普通模式（每次都翻译）",
        ProviderDisplayMode.RememberFold => "记住折叠状态（折叠后不会自动翻译，点击展开触发翻译并消耗用量）",
        ProviderDisplayMode.AlwaysFold => "总是折叠（不会自动翻译，点击展开触发翻译并消耗用量）",
        ProviderDisplayMode.PinToBar => "隐藏并钉到语言切换栏（不会自动翻译，点击图标触发一次翻译并消耗用量）",
        ProviderDisplayMode.Closed => "彻底关闭",
        _ => "普通模式（每次都翻译）"
    };
}

public sealed class AppConfiguration
{
    [JsonPropertyName("provider")]
    public string Provider { get; set; } = "freeai";

    [JsonPropertyName("enabled_providers")]
    public List<string> EnabledProviders { get; set; } = new() { "freeai" };

    [JsonPropertyName("provider_display_modes")]
    public Dictionary<string, string> ProviderDisplayModes { get; set; } = new();

    [JsonPropertyName("provider_order")]
    public List<string> ProviderOrder { get; set; } = new()
    {
        "freeai",
        "microsoft",
        "google",
        "deepl",
        "baidu",
        "youdao",
        "volcano",
        "openaicompatible"
    };

    [JsonPropertyName("deepl_auth_key")]
    public string DeeplAuthKey { get; set; } = "";

    [JsonPropertyName("deepl_endpoint")]
    public string DeeplEndpoint { get; set; } = "";

    [JsonPropertyName("baidu_app_id")]
    public string BaiduAppId { get; set; } = "";

    [JsonPropertyName("baidu_secret_key")]
    public string BaiduSecretKey { get; set; } = "";

    [JsonPropertyName("youdao_app_key")]
    public string YoudaoAppKey { get; set; } = "";

    [JsonPropertyName("youdao_secret")]
    public string YoudaoSecret { get; set; } = "";

    [JsonPropertyName("volcano_access_key")]
    public string VolcanoAccessKey { get; set; } = "";

    [JsonPropertyName("volcano_secret_key")]
    public string VolcanoSecretKey { get; set; } = "";

    [JsonPropertyName("endpoint")]
    public string Endpoint { get; set; } = "";

    [JsonPropertyName("api_key")]
    public string ApiKey { get; set; } = "";

    [JsonPropertyName("model")]
    public string Model { get; set; } = "";

    [JsonPropertyName("source_language")]
    public string? SourceLanguage { get; set; }

    [JsonPropertyName("target_language")]
    public string TargetLanguage { get; set; } = "zh-Hans";

    [JsonPropertyName("second_target_language")]
    public string SecondTargetLanguage { get; set; } = "en";

    [JsonPropertyName("ai_streaming_enabled")]
    public bool AiStreamingEnabled { get; set; } = true;

    [JsonPropertyName("screenshot_translation_style")]
    public string ScreenshotTranslationStyle { get; set; } = "bob";

    [JsonPropertyName("hotkey_screenshot_copy")]
    public string HotkeyScreenshotCopy { get; set; } = GlobalShortcutDefaults.ScreenshotCopy;

    [JsonPropertyName("hotkey_screenshot_pin")]
    public string HotkeyScreenshotPin { get; set; } = GlobalShortcutDefaults.Screenshot;

    [JsonPropertyName("hotkey_pin_clipboard_image")]
    public string HotkeyPinClipboardImage { get; set; } = GlobalShortcutDefaults.PinClipboardImage;

    [JsonPropertyName("hotkey_screen_translate")]
    public string HotkeyScreenTranslate { get; set; } = GlobalShortcutDefaults.ScreenTranslate;

    [JsonPropertyName("hotkey_main_translator")]
    public string HotkeyMainTranslator { get; set; } = GlobalShortcutDefaults.MainTranslator;

    [JsonPropertyName("hotkey_selected_text")]
    public string HotkeySelectedText { get; set; } = GlobalShortcutDefaults.SelectedText;

    [JsonPropertyName("hotkey_long_screenshot")]
    public string HotkeyLongScreenshot { get; set; } = GlobalShortcutDefaults.LongScreenshot;

    [JsonPropertyName("hotkey_screen_recording")]
    public string HotkeyScreenRecording { get; set; } = GlobalShortcutDefaults.ScreenRecording;

    [JsonPropertyName("hotkey_restore_most_recent_pin")]
    public string HotkeyRestoreMostRecentPin { get; set; } = GlobalShortcutDefaults.RestoreMostRecentPin;

    [JsonPropertyName("hotkey_ocr_translate")]
    public string HotkeyOcrTranslate { get; set; } = GlobalShortcutDefaults.OcrTranslate;

    [JsonPropertyName("hotkey_ocr_workspace")]
    public string HotkeyOcrWorkspace { get; set; } = GlobalShortcutDefaults.OcrWorkspace;

    [JsonPropertyName("hotkey_ocr_translation_card")]
    public string HotkeyOcrTranslationCard { get; set; } = GlobalShortcutDefaults.OcrTranslationCard;

    [JsonPropertyName("hotkey_translate_and_replace")]
    public string HotkeyTranslateAndReplace { get; set; } = GlobalShortcutDefaults.TranslateAndReplace;

    [JsonPropertyName("save_completed_screenshots_to_history")]
    public bool SaveCompletedScreenshotsToHistory { get; set; } = false;

    [JsonPropertyName("auto_check_updates")]
    public bool AutoCheckUpdates { get; set; } = true;

    [JsonPropertyName("include_beta_updates")]
    public bool IncludeBetaUpdates { get; set; }

    [JsonPropertyName("skipped_update_version")]
    public string SkippedUpdateVersion { get; set; } = "";

    [JsonPropertyName("appcast_url")]
    public string AppcastUrl { get; set; } = "https://github.com/ldjx7/Polyglance/releases/latest/download/appcast-windows.xml";

    [JsonPropertyName("default_recording_format")]
    public string DefaultRecordingFormat { get; set; } = "MP4";

    [JsonPropertyName("default_recording_fps")]
    public int DefaultRecordingFps { get; set; } = 30;

    [JsonPropertyName("default_recording_delay_seconds")]
    public int DefaultRecordingDelaySeconds { get; set; }

    [JsonPropertyName("screenshot_toolbar_items")]
    public List<ScreenshotToolbarItemConfig> ScreenshotToolbarItems { get; set; } = ScreenshotToolbarItemConfig.DefaultItems();

    [JsonPropertyName("ocr_auto_copy_next_time")]
    public bool OcrAutoCopyNextTime { get; set; }

    [JsonPropertyName("ocr_default_formatting")]
    public int OcrDefaultFormatting { get; set; }

    [JsonPropertyName("custom_ai_configs")]
    public List<CustomAIServiceConfig> CustomAIConfigs { get; set; } = new();
}

public sealed class CustomAIServiceConfig
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = $"custom_{Guid.NewGuid():N}"[..15];

    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("endpoint")]
    public string Endpoint { get; set; } = "https://api.openai.com/v1";

    [JsonPropertyName("api_key")]
    public string ApiKey { get; set; } = "";

    [JsonPropertyName("model")]
    public string Model { get; set; } = "gpt-4o-mini";

    [JsonPropertyName("prompt")]
    public string Prompt { get; set; } = "";

    [JsonPropertyName("is_enabled")]
    public bool IsEnabled { get; set; } = true;
}

public sealed class ScreenshotToolbarItemConfig
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("is_visible")]
    public bool IsVisible { get; set; } = true;

    public ScreenshotToolbarItemConfig() { }

    public ScreenshotToolbarItemConfig(string id, bool isVisible = true)
    {
        Id = id;
        IsVisible = isVisible;
    }

    public static List<ScreenshotToolbarItemConfig> DefaultItems() => new()
    {
        new("pen"),
        new("line"),
        new("arrow"),
        new("ellipse"),
        new("rect"),
        new("text"),
        new("mosaic"),
        new("number"),
        new("undo"),
        new("redo"),
        new("longScreenshot"),
        new("screenRecording"),
        new("ocr"),
        new("translate"),
        new("barcode"),
        new("save"),
        new("cancel"),
        new("pin"),
        new("copy")
    };

    public static List<ScreenshotToolbarItemConfig> Normalize(List<ScreenshotToolbarItemConfig>? items)
    {
        var defaults = DefaultItems();
        if (items == null || items.Count == 0) return defaults;
        var result = new List<ScreenshotToolbarItemConfig>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in items)
        {
            if (defaults.Exists(d => string.Equals(d.Id, item.Id, StringComparison.OrdinalIgnoreCase)) && seen.Add(item.Id))
            {
                result.Add(new ScreenshotToolbarItemConfig(item.Id, item.IsVisible));
            }
        }
        foreach (var d in defaults)
        {
            if (seen.Add(d.Id))
            {
                result.Add(new ScreenshotToolbarItemConfig(d.Id, d.IsVisible));
            }
        }
        return result;
    }
}

public static class GlobalShortcutDefaults
{
    public const string Screenshot = "Ctrl+Shift+D1";
    public const string ScreenshotCopy = "";
    public const string PinClipboardImage = "Ctrl+Shift+D2";
    public const string SelectedText = "Ctrl+Shift+D3";
    public const string ScreenTranslate = "Ctrl+Shift+D4";
    public const string LongScreenshot = "";
    public const string ScreenRecording = "";
    public const string RestoreMostRecentPin = "Ctrl+Shift+D5";
    public const string MainTranslator = "";
    public const string OcrTranslate = "";
    public const string OcrWorkspace = "";
    public const string OcrTranslationCard = "";
    public const string TranslateAndReplace = "";

    public static bool IsCompleteLegacyDefaultSet(AppConfiguration configuration) =>
        configuration.HotkeyScreenshotPin == "Alt+A"
        && configuration.HotkeyScreenTranslate == "Alt+W"
        && configuration.HotkeyMainTranslator == "Alt+T"
        && configuration.HotkeySelectedText == "Alt+D"
        && configuration.HotkeyLongScreenshot == "Alt+S";

    public static void ApplyRecommendedDefaults(AppConfiguration configuration)
    {
        configuration.HotkeyScreenshotPin = Screenshot;
        configuration.HotkeyScreenshotCopy = ScreenshotCopy;
        configuration.HotkeyPinClipboardImage = PinClipboardImage;
        configuration.HotkeySelectedText = SelectedText;
        configuration.HotkeyScreenTranslate = ScreenTranslate;
        configuration.HotkeyLongScreenshot = LongScreenshot;
        configuration.HotkeyScreenRecording = ScreenRecording;
        configuration.HotkeyRestoreMostRecentPin = RestoreMostRecentPin;
        configuration.HotkeyMainTranslator = MainTranslator;
        configuration.HotkeyOcrTranslate = OcrTranslate;
        configuration.HotkeyOcrWorkspace = OcrWorkspace;
        configuration.HotkeyOcrTranslationCard = OcrTranslationCard;
        configuration.HotkeyTranslateAndReplace = TranslateAndReplace;
    }
}

public sealed class TranslationResult
{
    [JsonPropertyName("text")]
    public string Text { get; set; } = "";

    [JsonPropertyName("provider")]
    public string Provider { get; set; } = "";

    [JsonPropertyName("elapsed_ms")]
    public ulong ElapsedMs { get; set; }
}

public sealed class LayoutTextLine
{
    [JsonPropertyName("text")]
    public string Text { get; set; } = "";

    [JsonPropertyName("x")]
    public double X { get; set; }

    [JsonPropertyName("y")]
    public double Y { get; set; }

    [JsonPropertyName("width")]
    public double Width { get; set; }

    [JsonPropertyName("height")]
    public double Height { get; set; }

    [JsonPropertyName("words")]
    public List<LayoutTextWord> Words { get; set; } = [];
}

public sealed class LayoutTextWord
{
    [JsonPropertyName("text")]
    public string Text { get; set; } = "";

    [JsonPropertyName("x")]
    public double X { get; set; }

    [JsonPropertyName("y")]
    public double Y { get; set; }

    [JsonPropertyName("width")]
    public double Width { get; set; }

    [JsonPropertyName("height")]
    public double Height { get; set; }
}

public sealed class LayoutParagraph
{
    [JsonPropertyName("text")]
    public string Text { get; set; } = "";

    [JsonPropertyName("x")]
    public double X { get; set; }

    [JsonPropertyName("y")]
    public double Y { get; set; }

    [JsonPropertyName("width")]
    public double Width { get; set; }

    [JsonPropertyName("height")]
    public double Height { get; set; }

    [JsonPropertyName("line_count")]
    public uint LineCount { get; set; }
}

public sealed class SegmentPair
{
    [JsonPropertyName("id")]
    public uint Id { get; set; }

    [JsonPropertyName("source_text")]
    public string SourceText { get; set; } = "";

    [JsonPropertyName("target_text")]
    public string TargetText { get; set; } = "";

    [JsonPropertyName("source_location")]
    public uint SourceLocation { get; set; }

    [JsonPropertyName("source_length")]
    public uint SourceLength { get; set; }

    [JsonPropertyName("target_location")]
    public uint TargetLocation { get; set; }

    [JsonPropertyName("target_length")]
    public uint TargetLength { get; set; }
}

public struct StitchConfiguration
{
    public double CaptureInterval;
    public uint MaximumFrameCount;
    public uint MaximumOutputWidth;
    public uint MaximumOutputHeight;
    public ulong MaximumPixelCount;
    public ulong MaximumWorkingBytes;
    public uint MinimumOverlapRows;
    public double MaximumScrollFraction;
    public double MatchThreshold;

    public static StitchConfiguration Default => new()
    {
        CaptureInterval = 0.05,
        MaximumFrameCount = 60,
        MaximumOutputWidth = 4000,
        MaximumOutputHeight = 15000,
        MaximumPixelCount = 50_000_000,
        MaximumWorkingBytes = 250_000_000,
        MinimumOverlapRows = 12,
        MaximumScrollFraction = 0.85,
        MatchThreshold = 0.035
    };
}

public struct StitchAppendResult
{
    public int Disposition;
    public long Offset;
    public uint FrameCount;
    public uint TotalWidth;
    public uint TotalHeight;
    public int LimitReached;
}

public enum NativeSelectionEditTarget
{
    None = 0,
    Move = 1,
    TopLeft = 2,
    Top = 3,
    TopRight = 4,
    Right = 5,
    BottomRight = 6,
    Bottom = 7,
    BottomLeft = 8,
    Left = 9,
    Expand = 10
}

public readonly struct NativePoint
{
    public NativePoint(double x, double y)
    {
        X = x;
        Y = y;
    }

    public readonly double X;
    public readonly double Y;
}

public readonly struct NativeRect
{
    public NativeRect(double x, double y, double width, double height)
    {
        X = x;
        Y = y;
        Width = width;
        Height = height;
    }

    public readonly double X;
    public readonly double Y;
    public readonly double Width;
    public readonly double Height;
}
