namespace Polyglance.Platform.Recording;

public enum ScreenRecordingAudioDeviceKind
{
    SystemAudio,
    Microphone,
}

public sealed class ScreenRecordingAudioDeviceUnavailableException : InvalidOperationException
{
    public ScreenRecordingAudioDeviceKind DeviceKind { get; }

    public ScreenRecordingAudioDeviceUnavailableException(
        ScreenRecordingAudioDeviceKind deviceKind,
        string message,
        Exception? innerException = null)
        : base(message, innerException)
    {
        DeviceKind = deviceKind;
    }
}
