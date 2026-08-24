using Polyglance.Platform.Recording;

namespace Polyglance.Platform.Tests;

public sealed class ScreenRecordingAudioEndpointSelectorTests
{
    [Fact]
    public void FallsBackAcrossDefaultRolesBeforeEnumeratingActiveEndpoints()
    {
        var requestedRoles = new List<ScreenRecordingAudioEndpointRole>();
        var selected = ScreenRecordingAudioEndpointSelector.Select(
            role =>
            {
                requestedRoles.Add(role);
                return role == ScreenRecordingAudioEndpointRole.Communications
                    ? "communications-microphone"
                    : null;
            },
            () => ["enumerated-microphone"]);

        Assert.Equal("communications-microphone", selected);
        Assert.Equal(
            [
                ScreenRecordingAudioEndpointRole.Console,
                ScreenRecordingAudioEndpointRole.Multimedia,
                ScreenRecordingAudioEndpointRole.Communications,
            ],
            requestedRoles);
    }

    [Fact]
    public void UsesFirstActiveEndpointWhenNoRoleHasADefault()
    {
        var selected = ScreenRecordingAudioEndpointSelector.Select<string>(
            _ => null,
            () => ["first-active", "second-active"]);

        Assert.Equal("first-active", selected);
    }

    [Fact]
    public void ReturnsNullWhenNoRecordingEndpointExists()
    {
        var selected = ScreenRecordingAudioEndpointSelector.Select<string>(
            _ => null,
            () => []);

        Assert.Null(selected);
    }
}
