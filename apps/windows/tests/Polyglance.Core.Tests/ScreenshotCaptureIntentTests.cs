using Polyglance.Core.Models;

namespace Polyglance.Core.Tests;

public sealed class ScreenshotCaptureIntentTests
{
    [Theory]
    [InlineData(ScreenshotCaptureIntent.Standard, ScreenshotSelectionAction.None)]
    [InlineData(ScreenshotCaptureIntent.ScreenTranslation, ScreenshotSelectionAction.ScreenTranslation)]
    [InlineData(ScreenshotCaptureIntent.LongScreenshot, ScreenshotSelectionAction.LongScreenshot)]
    [InlineData(ScreenshotCaptureIntent.ScreenRecording, ScreenshotSelectionAction.ScreenRecording)]
    public void PreferredActionMatchesMacSelectionFlow(
        ScreenshotCaptureIntent intent,
        ScreenshotSelectionAction expected)
    {
        Assert.Equal(expected, intent.ActionAfterSelection());
    }
}
