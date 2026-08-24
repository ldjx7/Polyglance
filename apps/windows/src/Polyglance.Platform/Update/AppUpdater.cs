using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows;
using System.Xml.Linq;

namespace Polyglance.Platform.Update;

public sealed class UpdateInfo
{
    public string Version { get; set; } = "";
    public string DownloadUrl { get; set; } = "";
    public string ReleaseNotes { get; set; } = "";
    public string Title { get; set; } = "";
}

public static class AppUpdater
{
    private static readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromSeconds(15) };

    public static Version CurrentVersion => Assembly.GetEntryAssembly()?.GetName().Version ?? new Version(0, 0, 3);

    public static async Task<UpdateInfo?> CheckForUpdatesAsync(string appcastUrl)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(appcastUrl))
                return null;

            string xmlContent = await _httpClient.GetStringAsync(appcastUrl);
            var doc = XDocument.Parse(xmlContent);
            XNamespace sparkleNs = "http://www.andymatuschak.org/xml-namespaces/sparkle";

            var item = doc.Root?.Element("channel")?.Element("item");
            if (item == null) return null;

            string versionStr = item.Element(sparkleNs + "version")?.Value
                                ?? item.Element("version")?.Value
                                ?? "";

            var enclosure = item.Element("enclosure");
            string downloadUrl = enclosure?.Attribute("url")?.Value ?? "";
            string title = item.Element("title")?.Value ?? "Polyglance 新版本";
            string releaseNotes = item.Element("description")?.Value ?? "";

            if (Version.TryParse(versionStr, out var remoteVer) && remoteVer > CurrentVersion)
            {
                return new UpdateInfo
                {
                    Version = versionStr,
                    DownloadUrl = downloadUrl,
                    Title = title,
                    ReleaseNotes = releaseNotes
                };
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Update check failed: {ex.Message}");
        }

        return null;
    }

    public static async Task<bool> DownloadAndApplyUpdateAsync(string downloadUrl, IProgress<int>? progress = null)
    {
        try
        {
            string tempZip = Path.Combine(Path.GetTempPath(), $"Polyglance_Update_{Guid.NewGuid():N}.zip");
            string tempExtractDir = Path.Combine(Path.GetTempPath(), $"Polyglance_Extracted_{Guid.NewGuid():N}");

            using (var response = await _httpClient.GetAsync(downloadUrl, HttpCompletionOption.ResponseHeadersRead))
            {
                response.EnsureSuccessStatusCode();
                long totalBytes = response.Content.Headers.ContentLength ?? -1;

                using var stream = await response.Content.ReadAsStreamAsync();
                using var fileStream = File.Create(tempZip);

                byte[] buffer = new byte[81920];
                long totalRead = 0;
                int bytesRead;

                while ((bytesRead = await stream.ReadAsync(buffer)) > 0)
                {
                    await fileStream.WriteAsync(buffer.AsMemory(0, bytesRead));
                    totalRead += bytesRead;

                    if (totalBytes > 0)
                    {
                        int percent = (int)((totalRead * 100) / totalBytes);
                        progress?.Report(percent);
                    }
                }
            }

            // Extract update
            System.IO.Compression.ZipFile.ExtractToDirectory(tempZip, tempExtractDir);

            string currentAppDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\', '/');
            string currentExe = Process.GetCurrentProcess().MainModule?.FileName ?? Path.Combine(currentAppDir, "Polyglance.UI.exe");

            // Write batch update script
            string batchScript = Path.Combine(Path.GetTempPath(), $"polyglance_updater_{Guid.NewGuid():N}.cmd");
            string scriptContent = $@"@echo off
timeout /t 1 /nobreak >nul
taskkill /f /im Polyglance.UI.exe >nul 2>&1
timeout /t 1 /nobreak >nul
robocopy ""{tempExtractDir}"" ""{currentAppDir}"" /e /is /it /np >nul
start """" ""{currentExe}""
del /f /q ""{tempZip}"" >nul 2>&1
rd /s /q ""{tempExtractDir}"" >nul 2>&1
(goto) 2>nul & del ""%~f0""
";
            File.WriteAllText(batchScript, scriptContent, System.Text.Encoding.Default);

            Process.Start(new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = $"/c \"{batchScript}\"",
                CreateNoWindow = true,
                UseShellExecute = false
            });

            Application.Current.Dispatcher.Invoke(() => Application.Current.Shutdown());
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Failed to apply update: {ex.Message}");
            return false;
        }
    }
}
