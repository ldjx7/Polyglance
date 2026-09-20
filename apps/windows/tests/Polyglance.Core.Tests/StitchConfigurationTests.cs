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

    [Fact]
    public void DefaultDoesNotCapASessionByFrameCount()
    {
        Assert.True(StitchConfiguration.Default.MaximumFrameCount >= 10_000);
    }

    [Fact]
    public void DefaultOutputBudgetsMatchTheMacOSClient()
    {
        var config = StitchConfiguration.Default;
        Assert.Equal(32_768u, config.MaximumOutputWidth);
        Assert.Equal(32_768u, config.MaximumOutputHeight);
    }

    [Fact]
    public void DefaultWorkingMemoryScalesWithPhysicalMemory()
    {
        long physical = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes;
        ulong expected = (ulong)Math.Clamp(physical / 8, 384L * 1024 * 1024, 1536L * 1024 * 1024);
        var config = StitchConfiguration.Default;

        Assert.Equal(expected, config.MaximumWorkingBytes);
        Assert.Equal(expected / 4, config.MaximumPixelCount);
    }

    [Fact]
    public void DefaultCaptureIntervalIsUsableAsATimerPeriod()
    {
        Assert.Equal(TimeSpan.FromMilliseconds(33), TimeSpan.FromSeconds(StitchConfiguration.Default.CaptureInterval));
    }
}
