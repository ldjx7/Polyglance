using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using Polyglance.Core.Native;

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
        ArgumentException.ThrowIfNullOrWhiteSpace(videoPath);
        ArgumentNullException.ThrowIfNull(audioPaths);
        ArgumentException.ThrowIfNullOrWhiteSpace(outputPath);

        string audioJson = JsonSerializer.Serialize(audioPaths);

        // 重度视频压制合成移入后台线程执行，彻底根治 UI 主线程被阻塞数秒导致的窗口黑屏卡死假死
        int status = await Task.Run(() => NativeMethods.polyglance_windows_recording_compose(
            videoPath,
            audioJson,
            outputPath,
            width,
            height,
            frameRate,
            videoBitrate));

        if (status != 0)
        {
            throw new InvalidOperationException($"MP4 编码失败 (错误码 {status})。");
        }
    }
}
