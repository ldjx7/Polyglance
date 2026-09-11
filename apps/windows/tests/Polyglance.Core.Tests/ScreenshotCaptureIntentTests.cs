using Polyglance.Core.Models;

namespace Polyglance.Core.Tests;

public sealed class ScreenshotCaptureIntentTests
{
    [Theory]
    [InlineData(ScreenshotCaptureIntent.Standard, ScreenshotSelectionAction.None)]
    [InlineData(ScreenshotCaptureIntent.ScreenshotAndCopy, ScreenshotSelectionAction.Copy)]
    [InlineData(ScreenshotCaptureIntent.ScreenTranslation, ScreenshotSelectionAction.ScreenTranslation)]
    [InlineData(ScreenshotCaptureIntent.LongScreenshot, ScreenshotSelectionAction.LongScreenshot)]
    [InlineData(ScreenshotCaptureIntent.ScreenRecording, ScreenshotSelectionAction.ScreenRecording)]
    [InlineData(ScreenshotCaptureIntent.OcrTranslate, ScreenshotSelectionAction.OcrTranslate)]
    [InlineData(ScreenshotCaptureIntent.OcrWorkspace, ScreenshotSelectionAction.OcrWorkspace)]
    [InlineData(ScreenshotCaptureIntent.OcrTranslationCard, ScreenshotSelectionAction.OcrTranslationCard)]
    public void PreferredActionMatchesMacSelectionFlow(
        ScreenshotCaptureIntent intent,
        ScreenshotSelectionAction expected)
    {
        Assert.Equal(expected, intent.ActionAfterSelection());
    }
}
