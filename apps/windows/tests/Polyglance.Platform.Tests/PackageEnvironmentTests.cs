using Polyglance.Platform.Packaging;
using Xunit;

namespace Polyglance.Platform.Tests;

[Collection("PackageEnvironment")]
public sealed class PackageEnvironmentTests
{
    [Fact]
    public void ClassifyPackageIdentityResult_ReturnsTrueForSuccessAndInsufficientBuffer()
    {
        Assert.True(PackageEnvironment.ClassifyPackageIdentityResult(PackageEnvironment.ErrorSuccess));
        Assert.True(PackageEnvironment.ClassifyPackageIdentityResult(PackageEnvironment.ErrorInsufficientBuffer));
    }

    [Fact]
    public void ClassifyPackageIdentityResult_ReturnsFalseForNoPackage()
    {
        Assert.False(PackageEnvironment.ClassifyPackageIdentityResult(PackageEnvironment.AppModelErrorNoPackage));
    }

    [Theory]
    [InlineData(1)]
    [InlineData(13)]
    [InlineData(87)]
    [InlineData(-1)]
    public void ClassifyPackageIdentityResult_ReturnsFalseForUnknownOrErrorCodes(int errorCode)
    {
        Assert.False(PackageEnvironment.ClassifyPackageIdentityResult(errorCode));
    }

    [Fact]
    public void DistributionChannel_MapsCorrectlyAccordingToIsPackaged()
    {
        try
        {
            PackageEnvironment.SetPackagedOverrideForTesting(false);
            Assert.False(PackageEnvironment.IsPackaged);
            Assert.Equal(DistributionChannel.GitHub, PackageEnvironment.DistributionChannel);

            PackageEnvironment.SetPackagedOverrideForTesting(true);
            Assert.True(PackageEnvironment.IsPackaged);
            Assert.Equal(DistributionChannel.MicrosoftStore, PackageEnvironment.DistributionChannel);
        }
        finally
        {
            PackageEnvironment.SetPackagedOverrideForTesting(null);
        }
    }
}
