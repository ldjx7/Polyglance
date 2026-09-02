using Polyglance.Core.Services;

namespace Polyglance.Core.Tests;

public sealed class BarcodeContentTests
{
    [Fact]
    public void WebLinksBecomeOpenableUrls()
    {
        foreach (var payload in new[] { "https://example.com", "http://example.com/path?q=1" })
        {
            var content = BarcodeContent.From(payload);

            Assert.IsType<BarcodeContent.Url>(content);
            Assert.True(content.IsOpenable);
        }
    }

    [Fact]
    public void OtpSchemesAreRecognisedSeparately()
    {
        var content = BarcodeContent.From("otpauth://totp/Example:me?secret=ABC123");

        Assert.IsType<BarcodeContent.Otp>(content);
        // A key is not a web page, so it must never be offered as one.
        Assert.False(content.IsOpenable);
    }

    [Fact]
    public void NonWebSchemesGetNoOpenAction()
    {
        foreach (var payload in new[] { "file:///etc/passwd", "smb://server/share", "myapp://deep/link" })
        {
            var content = BarcodeContent.From(payload);

            Assert.IsType<BarcodeContent.Text>(content);
            Assert.False(content.IsOpenable);
        }
    }

    [Fact]
    public void WiFiPayloadIsUnescaped()
    {
        // The escaped punctuation is what makes a naive split-on-semicolon wrong.
        var content = BarcodeContent.From(@"WIFI:T:WPA;S:café\,office;P:pa\;ss\:word;;");

        var wifi = Assert.IsType<BarcodeContent.Wifi>(content);
        Assert.Equal("café,office", wifi.Ssid);
        Assert.Equal("pa;ss:word", wifi.Password);
        Assert.Equal("WPA", wifi.Security);
        Assert.Equal("pa;ss:word", content.CopiedText);
    }

    [Fact]
    public void WiFiWithoutAnSsidFallsBackToText()
    {
        var content = BarcodeContent.From("WIFI:T:WPA;P:secret;;");

        Assert.IsType<BarcodeContent.Text>(content);
    }

    [Fact]
    public void PlainTextStaysPlainText()
    {
        var content = BarcodeContent.From("只是一段文字");

        var text = Assert.IsType<BarcodeContent.Text>(content);
        Assert.Equal("只是一段文字", text.Value);
        Assert.False(content.IsOpenable);
        Assert.False(content.IsTranslatable);
    }

    [Fact]
    public void BinaryLikeTextCannotBeSentToTranslation()
    {
        var content = BarcodeContent.From("\0\u0001\uFFFD");

        Assert.IsType<BarcodeContent.Text>(content);
        Assert.False(content.IsTranslatable);
    }

    [Fact]
    public void UpcaHasTheSameUserFacingTitleOnWindowsAndMac()
    {
        Assert.Equal("UPC-A", BarcodeSymbology.Upca.Title());
    }
}
