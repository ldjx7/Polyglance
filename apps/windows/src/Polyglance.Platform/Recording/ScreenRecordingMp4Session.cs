using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.IO;
using SharpAvi.Codecs;
using SharpAvi.Output;

namespace Polyglance.Platform.Recording;

public sealed class ScreenRecordingMp4Session : IAsyncDisposable
{
    private readonly string _temporaryDirectory;
    private readonly string _videoPath;
    private readonly int _width;
    private readonly int _height;
    private readonly int _frameRate;
    private readonly uint _videoBitrate;
    private readonly AviWriter _writer;
    private readonly IAviVideoStream _videoStream;
    private readonly ScreenRecordingAudioCapture _audioCapture;
    private byte[] _pixelBuffer;
    private bool _finished;

    public ScreenRecordingMp4Session(
        string temporaryDirectory,
        int width,
        int height,
        int frameRate,
        int jpegQuality,
        uint videoBitrate,
        ScreenRecordingMediaOptions options)
    {
        if (options.Container != ScreenRecordingContainer.Mp4)
        {
            throw new ArgumentException("MP4 会话只能用于 MP4 格式", nameof(options));
        }
        _temporaryDirectory = temporaryDirectory;
        _width = Math.Max(1, width);
        _height = Math.Max(1, height);
        _frameRate = Math.Max(1, frameRate);
        _videoBitrate = videoBitrate;
        Directory.CreateDirectory(_temporaryDirectory);
        _videoPath = Path.Combine(_temporaryDirectory, "video.avi");
        _writer = new AviWriter(_videoPath)
        {
            FramesPerSecond = _frameRate,
            EmitIndex1 = true,
        };
        _videoStream = _writer.AddMJpegWpfVideoStream(
            _width,
            _height,
            Math.Clamp(jpegQuality, 1, 100));
        _pixelBuffer = new byte[checked(_width * _height * 4)];
        try
        {
            _audioCapture = ScreenRecordingAudioCapture.Create(_temporaryDirectory, options);
            _audioCapture.Start();
        }
        catch
        {
            _writer.Close();
            CleanupTemporaryDirectory();
            throw;
        }
    }

    public void AppendFrame(BitmapSource frame)
    {
        ObjectDisposedException.ThrowIf(_finished, this);
        BitmapSource source = frame;
        if (source.PixelWidth != _width || source.PixelHeight != _height || source.Format != PixelFormats.Bgr32)
        {
            var converted = new FormatConvertedBitmap(
                source,
                PixelFormats.Bgr32,
                null,
                0);
            converted.Freeze();
            source = converted;
        }
        if (source.PixelWidth != _width || source.PixelHeight != _height)
        {
            throw new InvalidOperationException(
                $"录屏帧尺寸不一致：预期 {_width}×{_height}，实际 {source.PixelWidth}×{source.PixelHeight}");
        }
        source.CopyPixels(
            new Int32Rect(0, 0, _width, _height),
            _pixelBuffer,
            _width * 4,
            0);
        _videoStream.WriteFrame(true, _pixelBuffer, 0, _pixelBuffer.Length);
    }

    public void SetPaused(bool paused) => _audioCapture.SetPaused(paused);

    public async Task FinishAsync(string outputPath)
    {
        ObjectDisposedException.ThrowIf(_finished, this);
        _finished = true;
        try
        {
            await _audioCapture.StopAsync();
            var audioFiles = _audioCapture.OutputFiles.ToArray();
            await _audioCapture.DisposeAsync();
            _writer.Close();
            await ScreenRecordingMp4Composer.ComposeAsync(
                _videoPath,
                audioFiles,
                outputPath,
                _width,
                _height,
                _frameRate,
                _videoBitrate);
        }
        finally
        {
            CleanupTemporaryDirectory();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (!_finished)
        {
            _finished = true;
            await _audioCapture.DisposeAsync();
            _writer.Close();
        }
        CleanupTemporaryDirectory();
    }

    private void CleanupTemporaryDirectory()
    {
        try
        {
            if (Directory.Exists(_temporaryDirectory))
            {
                Directory.Delete(_temporaryDirectory, recursive: true);
            }
        }
        catch
        {
            // Temporary files can be cleaned by the OS if a media component still has a handle briefly.
        }
    }
}
