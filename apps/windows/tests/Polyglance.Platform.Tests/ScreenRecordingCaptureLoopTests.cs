using System.Collections.Concurrent;
using Polyglance.Platform.Recording;

namespace Polyglance.Platform.Tests;

public sealed class ScreenRecordingCaptureLoopTests
{
    [Theory]
    [InlineData(30)]
    [InlineData(60)]
    public void FrameClockUsesAbsoluteDeadlinesWithoutRoundingDrift(int fps)
    {
        Assert.Equal(TimeSpan.TicksPerSecond * 60, ScreenRecordingCaptureLoop.FrameTime(fps * 60, fps));
        Assert.Equal(fps * 60, ScreenRecordingCaptureLoop.FrameIndex(TimeSpan.TicksPerSecond * 60, fps));
        // 错过半秒后定位当前时刻，不把迟到的画面依次补进过去的帧。
        Assert.Equal(fps / 2, ScreenRecordingCaptureLoop.FrameIndex(TimeSpan.TicksPerSecond / 2, fps));
    }

    [Fact]
    public async Task CaptureContinuesWhileCallingThreadIsBlocked()
    {
        using var captured = new ManualResetEventSlim();
        var times = new ConcurrentQueue<long>();
        using var loop = new ScreenRecordingCaptureLoop(30, timestamp =>
        {
            times.Enqueue(timestamp);
            if (times.Count >= 8) captured.Set();
        });
        // 等待期间不运行调用方的 Dispatcher 或同步上下文。
        Assert.True(captured.Wait(TimeSpan.FromSeconds(3)));
        await loop.StopAsync();
        Assert.True(times.Count >= 8);
        Assert.Equal(0, times.First());
        Assert.True(times.Zip(times.Skip(1)).All(pair => pair.First < pair.Second));
    }

    [Fact]
    public async Task PauseFreezesTimelineAndStopPreventsFurtherCapture()
    {
        using var ready = new ManualResetEventSlim();
        int count = 0;
        using var loop = new ScreenRecordingCaptureLoop(30, _ => { Interlocked.Increment(ref count); ready.Set(); });
        Assert.True(ready.Wait(TimeSpan.FromSeconds(3)));
        loop.SetPaused(true);
        await Task.Delay(80); // 允许暂停前已经开始的单帧完成。
        int pausedCount = Volatile.Read(ref count);
        var pausedDuration = loop.Duration;
        await Task.Delay(100);
        Assert.Equal(pausedCount, Volatile.Read(ref count));
        Assert.Equal(pausedDuration, loop.Duration);
        ready.Reset();
        loop.SetPaused(false);
        Assert.True(ready.Wait(TimeSpan.FromSeconds(3)));
        await loop.StopAsync();
        int stoppedCount = Volatile.Read(ref count);
        await Task.Delay(80);
        Assert.Equal(stoppedCount, Volatile.Read(ref count));
    }
}
