using System.Diagnostics;
using Polyglance.UI.Views;

namespace Polyglance.UI.Tests;

public sealed class PlaybackProgressClockTests
{
    [Fact]
    public void ProgressContinuesWhileMediaPositionIsTemporarilyUnchanged()
    {
        long now = 0;
        var clock = new PlaybackProgressClock(() => now);
        clock.Play(0);

        now += Stopwatch.Frequency / 4;
        clock.Observe(0);
        Assert.InRange(clock.Position, 0.24, 0.26);
        now += Stopwatch.Frequency / 4;
        clock.Observe(0);
        Assert.InRange(clock.Position, 0.49, 0.51);

        // The player position catches up after a coarse update; the visual
        // playhead should not jump backward or forward by half a second.
        clock.Observe(0.5);
        Assert.InRange(clock.Position, 0.49, 0.51);
    }

    [Fact]
    public void PauseSeekAndResumeUseTheSelectedPlaybackTime()
    {
        long now = 0;
        var clock = new PlaybackProgressClock(() => now);
        clock.Play(2);
        now += Stopwatch.Frequency;
        clock.Pause();
        now += Stopwatch.Frequency * 5;
        Assert.InRange(clock.Position, 2.99, 3.01);

        clock.Seek(8);
        Assert.Equal(8, clock.Position);
        clock.Play(8);
        now += Stopwatch.Frequency / 2;
        Assert.InRange(clock.Position, 8.49, 8.51);
    }

    [Fact]
    public void RealPlaybackDriftEventuallyResynchronizesThePlayhead()
    {
        long now = 0;
        var clock = new PlaybackProgressClock(() => now);
        clock.Play(0);
        now += Stopwatch.Frequency * 3;
        clock.Observe(1.5);
        Assert.InRange(clock.Position, 1.49, 1.51);
        now += Stopwatch.Frequency / 2;
        Assert.InRange(clock.Position, 1.99, 2.01);
    }
}
