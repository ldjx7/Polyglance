using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media.Imaging;

namespace Polyglance.Platform.Recording;

public sealed class ScreenRecordingCaptureLoop : IDisposable
{
    private readonly object _state = new();
    private readonly AutoResetEvent _wake = new(false);
    private readonly Stopwatch _clock = new();
    private readonly int _fps;
    private readonly ScreenRecordingMp4Session? _session;
    private readonly Int32Rect _region;
    private readonly bool _showCursor;
    private readonly Action<long>? _testCapture;
    private bool _paused;
    private bool _stopping;
    private bool _disposed;
    private long _samples;
    private long _missedSlots;
    private double _captureMilliseconds;
    private double _encodeMilliseconds;
    private double _maxCaptureMilliseconds;
    public Task Completion { get; }
    public BitmapSource? PosterFrame { get; private set; }
    public TimeSpan Duration { get { lock (_state) return _clock.Elapsed; } }
    public object Statistics => new
    {
        RequestedFps = _fps, CapturedFrames = _samples, MissedFrameSlots = _missedSlots,
        DurationSeconds = Duration.TotalSeconds,
        CaptureMillisecondsPerFrame = _captureMilliseconds / Math.Max(1, _samples),
        EncodeMillisecondsPerFrame = _encodeMilliseconds / Math.Max(1, _samples),
        MaxCaptureMilliseconds = _maxCaptureMilliseconds,
    };

    public ScreenRecordingCaptureLoop(Int32Rect region, int fps, bool showCursor, ScreenRecordingMp4Session session)
    {
        _region = region;
        _fps = fps;
        _showCursor = showCursor;
        _session = session;
        Completion = Task.Factory.StartNew(Run, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
    }

    internal ScreenRecordingCaptureLoop(int fps, Action<long> capture)
    {
        _fps = fps;
        _testCapture = capture;
        Completion = Task.Factory.StartNew(Run, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
    }

    public void SetPaused(bool paused)
    {
        lock (_state)
        {
            if (_stopping || _paused == paused) return;
            _paused = paused;
            if (paused) _clock.Stop(); else _clock.Start();
            _session?.SetPaused(paused);
        }
        _wake.Set();
    }

    public async Task StopAsync()
    {
        lock (_state) { _stopping = true; _clock.Stop(); }
        _wake.Set();
        await Completion.ConfigureAwait(false);
    }

    private void Run()
    {
        bool timerPeriodSet = timeBeginPeriod(1) == 0;
        try
        {
            using var capture = _testCapture is null ? new ScreenRecordingFrameCapture(_region) : null;
            lock (_state) { if (_stopping) return; if (!_paused) _clock.Start(); }
            long nextFrame = 0;
            while (true)
            {
                long elapsed;
                bool paused;
                lock (_state)
                {
                    if (_stopping) break;
                    paused = _paused;
                    elapsed = _clock.Elapsed.Ticks;
                }
                if (paused) { _wake.WaitOne(); continue; }
                long due = FrameTime(nextFrame, _fps);
                if (elapsed < due)
                {
                    // 等待绝对截止时间，采集与编码的耗时不会累加到下一帧间隔。
                    _wake.WaitOne(Math.Max(1, (int)((due - elapsed) / TimeSpan.TicksPerMillisecond)));
                    continue;
                }
                long frame = Math.Max(nextFrame, FrameIndex(elapsed, _fps));
                _missedSlots += frame - nextFrame;
                long timestamp = _samples == 0 ? 0 : FrameTime(frame, _fps);
                if (_testCapture is not null) _testCapture(timestamp);
                else
                {
                    long start = Stopwatch.GetTimestamp();
                    capture!.Capture(_showCursor);
                    double captureMs = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
                    _captureMilliseconds += captureMs;
                    _maxCaptureMilliseconds = Math.Max(_maxCaptureMilliseconds, captureMs);
                    start = Stopwatch.GetTimestamp();
                    _session!.AppendPixels(capture.Pixels, capture.Length, timestamp);
                    _encodeMilliseconds += Stopwatch.GetElapsedTime(start).TotalMilliseconds;
                    if (_samples == 0) PosterFrame = capture.CreatePoster();
                }
                _samples++;
                nextFrame = frame + 1;
            }
        }
        finally
        {
            lock (_state) _clock.Stop();
            if (timerPeriodSet) timeEndPeriod(1);
        }
    }

    internal static long FrameIndex(long elapsedTicks, int fps) => elapsedTicks * fps / TimeSpan.TicksPerSecond;
    internal static long FrameTime(long index, int fps) => index * TimeSpan.TicksPerSecond / fps;

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try { StopAsync().GetAwaiter().GetResult(); }
        finally { _wake.Dispose(); }
    }

    [DllImport("winmm.dll")]
    private static extern uint timeBeginPeriod(uint period);
    [DllImport("winmm.dll")]
    private static extern uint timeEndPeriod(uint period);
}
