using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Xml;
using System.Xml.Linq;
using Polyglance.Core.Services;

namespace Polyglance.Platform.Update;

public sealed class UpdateInfo
{
    public string Version { get; set; } = "";
    public string BuildVersion { get; set; } = "";
    public string DownloadUrl { get; set; } = "";
    public string ReleaseNotes { get; set; } = "";
    public string Title { get; set; } = "";
}

public enum UpdateCheckStatus
{
    UpdateAvailable,
    UpToDate,
    Failed
}

public sealed class UpdateCheckResult
{
    public UpdateCheckStatus Status { get; init; }
    public UpdateInfo? Update { get; init; }
    public string ErrorMessage { get; init; } = "";
}

public static class AppUpdater
{
    private static readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromSeconds(15) };

    public static Version CurrentVersion => Assembly.GetEntryAssembly()?.GetName().Version ?? new Version(0, 0, 3);

    public static string CurrentSemanticVersion =>
        AppVersionDisplay.FromAssembly(Assembly.GetEntryAssembly()).TrimStart('v', 'V');

    public static Task<UpdateCheckResult> CheckForUpdatesAsync(string appcastUrl) =>
        CheckForUpdatesAsync(appcastUrl, _httpClient, CurrentSemanticVersion, CurrentVersion);

    internal static async Task<UpdateCheckResult> CheckForUpdatesAsync(
        string appcastUrl,
        HttpClient httpClient,
        string currentSemanticVersion,
        Version currentBuildVersion)
    {
        if (string.IsNullOrWhiteSpace(appcastUrl))
            return Failed("更新地址未配置。");

        try
        {
            string xmlContent = await DownloadAppcastAsync(
                appcastUrl,
                httpClient,
                currentSemanticVersion);

            var doc = XDocument.Parse(xmlContent);
            XNamespace sparkleNs = "http://www.andymatuschak.org/xml-namespaces/sparkle";

            var item = doc.Root?.Element("channel")?.Element("item");
            if (item == null)
                return Failed("更新信息格式无效：缺少版本条目。");

            string buildVersion = item.Element(sparkleNs + "version")?.Value
                                  ?? item.Element("version")?.Value
                                  ?? "";
            string title = item.Element("title")?.Value ?? "Polyglance 新版本";
            string semanticVersion = item.Element(sparkleNs + "shortVersionString")?.Value
                                     ?? VersionFromTitle(title)
                                     ?? buildVersion;

            var enclosure = item.Element("enclosure");
            string downloadUrl = enclosure?.Attribute("url")?.Value ?? "";
            string releaseNotes = item.Element("description")?.Value ?? "";

            if (!Version.TryParse(buildVersion, out Version? remoteBuildVersion))
                return Failed("更新信息格式无效：构建版本号无法识别。");
            if (string.IsNullOrWhiteSpace(downloadUrl))
                return Failed("更新信息格式无效：缺少下载地址。");

            bool remoteSemanticVersionValid =
                SemanticVersion.TryParse(semanticVersion, out SemanticVersion? remoteSemanticVersion);
            bool currentSemanticVersionValid =
                SemanticVersion.TryParse(currentSemanticVersion, out SemanticVersion? currentParsedVersion);
            bool semanticVersionsValid = remoteSemanticVersionValid && currentSemanticVersionValid;
            int semanticComparison = semanticVersionsValid
                ? remoteSemanticVersion!.CompareTo(currentParsedVersion)
                : 0;
            bool isNewer = semanticVersionsValid
                ? semanticComparison > 0
                    || (semanticComparison == 0 && remoteBuildVersion > currentBuildVersion)
                : remoteBuildVersion > currentBuildVersion;

            if (isNewer)
            {
                return new UpdateCheckResult
                {
                    Status = UpdateCheckStatus.UpdateAvailable,
                    Update = new UpdateInfo
                    {
                        Version = semanticVersion.TrimStart('v', 'V'),
                        BuildVersion = buildVersion,
                        DownloadUrl = downloadUrl,
                        Title = title,
                        ReleaseNotes = releaseNotes
                    }
                };
            }

            return new UpdateCheckResult { Status = UpdateCheckStatus.UpToDate };
        }
        catch (TaskCanceledException error)
        {
            return Failed($"连接更新服务器超时：{error.Message}");
        }
        catch (HttpRequestException error)
        {
            return Failed($"无法访问更新服务器：{error.Message}");
        }
        catch (XmlException error)
        {
            return Failed($"更新信息格式无效：{error.Message}");
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Update check failed: {error.Message}");
            return Failed($"检查更新失败：{error.Message}");
        }
    }

    private static UpdateCheckResult Failed(string message) => new()
    {
        Status = UpdateCheckStatus.Failed,
        ErrorMessage = message
    };

    private static async Task<string> DownloadAppcastAsync(
        string appcastUrl,
        HttpClient httpClient,
        string currentSemanticVersion)
    {
        using HttpResponseMessage response = await SendUpdateRequestAsync(
            httpClient,
            appcastUrl,
            currentSemanticVersion);

        if (response.StatusCode == HttpStatusCode.NotFound
            && TryCreateGitHubReleaseLookup(appcastUrl, out string? releasesApiUrl, out string? assetName))
        {
            string? fallbackUrl = await FindNewestGitHubReleaseAssetAsync(
                httpClient,
                releasesApiUrl!,
                assetName!,
                currentSemanticVersion);
            if (!string.IsNullOrWhiteSpace(fallbackUrl))
            {
                using HttpResponseMessage fallbackResponse = await SendUpdateRequestAsync(
                    httpClient,
                    fallbackUrl,
                    currentSemanticVersion);
                fallbackResponse.EnsureSuccessStatusCode();
                return await fallbackResponse.Content.ReadAsStringAsync();
            }
        }

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsStringAsync();
    }

    private static async Task<HttpResponseMessage> SendUpdateRequestAsync(
        HttpClient httpClient,
        string url,
        string currentSemanticVersion)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.UserAgent.Add(new ProductInfoHeaderValue("Polyglance", currentSemanticVersion));
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
        return await httpClient.SendAsync(request);
    }

    private static bool TryCreateGitHubReleaseLookup(
        string appcastUrl,
        out string? releasesApiUrl,
        out string? assetName)
    {
        releasesApiUrl = null;
        assetName = null;
        if (!Uri.TryCreate(appcastUrl, UriKind.Absolute, out Uri? uri)
            || !uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            || !uri.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        string[] segments = uri.AbsolutePath
            .Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (segments.Length != 6
            || !segments[2].Equals("releases", StringComparison.OrdinalIgnoreCase)
            || !segments[3].Equals("latest", StringComparison.OrdinalIgnoreCase)
            || !segments[4].Equals("download", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        string owner = Uri.EscapeDataString(segments[0]);
        string repository = Uri.EscapeDataString(segments[1]);
        assetName = Uri.UnescapeDataString(segments[5]);
        releasesApiUrl = $"https://api.github.com/repos/{owner}/{repository}/releases?per_page=20";
        return !string.IsNullOrWhiteSpace(assetName);
    }

    private static async Task<string?> FindNewestGitHubReleaseAssetAsync(
        HttpClient httpClient,
        string releasesApiUrl,
        string assetName,
        string currentSemanticVersion)
    {
        using HttpResponseMessage response = await SendUpdateRequestAsync(
            httpClient,
            releasesApiUrl,
            currentSemanticVersion);
        response.EnsureSuccessStatusCode();
        string json = await response.Content.ReadAsStringAsync();

        using JsonDocument document = JsonDocument.Parse(json);
        if (document.RootElement.ValueKind != JsonValueKind.Array)
            return null;

        foreach (JsonElement release in document.RootElement.EnumerateArray())
        {
            if (release.TryGetProperty("draft", out JsonElement draft)
                && draft.ValueKind == JsonValueKind.True)
            {
                continue;
            }
            if (!release.TryGetProperty("assets", out JsonElement assets)
                || assets.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            foreach (JsonElement asset in assets.EnumerateArray())
            {
                if (!asset.TryGetProperty("name", out JsonElement name)
                    || !string.Equals(name.GetString(), assetName, StringComparison.OrdinalIgnoreCase)
                    || !asset.TryGetProperty("browser_download_url", out JsonElement downloadUrl))
                {
                    continue;
                }

                string? value = downloadUrl.GetString();
                if (Uri.TryCreate(value, UriKind.Absolute, out Uri? downloadUri)
                    && downloadUri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
                {
                    return downloadUri.AbsoluteUri;
                }
            }
        }

        return null;
    }

    private static string? VersionFromTitle(string title)
    {
        const string prefix = "Polyglance ";
        return title.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            ? title[prefix.Length..].Trim()
            : null;
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
