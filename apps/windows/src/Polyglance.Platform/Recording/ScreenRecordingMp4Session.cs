using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32.SafeHandles;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using Polyglance.Core.Native;

namespace Polyglance.Platform.Recording;

public sealed class ScreenRecordingMp4Session : IAsyncDisposable
{
    private readonly string _temporaryDirectory;
    private readonly string _videoPath;
    private readonly int _width;
    private readonly int _height;
    private readonly int _frameRate;
    private readonly EncoderHandle _encoder;
    private readonly ScreenRecordingAudioCapture _audioCapture;
    private byte[]? _bitmapBuffer;
    private long _endTime;
    private bool _finished;
    public int FramesWritten { get; private set; }
    public int CapturedFrames { get; private set; }
    public TimeSpan Duration => TimeSpan.FromTicks(_endTime);

    public ScreenRecordingMp4Session(
        string temporaryDirectory, int width, int height, int frameRate,
        uint videoBitrate, ScreenRecordingMediaOptions options)
    {
        if (options.Container != ScreenRecordingContainer.Mp4)
            throw new ArgumentException("MP4 会话只能用于 MP4 格式", nameof(options));
        if (width < 2 || height < 2 || frameRate is < 1 or > 240)
            throw new ArgumentOutOfRangeException(nameof(width), "录屏尺寸和帧率无效");
        _temporaryDirectory = temporaryDirectory;
        _width = width & ~1;
        _height = height & ~1;
        _frameRate = frameRate;
        Directory.CreateDirectory(temporaryDirectory);
        _videoPath = Path.Combine(temporaryDirectory, "video.mp4");
        CheckStatus(NativeMethods.polyglance_windows_recording_encoder_new(
            _videoPath, (uint)_width, (uint)_height, (uint)frameRate, videoBitrate, out var handle));
        _encoder = new EncoderHandle(handle);
        try
        {
            _audioCapture = ScreenRecordingAudioCapture.Create(temporaryDirectory, options);
            _audioCapture.Start();
        }
        catch
        {
            _encoder.Dispose();
            CleanupTemporaryDirectory();
            throw;
        }
    }

    // 保留位图入口供测试和单帧调用；持续录屏直接读取复用的 DIB 像素缓冲区。
    public unsafe void AppendFrame(BitmapSource frame, int repeatCount = 1)
    {
        ObjectDisposedException.ThrowIf(_finished, this);
        if (frame.PixelWidth < _width || frame.PixelHeight < _height)
            throw new ArgumentException("录屏帧尺寸小于录制区域", nameof(frame));
        BitmapSource source = frame;
        if (source.Format != PixelFormats.Bgr32)
        {
            source = new FormatConvertedBitmap(source, PixelFormats.Bgr32, null, 0);
            source.Freeze();
        }
        _bitmapBuffer ??= new byte[checked(_width * _height * 4)];
        source.CopyPixels(new Int32Rect(0, 0, _width, _height), _bitmapBuffer, _width * 4, 0);
        int count = Math.Clamp(repeatCount, 1, _frameRate * 3);
        int nextFrame = FramesWritten + count;
        fixed (byte* pixels = _bitmapBuffer)
            AppendPixels((IntPtr)pixels, _bitmapBuffer.Length, _endTime);
        FramesWritten = nextFrame;
        _endTime = nextFrame * TimeSpan.TicksPerSecond / _frameRate;
    }

    public void AppendPixels(IntPtr pixels, int length, long timestampTicks)
    {
        ObjectDisposedException.ThrowIf(_finished, this);
        CheckStatus(NativeMethods.polyglance_windows_recording_encoder_write(
            _encoder.DangerousGetHandle(), pixels, (nuint)length, timestampTicks));
        CapturedFrames++;
        _endTime = timestampTicks + TimeSpan.TicksPerSecond / _frameRate;
        FramesWritten = (int)Math.Ceiling(_endTime * (double)_frameRate / TimeSpan.TicksPerSecond);
    }

    public void SetPaused(bool paused) => _audioCapture.SetPaused(paused);

