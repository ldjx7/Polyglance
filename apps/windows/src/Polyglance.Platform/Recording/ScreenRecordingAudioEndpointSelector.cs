namespace Polyglance.Platform.Recording;

public enum ScreenRecordingAudioEndpointRole
{
    Console,
    Multimedia,
    Communications,
}

public static class ScreenRecordingAudioEndpointSelector
{
    private static readonly ScreenRecordingAudioEndpointRole[] DefaultRoleOrder =
    [
        ScreenRecordingAudioEndpointRole.Console,
        ScreenRecordingAudioEndpointRole.Multimedia,
        ScreenRecordingAudioEndpointRole.Communications,
    ];

    public static T? Select<T>(
        Func<ScreenRecordingAudioEndpointRole, T?> tryGetDefault,
        Func<IReadOnlyList<T>> getActiveEndpoints)
        where T : class
    {
        foreach (var role in DefaultRoleOrder)
        {
            if (tryGetDefault(role) is { } endpoint)
            {
                return endpoint;
            }
        }
        return getActiveEndpoints().FirstOrDefault();
    }
}
