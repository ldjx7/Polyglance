using Polyglance.Core.Models;
using Xunit;

namespace Polyglance.Core.Tests;

public sealed class StitchConfigurationTests
{
    [Fact]
    public void DefaultMatchThresholdUsesNormalizedPixelErrorScale()
    {
        Assert.Equal(0.035, StitchConfiguration.Default.MatchThreshold, precision: 6);
    }
}
