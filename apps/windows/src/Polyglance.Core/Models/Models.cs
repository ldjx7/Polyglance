using System.Text.Json.Serialization;

namespace Polyglance.Core.Models;

public enum TranslationProvider
{
    Google,
    Microsoft,
    FreeAI,
    OpenAICompatible,
    DeepLX
}

public sealed class AppConfiguration
{
    [JsonPropertyName("provider")]
    public string Provider { get; set; } = "microsoft";

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

    [JsonPropertyName("ai_streaming_enabled")]
    public bool AiStreamingEnabled { get; set; } = true;

    [JsonPropertyName("hotkey_screenshot_pin")]
    public string HotkeyScreenshotPin { get; set; } = "Alt+A";

    [JsonPropertyName("hotkey_screen_translate")]
    public string HotkeyScreenTranslate { get; set; } = "Alt+W";

    [JsonPropertyName("hotkey_main_translator")]
    public string HotkeyMainTranslator { get; set; } = "Alt+T";

    [JsonPropertyName("hotkey_selected_text")]
    public string HotkeySelectedText { get; set; } = "Alt+D";

    [JsonPropertyName("hotkey_long_screenshot")]
    public string HotkeyLongScreenshot { get; set; } = "Alt+S";

    [JsonPropertyName("auto_check_updates")]
    public bool AutoCheckUpdates { get; set; } = true;

    [JsonPropertyName("appcast_url")]
    public string AppcastUrl { get; set; } = "https://github.com/ldjx7/Polyglance/releases/latest/download/appcast-windows.xml";
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
        MatchThreshold = 0.88
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
