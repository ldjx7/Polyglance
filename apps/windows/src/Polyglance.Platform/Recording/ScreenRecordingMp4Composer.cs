using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using System.IO;

namespace Polyglance.Platform.Recording;

public static class ScreenRecordingMp4Composer
{
    public static async Task ComposeAsync(
        string videoPath,
        IReadOnlyList<string> audioPaths,
        string outputPath,
        int width,
        int height,
        int frameRate,
        uint videoBitrate)
    {
        var videoFile = await StorageFile.GetFileFromPathAsync(videoPath);
        var composition = new MediaComposition();
        composition.Clips.Add(await MediaClip.CreateFromFileAsync(videoFile));

        foreach (var audioPath in audioPaths)
        {
            var audioFile = await StorageFile.GetFileFromPathAsync(audioPath);
            composition.BackgroundAudioTracks.Add(await BackgroundAudioTrack.CreateFromFileAsync(audioFile));
        }

        var outputDirectory = Path.GetDirectoryName(outputPath)
            ?? throw new InvalidOperationException("录屏输出目录无效");
        Directory.CreateDirectory(outputDirectory);
        var folder = await StorageFolder.GetFolderFromPathAsync(outputDirectory);
        var outputFile = await folder.CreateFileAsync(
            Path.GetFileName(outputPath),
            CreationCollisionOption.ReplaceExisting);

        var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.Auto);
        profile.Video.Width = (uint)Math.Max(2, width - width % 2);
        profile.Video.Height = (uint)Math.Max(2, height - height % 2);
        profile.Video.FrameRate.Numerator = (uint)Math.Max(1, frameRate);
        profile.Video.FrameRate.Denominator = 1;
        profile.Video.Bitrate = videoBitrate;
        if (audioPaths.Count == 0)
        {
            profile.Audio = null;
        }
        else
        {
            profile.Audio = AudioEncodingProperties.CreateAac(48_000, 2, 192_000);
        }

        var result = await composition.RenderToFileAsync(
            outputFile,
            MediaTrimmingPreference.Precise,
            profile);
        if (result != TranscodeFailureReason.None)
        {
            throw new InvalidOperationException($"MP4 编码失败：{result}");
        }
    }
}
