// 仅用于性能对照：复现修改前的 MJPEG 中间文件流程，不参与应用录制。
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.IO;
using SharpAvi.Codecs;
using SharpAvi.Output;

namespace Polyglance.Platform.Recording;

public sealed class LegacyRecordingSession : IAsyncDisposable
{
    private readonly string _temporaryDirectory;
    private readonly string _videoPath;
    private readonly int _width;
    private readonly int _height;
    private readonly int _frameRate;
    private readonly uint _videoBitrate;
    private readonly AviWriter _writer;
    private readonly IAviVideoStream _videoStream;
    private readonly MJpegWpfVideoEncoder _encoder;
    private readonly byte[] _encodedBuffer;
    private readonly byte[] _pixelBuffer;
    public int FramesWritten { get; private set; }
    private bool _finished;

    public LegacyRecordingSession(
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
        _encoder = new MJpegWpfVideoEncoder(_width, _height, Math.Clamp(jpegQuality, 1, 100));
        _encodedBuffer = new byte[_encoder.MaxEncodedSize];
        _videoStream = _writer.AddVideoStream(_width, _height, _encoder.BitsPerPixel);
        _videoStream.Codec = _encoder.Codec;
        _pixelBuffer = new byte[checked(_width * _height * 4)];

    }

    public void AppendFrame(BitmapSource frame, int repeatCount = 1)
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

        // 补帧复用已压缩的数据，避免同一画面重复进行 JPEG 编码。
        int encodedLength = _encoder.EncodeFrame(_pixelBuffer, 0, _encodedBuffer, 0, out bool isKeyFrame);
        int count = Math.Clamp(repeatCount, 1, _frameRate * 3);
        for (int i = 0; i < count; i++)
        {
            _videoStream.WriteFrame(isKeyFrame, _encodedBuffer, 0, encodedLength);
            FramesWritten++;
        }
    }

    public void SetPaused(bool paused) { }

    public async Task FinishAsync(string outputPath)
    {
        ObjectDisposedException.ThrowIf(_finished, this);
        _finished = true;
        try
        {
            var audioFiles = Array.Empty<string>();
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

    public ValueTask DisposeAsync()
    {
        if (!_finished)
        {
            _finished = true;
            _writer.Close();
        }
        CleanupTemporaryDirectory();
        return ValueTask.CompletedTask;
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
