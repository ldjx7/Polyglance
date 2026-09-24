using System.Diagnostics;

namespace Polyglance.UI.Views;

// MediaElement.Position may advance in coarse steps even while playback is
// continuous. Interpolate the playhead between position updates, then correct
// only a substantial difference from the media clock.
internal sealed class PlaybackProgressClock(Func<long>? timestamp = null)
{
    private readonly Func<long> _timestamp = timestamp ?? Stopwatch.GetTimestamp;
    private long _originTicks;
    private double _originSeconds;
    private double _lastMediaSeconds = -1;
    private bool _running;

    public double Position
    {
        get
        {
            if (!_running) return _originSeconds;
            return _originSeconds + (_timestamp() - _originTicks) / (double)Stopwatch.Frequency;
        }
    }

    public void Play(double mediaSeconds)
    {
        _originSeconds = Math.Max(0, mediaSeconds);
        _lastMediaSeconds = _originSeconds;
        _originTicks = _timestamp();
        _running = true;
    }

    public void Pause()
    {
        if (!_running) return;
        _originSeconds = Position;
        _running = false;
    }

    public void Seek(double mediaSeconds)
    {
        _originSeconds = Math.Max(0, mediaSeconds);
        _lastMediaSeconds = _originSeconds;
        _originTicks = _timestamp();
    }

    public void Observe(double mediaSeconds)
    {
        if (!_running || !double.IsFinite(mediaSeconds) || mediaSeconds < 0) return;
        // A stalled Position property is not evidence that playback stopped.
        if (mediaSeconds <= _lastMediaSeconds) return;
        _lastMediaSeconds = mediaSeconds;
        if (Math.Abs(mediaSeconds - Position) > 1.0)
        {
            _originSeconds = mediaSeconds;
            _originTicks = _timestamp();
        }
    }
}
