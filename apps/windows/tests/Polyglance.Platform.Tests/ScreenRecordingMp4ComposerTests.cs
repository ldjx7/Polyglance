using System.Buffers.Binary;
using System.IO;
using NAudio.Wave;
using Polyglance.Platform.Recording;
using SharpAvi.Codecs;
using SharpAvi.Output;

namespace Polyglance.Platform.Tests;

public sealed class ScreenRecordingMp4ComposerTests : IDisposable
{
    private readonly string _directory = Path.Combine(
        Path.GetTempPath(),
        $"Polyglance.Mp4ComposerTests.{Guid.NewGuid():N}");

    [Fact]
    public async Task RendersRealMp4WithSystemAndMicrophoneAudioInputs()
    {
        Directory.CreateDirectory(_directory);
        var videoPath = Path.Combine(_directory, "video.avi");
        var systemAudioPath = Path.Combine(_directory, "system.wav");
        var microphonePath = Path.Combine(_directory, "microphone.wav");
        var outputPath = Path.Combine(_directory, "output.mp4");
        CreateVideo(videoPath);
        CreateTone(systemAudioPath, 440);
        CreateTone(microphonePath, 660);

        await ScreenRecordingMp4Composer.ComposeAsync(
            videoPath,
            [systemAudioPath, microphonePath],
            outputPath,
            width: 64,
            height: 64,
            frameRate: 5,
            videoBitrate: 2_000_000);

        Assert.True(File.Exists(outputPath));
        var fileInfo = new FileInfo(outputPath);
        Assert.True(fileInfo.Length > 1_024);
        Assert.Equal(".mp4", Path.GetExtension(outputPath));
        using var stream = File.OpenRead(outputPath);
        var header = new byte[8];
        Assert.Equal(8, stream.Read(header, 0, 8));
        Assert.Equal("ftyp", System.Text.Encoding.ASCII.GetString(header, 4, 4));
    }

    [Theory]
    [InlineData(64, 64)]
    [InlineData(65, 63)]
    public async Task SessionWritesRepeatedFramesWithoutAudio(int width, int height)
    {
        Directory.CreateDirectory(_directory);
        var sessionDirectory = Path.Combine(_directory, "session");
        var outputPath = Path.Combine(_directory, "silent.mp4");
        var options = ScreenRecordingMediaOptions.Create(ScreenRecordingContainer.Mp4, false, false, false);
        await using var session = new ScreenRecordingMp4Session(
            sessionDirectory, width, height, 30, 2_000_000, options);
        var frame = System.Windows.Media.Imaging.BitmapSource.Create(
            width, height, 96, 96, System.Windows.Media.PixelFormats.Bgr32,
            null, new byte[width * height * 4], width * 4);
        frame.Freeze();
        await Task.Run(() => session.AppendFrame(frame, 30));
        Assert.Equal(30, session.FramesWritten);
        await session.FinishAsync(outputPath);
        Assert.True(new FileInfo(outputPath).Length > 1024);
        Assert.False(Directory.Exists(sessionDirectory));
        using var stream = File.OpenRead(outputPath);
        var header = new byte[8];
        Assert.Equal(8, stream.Read(header, 0, 8));
        Assert.Equal("ftyp", System.Text.Encoding.ASCII.GetString(header, 4, 4));
    }

    private static void CreateVideo(string path)
    {
        using var writer = new AviWriter(path)
        {
            FramesPerSecond = 5,
            EmitIndex1 = true,
        };
        var stream = writer.AddMJpegWpfVideoStream(64, 64, 80);
        var frame = new byte[64 * 64 * 4];
        for (var index = 0; index < frame.Length; index += 4)
        {
            frame[index] = 0x30;
            frame[index + 1] = 0x80;
            frame[index + 2] = 0xE0;
            frame[index + 3] = 0xFF;
        }
        for (var frameIndex = 0; frameIndex < 5; frameIndex++)
        {
            stream.WriteFrame(true, frame, 0, frame.Length);
        }
    }

    private static void CreateTone(string path, double frequency)
    {
        const int sampleRate = 48_000;
        var bytes = new byte[sampleRate * 2];
        for (var index = 0; index < sampleRate; index++)
        {
            var value = (short)(Math.Sin(2 * Math.PI * frequency * index / sampleRate) * 4_000);
            BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(index * 2, 2), value);
        }
        using var writer = new WaveFileWriter(path, new WaveFormat(sampleRate, 16, 1));
        writer.Write(bytes, 0, bytes.Length);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
        }
        catch
        {
            // Media Foundation can release the final file handle just after the assertion completes.
        }
    }
}
