using System.Net;
using System.Net.Http;
using Polyglance.Platform.Update;

namespace Polyglance.Platform.Tests;

public sealed class AppUpdaterTests
{
    [Fact]
    public async Task Beta4DetectsBeta5AndUsesTheSemanticVersionForDisplay()
    {
        using var client = CreateClient(_ => Response(Appcast("0.0.4-beta.5", "0.0.4.3")));

        UpdateCheckResult result = await AppUpdater.CheckForUpdatesAsync(
            "https://updates.example.test/appcast.xml",
            client,
            "0.0.4-beta.4",
            new Version(0, 0, 4, 2));

        Assert.Equal(UpdateCheckStatus.UpdateAvailable, result.Status);
        Assert.NotNull(result.Update);
        Assert.Equal("0.0.4-beta.5", result.Update!.Version);
        Assert.Equal("0.0.4.3", result.Update.BuildVersion);
        Assert.Equal("https://updates.example.test/Polyglance.zip", result.Update.DownloadUrl);
    }

    [Fact]
    public async Task SameSemanticAndBuildVersionIsUpToDate()
    {
        using var client = CreateClient(_ => Response(Appcast("0.0.4-beta.5", "0.0.4.3")));

        UpdateCheckResult result = await AppUpdater.CheckForUpdatesAsync(
            "https://updates.example.test/appcast.xml",
            client,
            "0.0.4-beta.5",
            new Version(0, 0, 4, 3));

        Assert.Equal(UpdateCheckStatus.UpToDate, result.Status);
        Assert.Null(result.Update);
        Assert.Equal(string.Empty, result.ErrorMessage);
    }

    [Fact]
    public async Task TransportFailureIsReportedInsteadOfBeingCalledUpToDate()
    {
        using var client = CreateClient(_ => throw new HttpRequestException("network offline"));

        UpdateCheckResult result = await AppUpdater.CheckForUpdatesAsync(
            "https://updates.example.test/appcast.xml",
            client,
            "0.0.4-beta.4",
            new Version(0, 0, 4, 2));

        Assert.Equal(UpdateCheckStatus.Failed, result.Status);
        Assert.Null(result.Update);
        Assert.Contains("network offline", result.ErrorMessage, StringComparison.Ordinal);
    }

    [Fact]
    public async Task MissingLatestWindowsFeedFallsBackToNewestReleaseContainingTheAsset()
    {
        var requestedUrls = new List<string>();
        using var client = CreateClient(request =>
        {
            string url = request.RequestUri?.AbsoluteUri ?? "";
            requestedUrls.Add(url);
            return url switch
            {
                "https://github.com/ldjx7/Polyglance/releases/latest/download/appcast-windows.xml" =>
                    new HttpResponseMessage(HttpStatusCode.NotFound),
                "https://api.github.com/repos/ldjx7/Polyglance/releases?per_page=20" =>
                    Response("""
                        [
                          {
                            "draft": false,
                            "assets": [
                              {
                                "name": "appcast.xml",
                                "browser_download_url": "https://downloads.example.test/beta.6/appcast.xml"
                              }
                            ]
                          },
                          {
                            "draft": false,
                            "assets": [
                              {
                                "name": "appcast-windows.xml",
                                "browser_download_url": "https://downloads.example.test/beta.5/appcast-windows.xml"
                              }
                            ]
                          }
                        ]
                        """),
                "https://downloads.example.test/beta.5/appcast-windows.xml" =>
                    Response(Appcast("0.0.4-beta.5", "0.0.4.3")),
                _ => throw new InvalidOperationException($"Unexpected update request: {url}")
            };
        });

        UpdateCheckResult result = await AppUpdater.CheckForUpdatesAsync(
            "https://github.com/ldjx7/Polyglance/releases/latest/download/appcast-windows.xml",
            client,
            "0.0.4-beta.4",
            new Version(0, 0, 4, 2));

        Assert.Equal(UpdateCheckStatus.UpdateAvailable, result.Status);
        Assert.Equal("0.0.4-beta.5", result.Update?.Version);
        Assert.Equal(
            [
                "https://github.com/ldjx7/Polyglance/releases/latest/download/appcast-windows.xml",
                "https://api.github.com/repos/ldjx7/Polyglance/releases?per_page=20",
                "https://downloads.example.test/beta.5/appcast-windows.xml"
            ],
            requestedUrls);
    }

    [Fact]
    public async Task InvalidXmlIsReportedInsteadOfBeingCalledUpToDate()
    {
        using var client = CreateClient(_ => Response("not xml"));

        UpdateCheckResult result = await AppUpdater.CheckForUpdatesAsync(
            "https://updates.example.test/appcast.xml",
            client,
            "0.0.4-beta.4",
            new Version(0, 0, 4, 2));

        Assert.Equal(UpdateCheckStatus.Failed, result.Status);
        Assert.Contains("更新信息格式无效", result.ErrorMessage, StringComparison.Ordinal);
    }

    [Fact]
    public async Task RequestIdentifiesPolyglanceAndDisablesCachedFeedResponses()
    {
        string? capturedUserAgent = null;
        bool capturedNoCache = false;
        bool capturedNoStore = false;
        using var client = CreateClient(request =>
        {
            capturedUserAgent = request.Headers.UserAgent.ToString();
            capturedNoCache = request.Headers.CacheControl?.NoCache == true;
            capturedNoStore = request.Headers.CacheControl?.NoStore == true;
            return Response(Appcast("0.0.4-beta.5", "0.0.4.3"));
        });

        await AppUpdater.CheckForUpdatesAsync(
            "https://updates.example.test/appcast.xml",
            client,
            "0.0.4-beta.4",
            new Version(0, 0, 4, 2));

        Assert.Contains("Polyglance", capturedUserAgent, StringComparison.Ordinal);
        Assert.True(capturedNoCache);
        Assert.True(capturedNoStore);
    }

    [Theory]
    [InlineData("0.0.4-beta.5", "0.0.4-beta.4", 1)]
    [InlineData("0.0.4-beta.10", "0.0.4-beta.9", 1)]
    [InlineData("0.0.4", "0.0.4-beta.10", 1)]
    [InlineData("0.0.4-beta.5+build.8", "0.0.4-beta.5+build.3", 0)]
    public void SemanticVersionsFollowPrereleaseOrdering(string left, string right, int expectedSign)
    {
        Assert.True(SemanticVersion.TryParse(left, out SemanticVersion? leftVersion));
        Assert.True(SemanticVersion.TryParse(right, out SemanticVersion? rightVersion));
        Assert.Equal(expectedSign, Math.Sign(leftVersion!.CompareTo(rightVersion)));
    }

    private static HttpClient CreateClient(Func<HttpRequestMessage, HttpResponseMessage> responder) =>
        new(new StubHttpMessageHandler(responder));

    private static HttpResponseMessage Response(string content) =>
        new(HttpStatusCode.OK) { Content = new StringContent(content) };

    private static string Appcast(string shortVersion, string buildVersion) => $$"""
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <title>Polyglance {{shortVersion}}</title>
              <sparkle:shortVersionString>{{shortVersion}}</sparkle:shortVersionString>
              <sparkle:version>{{buildVersion}}</sparkle:version>
              <description>Update notes</description>
              <enclosure url="https://updates.example.test/Polyglance.zip" type="application/zip" />
            </item>
          </channel>
        </rss>
        """;

    private sealed class StubHttpMessageHandler(Func<HttpRequestMessage, HttpResponseMessage> responder)
        : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            Task.FromResult(responder(request));
    }
}
