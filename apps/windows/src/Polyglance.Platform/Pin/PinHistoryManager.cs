using System;
using System.Collections.Generic;
using System.IO;
using System.Windows.Media.Imaging;

namespace Polyglance.Platform.Pin;

public sealed class PinHistoryItem
{
    public string FilePath { get; set; } = "";
    public DateTime CreatedAt { get; set; } = DateTime.Now;
    public int Width { get; set; }
    public int Height { get; set; }
}

public static class PinHistoryManager
{
    private static readonly string HistoryDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "Polyglance",
        "PinHistory"
    );

    static PinHistoryManager()
    {
        try
        {
            if (!Directory.Exists(HistoryDir))
            {
                Directory.CreateDirectory(HistoryDir);
            }
        }
        catch { }
    }

    public static void SavePinToHistory(BitmapSource bitmap)
    {
        try
        {
            string fileName = $"pin_{DateTime.Now:yyyyMMdd_HHmmss}_{Guid.NewGuid():N}.png";
            string filePath = Path.Combine(HistoryDir, fileName);

            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var stream = File.Create(filePath);
            encoder.Save(stream);

            // Clean old pins (keep latest 30)
            CleanupOldPins(30);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to save pin history: {ex.Message}");
        }
    }

    public static List<PinHistoryItem> GetRecentPins()
    {
        var list = new List<PinHistoryItem>();
        try
        {
            if (!Directory.Exists(HistoryDir))
                return list;

            var files = new DirectoryInfo(HistoryDir).GetFiles("*.png");
            Array.Sort(files, (a, b) => b.CreationTime.CompareTo(a.CreationTime));

            foreach (var file in files)
            {
                list.Add(new PinHistoryItem
                {
                    FilePath = file.FullName,
                    CreatedAt = file.CreationTime
                });
            }
        }
        catch { }

        return list;
    }

    private static void CleanupOldPins(int maxCount)
    {
        try
        {
            var files = new DirectoryInfo(HistoryDir).GetFiles("*.png");
            if (files.Length > maxCount)
            {
                Array.Sort(files, (a, b) => a.CreationTime.CompareTo(b.CreationTime));
                for (int i = 0; i < files.Length - maxCount; i++)
                {
                    files[i].Delete();
                }
            }
        }
        catch { }
    }
}
