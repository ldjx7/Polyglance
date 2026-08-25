using Polyglance.Core.Services;

namespace Polyglance.Core.Tests;

public sealed class AppVersionDisplayTests
{
    [Theory]
    [InlineData("0.0.4-beta.4", "v0.0.4-beta.4")]
    [InlineData("v0.0.4-beta.4", "v0.0.4-beta.4")]
    [InlineData("0.0.4-beta.4+30bf6a517581515aa00770180ce71f580c08f3fa", "v0.0.4-beta.4")]
    [InlineData("Polyglance v0.0.4-beta.4+30bf6a5", "v0.0.4-beta.4")]
    public void FormatKeepsOnlyTheUserFacingSemanticVersion(string rawVersion, string expected)
    {
        Assert.Equal(expected, AppVersionDisplay.Format(rawVersion, "0.0.4"));
    }

    [Fact]
    public void FormatFallsBackToTheAssemblyVersionWhenInformationalVersionIsBlank()
    {
        Assert.Equal("v0.0.4", AppVersionDisplay.Format("  ", "0.0.4"));
    }
}
