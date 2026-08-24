using NAudio.CoreAudioApi;
using NAudio.Wave;
using System.IO;
using System.Runtime.InteropServices;

namespace Polyglance.Platform.Recording;

internal sealed class ScreenRecordingAudioCapture : IAsyncDisposable
{
    private readonly List<WaveCaptureSink> _sinks = new();
    private bool _started;

    public IReadOnlyList<string> OutputFiles => _sinks
        .Select(sink => sink.OutputPath)
        .Where(path => File.Exists(path) && new FileInfo(path).Length > 44)
        .ToArray();

    public static ScreenRecordingAudioCapture Create(
        string directory,
        ScreenRecordingMediaOptions options)
    {
        var capture = new ScreenRecordingAudioCapture();
        try
        {
            if (options.CapturesSystemAudio)
            {
                capture._sinks.Add(CreateSystemAudioSink(directory));
            }
            if (options.CapturesMicrophone)
            {
                capture._sinks.Add(CreateMicrophoneSink(directory));
            }
            return capture;
        }
        catch
        {
            foreach (var sink in capture._sinks)
            {
                sink.Cancel();
            }
            throw;
        }
    }

    private static WaveCaptureSink CreateSystemAudioSink(string directory)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var endpoint = ResolveEndpoint(enumerator, DataFlow.Render)
                ?? throw new ScreenRecordingAudioDeviceUnavailableException(
                    ScreenRecordingAudioDeviceKind.SystemAudio,
                    "未检测到可录制系统声音的输出设备");
            return new WaveCaptureSink(
                ScreenRecordingAudioDeviceKind.SystemAudio,
                new WasapiLoopbackCapture(endpoint),
                Path.Combine(directory, "system-audio.wav"));
        }
        catch (Exception error) when (error is COMException or ArgumentException)
        {
            throw new ScreenRecordingAudioDeviceUnavailableException(
                ScreenRecordingAudioDeviceKind.SystemAudio,
                "无法打开系统声音设备，请确认 Windows 中存在可用的播放设备",
                error);
        }
    }

    private static WaveCaptureSink CreateMicrophoneSink(string directory)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var endpoint = ResolveEndpoint(enumerator, DataFlow.Capture)
                ?? throw new ScreenRecordingAudioDeviceUnavailableException(
                    ScreenRecordingAudioDeviceKind.Microphone,
                    "未检测到可用麦克风，请确认麦克风或远程音频输入已启用");
            return new WaveCaptureSink(
                ScreenRecordingAudioDeviceKind.Microphone,
                new WasapiCapture(endpoint),
                Path.Combine(directory, "microphone.wav"));
        }
        catch (Exception error) when (error is COMException or ArgumentException)
        {
            throw new ScreenRecordingAudioDeviceUnavailableException(
                ScreenRecordingAudioDeviceKind.Microphone,
                "无法打开麦克风，请确认 Windows 麦克风权限和默认输入设备设置",
                error);
        }
    }

    private static MMDevice? ResolveEndpoint(MMDeviceEnumerator enumerator, DataFlow dataFlow) =>
        ScreenRecordingAudioEndpointSelector.Select(
            role => TryGetDefaultEndpoint(enumerator, dataFlow, role),
            () => enumerator
                .EnumerateAudioEndPoints(dataFlow, DeviceState.Active)
                .ToArray());

    private static MMDevice? TryGetDefaultEndpoint(
        MMDeviceEnumerator enumerator,
        DataFlow dataFlow,
        ScreenRecordingAudioEndpointRole role)
    {
        try
        {
            return enumerator.GetDefaultAudioEndpoint(dataFlow, role switch
            {
                ScreenRecordingAudioEndpointRole.Console => Role.Console,
                ScreenRecordingAudioEndpointRole.Multimedia => Role.Multimedia,
                ScreenRecordingAudioEndpointRole.Communications => Role.Communications,
                _ => Role.Console,
            });
        }
        catch (COMException)
        {
            return null;
        }
    }

    public void Start()
    {
        if (_started) return;
        try
        {
            foreach (var sink in _sinks)
            {
                sink.Start();
            }
            _started = true;
        }
        catch
        {
            foreach (var sink in _sinks)
            {
                sink.Cancel();
            }
            throw;
        }
    }

    public void SetPaused(bool paused)
    {
        foreach (var sink in _sinks)
        {
            sink.IsPaused = paused;
        }
    }

    public async Task StopAsync()
    {
        if (!_started) return;
        await Task.WhenAll(_sinks.Select(sink => sink.StopAsync()));
        _started = false;
    }

    public async ValueTask DisposeAsync()
    {
        if (_started)
        {
            await StopAsync();
        }
        foreach (var sink in _sinks)
        {
            sink.Dispose();
        }
    }

    private sealed class WaveCaptureSink : IDisposable
    {
        private readonly ScreenRecordingAudioDeviceKind _deviceKind;
        private readonly IWaveIn _capture;
        private readonly WaveFileWriter _writer;
        private readonly TaskCompletionSource _stopped = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        private bool _started;
        private bool _disposed;

        public string OutputPath { get; }
        public bool IsPaused { get; set; }

        public WaveCaptureSink(
            ScreenRecordingAudioDeviceKind deviceKind,
            IWaveIn capture,
            string outputPath)
        {
            _deviceKind = deviceKind;
            _capture = capture;
            OutputPath = outputPath;
            _writer = new WaveFileWriter(outputPath, capture.WaveFormat);
            _capture.DataAvailable += OnDataAvailable;
            _capture.RecordingStopped += OnRecordingStopped;
        }

        public void Start()
        {
            try
            {
                _capture.StartRecording();
                _started = true;
            }
            catch (Exception error)
            {
                var message = _deviceKind == ScreenRecordingAudioDeviceKind.Microphone
                    ? "无法启动麦克风录制，请确认麦克风或远程音频输入可用"
                    : "无法启动系统声音录制，请确认 Windows 播放设备可用";
                throw new ScreenRecordingAudioDeviceUnavailableException(
                    _deviceKind,
                    message,
                    error);
            }
        }

        public async Task StopAsync()
        {
            if (!_started)
            {
                Dispose();
                return;
            }
            _capture.StopRecording();
            await _stopped.Task.WaitAsync(TimeSpan.FromSeconds(5));
            _started = false;
        }

        public void Cancel()
        {
            try
            {
                if (_started) _capture.StopRecording();
            }
            catch
            {
                // Best-effort cleanup after a partially started capture device.
            }
            Dispose();
        }

        private void OnDataAvailable(object? sender, WaveInEventArgs eventArgs)
        {
            if (!IsPaused && eventArgs.BytesRecorded > 0)
            {
                _writer.Write(eventArgs.Buffer, 0, eventArgs.BytesRecorded);
            }
        }

        private void OnRecordingStopped(object? sender, StoppedEventArgs eventArgs)
        {
            try
            {
                _writer.Flush();
                _writer.Dispose();
                if (eventArgs.Exception is not null)
                {
                    _stopped.TrySetException(eventArgs.Exception);
                }
                else
                {
                    _stopped.TrySetResult();
                }
            }
            catch (Exception error)
            {
                _stopped.TrySetException(error);
            }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _capture.DataAvailable -= OnDataAvailable;
            _capture.RecordingStopped -= OnRecordingStopped;
            _capture.Dispose();
            _writer.Dispose();
        }
    }
}
