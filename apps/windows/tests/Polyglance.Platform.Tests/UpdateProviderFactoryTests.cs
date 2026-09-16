using Polyglance.Platform.Packaging;
using Polyglance.Platform.Update;
using Xunit;

namespace Polyglance.Platform.Tests;

[Collection("PackageEnvironment")]
public sealed class UpdateProviderFactoryTests
{
    [Fact]
    public void Create_ReturnsGitHubUpdateProvider_WhenChannelIsGitHub()
    {
        var provider = UpdateProviderFactory.Create(
            "https://example.com/appcast.xml",
            channelOverride: DistributionChannel.GitHub);

        Assert.IsType<GitHubUpdateProvider>(provider);
        Assert.Equal(DistributionChannel.GitHub, provider.Channel);
        Assert.True(provider.SupportsBetaChannel);
        Assert.True(provider.SupportsSkippedVersions);
    }

    [Fact]
    public void Create_ReturnsMicrosoftStoreUpdateProvider_WhenChannelIsMicrosoftStore()
    {
        var provider = UpdateProviderFactory.Create(
            "https://example.com/appcast.xml",
            channelOverride: DistributionChannel.MicrosoftStore);

        Assert.IsType<MicrosoftStoreUpdateProvider>(provider);
        Assert.Equal(DistributionChannel.MicrosoftStore, provider.Channel);
        Assert.False(provider.SupportsBetaChannel);
        Assert.False(provider.SupportsSkippedVersions);
    }

    [Fact]
    public void Create_RespectsPackageEnvironmentDefaultChannel()
    {
        try
        {
            PackageEnvironment.SetPackagedOverrideForTesting(false);
            var unpackagedProvider = UpdateProviderFactory.Create("https://example.com/appcast.xml");
            Assert.IsType<GitHubUpdateProvider>(unpackagedProvider);

            PackageEnvironment.SetPackagedOverrideForTesting(true);
            var packagedProvider = UpdateProviderFactory.Create("https://example.com/appcast.xml");
            Assert.IsType<MicrosoftStoreUpdateProvider>(packagedProvider);
        }
        finally
        {
            PackageEnvironment.SetPackagedOverrideForTesting(null);
        }
    }
}
