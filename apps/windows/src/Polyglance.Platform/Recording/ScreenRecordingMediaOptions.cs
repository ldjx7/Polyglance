namespace Polyglance.Platform.Recording;

public enum ScreenRecordingContainer
{
    Mp4,
    Gif,
}

public static class ScreenRecordingContainerParser
{
    public static ScreenRecordingContainer Parse(string? value) =>
        value?.Trim().ToUpperInvariant() switch
        {
            "MP4" => ScreenRecordingContainer.Mp4,
            "GIF" => ScreenRecordingContainer.Gif,
            _ => throw new NotSupportedException($"不支持的录屏格式：{value ?? "(空)"}"),
        };
}

public sealed record ScreenRecordingMediaOptions(
    ScreenRecordingContainer Container,
    bool CapturesSystemAudio,
    bool CapturesMicrophone,
    bool ShowsCursor)
{
    public bool SupportsAudio => Container == ScreenRecordingContainer.Mp4;

    public ScreenRecordingMediaOptions WithoutMicrophone() =>
        this with { CapturesMicrophone = false };

    public static ScreenRecordingMediaOptions Create(
        ScreenRecordingContainer container,
        bool capturesSystemAudio,
        bool capturesMicrophone,
        bool showsCursor)
    {
        var supportsAudio = container == ScreenRecordingContainer.Mp4;
        return new ScreenRecordingMediaOptions(
            container,
            supportsAudio && capturesSystemAudio,
            supportsAudio && capturesMicrophone,
            showsCursor);
    }
}
