using System;
using System.Windows;
using System.Windows.Media.Imaging;
using Polyglance.Platform.Pin;

namespace Polyglance.UI.Views;

internal static class PinArchiveRecording
{
    internal static async void Record(BitmapSource image, PinArchiveSource source, PinArchiveStore? store = null, string? id = null)
    {
        try
        {
            if (await (store ?? PinHistoryManager.DefaultStore).AppendAsync(image, source, id) != null)
                return;
        }
        catch (Exception error)
        {
            System.Diagnostics.Trace.TraceError("Pin archive write failed: {0}", error.Message);
        }
        if (System.Windows.Application.Current != null)
            MessageBox.Show("截图或贴图仍可使用。请检查历史目录的可用空间、写入权限或文件占用情况后重试。",
                "未能保存到贴图历史", MessageBoxButton.OK, MessageBoxImage.Warning);
    }
}
