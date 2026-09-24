using System.Buffers.Binary;
using System.IO;
using NAudio.Wave;
using Polyglance.Platform.Recording;

namespace Polyglance.Platform.Tests;

public sealed class ScreenRecordingAudioMixTests
{
    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(6)]
    public void MixConvertsToStereoAndPadsToVideoDuration(int channels)
    {
        string directory = Path.Combine(Path.GetTempPath(), "Polyglance.AudioMix." + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            string input = Path.Combine(directory, "input.wav"), output = Path.Combine(directory, "mixed.wav");
            using (var writer = new WaveFileWriter(input, WaveFormat.CreateIeeeFloatWaveFormat(48_000, channels)))
            {
                var samples = new float[12_000 * channels];
                for (int frame = 0; frame < 12_000; frame++)
                {
                    // 验证中央声道不会在转双声道时丢失。
                    samples[frame * channels + (channels > 2 ? 2 : 0)] = 0.25f;
                }
                writer.WriteSamples(samples, 0, samples.Length);
            }
            ScreenRecordingMp4Session.MixAudio([input], output, TimeSpan.TicksPerSecond);
            using var reader = new WaveFileReader(output);
            Assert.Equal(2, reader.WaveFormat.Channels);
            Assert.Equal(48_000, reader.WaveFormat.SampleRate);
            Assert.Equal(16, reader.WaveFormat.BitsPerSample);
            Assert.Equal(192_000, reader.Length);
            var bytes = new byte[4];
            Assert.Equal(4, reader.Read(bytes, 0, 4));
            Assert.True(BinaryPrimitives.ReadInt16LittleEndian(bytes) > 2000);
            reader.Position = 96_000;
            Assert.Equal(4, reader.Read(bytes, 0, 4));
            Assert.All(bytes, value => Assert.Equal(0, value));
        }
        finally { Directory.Delete(directory, true); }
    }
}
