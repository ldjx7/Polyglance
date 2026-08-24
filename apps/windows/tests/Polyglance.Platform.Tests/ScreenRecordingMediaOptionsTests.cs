using Polyglance.Platform.Recording;

namespace Polyglance.Platform.Tests;

public sealed class ScreenRecordingMediaOptionsTests
{
    [Fact]
    public void Mp4KeepsSelectedAudioAndCursorOptions()
    {
        var options = ScreenRecordingMediaOptions.Create(
            ScreenRecordingContainer.Mp4,
            capturesSystemAudio: true,
            capturesMicrophone: true,
            showsCursor: false);

        Assert.True(options.CapturesSystemAudio);
        Assert.True(options.CapturesMicrophone);
        Assert.False(options.ShowsCursor);
        Assert.True(options.SupportsAudio);
    }

    [Fact]
    public void GifAlwaysDisablesAudioWithoutChangingCursorChoice()
    {
        var options = ScreenRecordingMediaOptions.Create(
            ScreenRecordingContainer.Gif,
            capturesSystemAudio: true,
            capturesMicrophone: true,
            showsCursor: true);

        Assert.False(options.CapturesSystemAudio);
        Assert.False(options.CapturesMicrophone);
        Assert.True(options.ShowsCursor);
        Assert.False(options.SupportsAudio);
    }

    [Fact]
    public void DisablingUnavailableMicrophonePreservesOtherRecordingOptions()
    {
        var options = ScreenRecordingMediaOptions.Create(
            ScreenRecordingContainer.Mp4,
            capturesSystemAudio: true,
            capturesMicrophone: true,
            showsCursor: true);

        var fallback = options.WithoutMicrophone();

        Assert.True(fallback.CapturesSystemAudio);
        Assert.False(fallback.CapturesMicrophone);
        Assert.True(fallback.ShowsCursor);
        Assert.Equal(ScreenRecordingContainer.Mp4, fallback.Container);
    }

    [Fact]
    public void AudioDeviceUnavailableErrorIdentifiesTheFailedDevice()
    {
        var inner = new InvalidOperationException("device missing");

        var error = new ScreenRecordingAudioDeviceUnavailableException(
            ScreenRecordingAudioDeviceKind.Microphone,
            "未检测到麦克风",
            inner);

        Assert.Equal(ScreenRecordingAudioDeviceKind.Microphone, error.DeviceKind);
        Assert.Same(inner, error.InnerException);
    }

    [Theory]
    [InlineData("MP4", ScreenRecordingContainer.Mp4)]
    [InlineData("mp4", ScreenRecordingContainer.Mp4)]
    [InlineData("GIF", ScreenRecordingContainer.Gif)]
    public void ParsesOnlySupportedToolbarFormats(string value, ScreenRecordingContainer expected)
    {
        Assert.Equal(expected, ScreenRecordingContainerParser.Parse(value));
    }

    [Fact]
    public void RejectsFormatsThatTheRecorderCannotActuallyProduce()
    {
        Assert.Throws<NotSupportedException>(() => ScreenRecordingContainerParser.Parse("WebM"));
    }
}