    public async Task FinishAsync(string outputPath, TimeSpan? duration = null)
    {
        ObjectDisposedException.ThrowIf(_finished, this);
        _finished = true;
        try
        {
            await _audioCapture.StopAsync();
            var audioFiles = _audioCapture.OutputFiles.ToArray();
            await _audioCapture.DisposeAsync();
            _endTime = Math.Max(_endTime, duration?.Ticks ?? 0);
            await Task.Run(() =>
            {
                CheckStatus(NativeMethods.polyglance_windows_recording_encoder_finish(
                    _encoder.DangerousGetHandle(), _endTime));
                _encoder.Dispose();
                if (audioFiles.Length == 0)
                {
                    File.Move(_videoPath, outputPath, overwrite: true);
                    return;
                }
                var mixedPath = Path.Combine(_temporaryDirectory, "mixed.wav");
                MixAudio(audioFiles, mixedPath, _endTime);
                // 视频保持已经编码的 H.264 数据，只编码音轨和写入 MP4 容器。
                CheckStatus(NativeMethods.polyglance_windows_recording_remux(_videoPath, mixedPath, outputPath));
            });
        }
        finally
        {
            try { await _audioCapture.DisposeAsync(); }
            finally { _encoder.Dispose(); CleanupTemporaryDirectory(); }
        }
    }

    internal static void MixAudio(IReadOnlyList<string> paths, string outputPath, long durationTicks)
    {
        var readers = new List<AudioFileReader>();
        try
        {
            var mixer = new MixingSampleProvider(WaveFormat.CreateIeeeFloatWaveFormat(48_000, 2)) { ReadFully = true };
            foreach (var path in paths)
            {
                var reader = new AudioFileReader(path);
                readers.Add(reader);
                ISampleProvider samples = reader;
                if (samples.WaveFormat.Channels == 1) samples = new MonoToStereoSampleProvider(samples);
                if (samples.WaveFormat.Channels > 2) samples = new StereoDownmix(samples);
                if (samples.WaveFormat.SampleRate != 48_000) samples = new WdlResamplingSampleProvider(samples, 48_000);
                mixer.AddMixerInput(samples);
            }
            var pcm = new SampleToWaveProvider16(mixer);
            using var writer = new WaveFileWriter(outputPath, pcm.WaveFormat);
            var buffer = new byte[48_000 / 10 * 4];
            long remaining = (long)Math.Ceiling(durationTicks / (double)TimeSpan.TicksPerSecond * 48_000) * 4;
            while (remaining > 0)
            {
                int length = (int)Math.Min(buffer.Length, remaining);
                int read = pcm.Read(buffer, 0, length);
                writer.Write(buffer, 0, read);
                remaining -= read;
            }
        }
        finally { foreach (var reader in readers) reader.Dispose(); }
    }

    private sealed class StereoDownmix(ISampleProvider source) : ISampleProvider
    {
        private float[] _input = [];
        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 2);
        public int Read(float[] buffer, int offset, int count)
        {
            int channels = source.WaveFormat.Channels;
            int requested = count / 2 * channels;
            if (_input.Length < requested) _input = new float[requested];
            int frames = source.Read(_input, 0, requested) / channels;
            for (int frame = 0; frame < frames; frame++)
            {
                int input = frame * channels;
                float left = _input[input], right = _input[input + 1];
                // 标准 Windows 声道顺序：前左、前右、中央、低频、后左、后右、侧左、侧右。
                float center = _input[input + 2] * 0.7071f;
                left += center; right += center;
                for (int channel = 4; channel < channels; channel++)
                {
                    if (channel % 2 == 0) left += _input[input + channel] * 0.7071f;
                    else right += _input[input + channel] * 0.7071f;
                }
                buffer[offset + frame * 2] = Math.Clamp(left, -1, 1);
                buffer[offset + frame * 2 + 1] = Math.Clamp(right, -1, 1);
            }
            return frames * 2;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (!_finished)
        {
            _finished = true;
            try { await _audioCapture.DisposeAsync(); }
            finally { _encoder.Dispose(); }
        }
        CleanupTemporaryDirectory();
    }

    private static void CheckStatus(int status)
    {
        if (status != 0) throw new InvalidOperationException($"录屏编码失败 (0x{status:X8})");
    }

    private sealed class EncoderHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public EncoderHandle(IntPtr value) : base(true) => SetHandle(value);
        protected override bool ReleaseHandle()
        {
            NativeMethods.polyglance_windows_recording_encoder_free(handle);
            return true;
        }
    }

    private void CleanupTemporaryDirectory()
    {
        try { if (Directory.Exists(_temporaryDirectory)) Directory.Delete(_temporaryDirectory, true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
