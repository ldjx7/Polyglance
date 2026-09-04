using System;
using System.Linq;
using System.Runtime.ExceptionServices;
using System.Threading;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.UI.Controls;
using Polyglance.UI.Views;

namespace Polyglance.UI.Tests;

public sealed class AnnotationInteractionTests
{
    [Fact]
    public void TranslateButtonRaisesTheOcrTranslateAction()
    {
        RunInSta(() =>
        {
            var toolbar = new ScreenshotToolbar();
            string? selectedAction = null;
            toolbar.ActionTriggered += action => selectedAction = action;

            toolbar.BtnTranslate.RaiseEvent(
                new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));

            Assert.Equal("OCRTranslate", selectedAction);
        });
    }

    [Fact]
    public void ToolbarDragDeltaUsesDeviceIndependentPositions()
    {
        Vector delta = ScreenshotToolbar.CalculateDragDelta(
            new Point(120, 80),
            new Point(185, 112));

        Assert.Equal(new Vector(65, 32), delta);
    }

    [Fact]
    public void OcrTranslationBusyStateProvidesImmediateVisibleFeedback()
    {
        RunInSta(() =>
        {
            var toolbar = new ScreenshotToolbar();

            toolbar.SetOcrTranslationBusy(true);

            Assert.True(toolbar.IsOcrTranslationBusy);
            Assert.False(toolbar.BtnTranslate.IsEnabled);
            Assert.Equal("正在识别并翻译…", toolbar.BtnTranslate.ToolTip);

            toolbar.SetOcrTranslationBusy(false);

            Assert.False(toolbar.IsOcrTranslationBusy);
            Assert.True(toolbar.BtnTranslate.IsEnabled);
            Assert.Equal("识别并翻译", toolbar.BtnTranslate.ToolTip);
        });
    }

    [Fact]
    public void SelectingAMarkupToolDoesNotHideScreenshotActions()
    {
        RunInSta(() =>
        {
            var toolbar = new ScreenshotToolbar();

            toolbar.SetAnnotationMode(true);

            Assert.True(toolbar.AreScreenshotActionsVisible);
            Assert.False(toolbar.IsFinishActionVisible);
        });
    }

    [Fact]
    public void SelectingToolDoesNotShiftMainToolbar()
    {
        RunInSta(() =>
        {
            var window = CreateSelectionWindow(1920, 1080);
            window.Width = 1000;
            window.Height = 800;
            window.Show();
            window.UpdateLayout();

            var tb = (ScreenshotToolbar)window.FindName("Toolbar");
            var mainBorder = (System.Windows.Controls.Border)tb.FindName("MainToolbarBorder");
            var subBorder = (System.Windows.Controls.Border)tb.FindName("SubToolbarBorder");

            // Case 1: Below
            window.SetSelectionForTesting(new Rect(100, 100, 600, 300));
            window.UpdateLayout();
            Point ptBelowBefore = mainBorder.TranslatePoint(new Point(0, 0), window);
            tb.BtnPen.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            window.UpdateLayout();
            Point ptBelowAfter = mainBorder.TranslatePoint(new Point(0, 0), window);
            Assert.Equal(ptBelowBefore.X, ptBelowAfter.X, 1);
            Assert.Equal(ptBelowBefore.Y, ptBelowAfter.Y, 1);

            // Case 2: Above
            window.ClearSelectedToolForTesting();
            window.SetSelectionForTesting(new Rect(100, 450, 600, 300));
            window.UpdateLayout();
            Point ptAboveBefore = mainBorder.TranslatePoint(new Point(0, 0), window);
            tb.BtnPen.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            window.UpdateLayout();
            Point ptPenAbove = mainBorder.TranslatePoint(new Point(0, 0), window);
            Assert.Equal(ptAboveBefore.X, ptPenAbove.X, 1);
            Assert.Equal(ptAboveBefore.Y, ptPenAbove.Y, 1);

            // Click Text
            tb.BtnText.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            window.UpdateLayout();
            Point ptTextAbove = mainBorder.TranslatePoint(new Point(0, 0), window);
            Assert.Equal(ptAboveBefore.X, ptTextAbove.X, 1);
            Assert.Equal(ptAboveBefore.Y, ptTextAbove.Y, 1);

            // Click Rect
            tb.BtnRect.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            window.UpdateLayout();
            Point ptRectAbove = mainBorder.TranslatePoint(new Point(0, 0), window);
            Assert.Equal(ptAboveBefore.X, ptRectAbove.X, 1);
            Assert.Equal(ptAboveBefore.Y, ptRectAbove.Y, 1);

            // Click Number
            tb.BtnNumber.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            window.UpdateLayout();
            Point ptNumberAbove = mainBorder.TranslatePoint(new Point(0, 0), window);
            Assert.Equal(ptAboveBefore.X, ptNumberAbove.X, 1);
            Assert.Equal(ptAboveBefore.Y, ptNumberAbove.Y, 1);

            // Click Mosaic
            tb.BtnMosaic.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            window.UpdateLayout();
            Point ptMosaicAbove = mainBorder.TranslatePoint(new Point(0, 0), window);
            Assert.Equal(ptAboveBefore.X, ptMosaicAbove.X, 1);
            Assert.Equal(ptAboveBefore.Y, ptMosaicAbove.Y, 1);

            window.Close();
        });
    }

    [Fact]
    public void ClickingSelectedToolTogglesItOffAndCollapsesSubToolbar()
    {
        RunInSta(() =>
        {
            var toolbar = new ScreenshotToolbar();
            string selectedTool = "";
            toolbar.ToolSelected += t => selectedTool = t;

            // Click Pen to select
            toolbar.BtnPen.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            Assert.Equal("Pen", selectedTool);
            Assert.Equal(Visibility.Visible, toolbar.SubToolbarBorder.Visibility);

            // Click Pen again to deselect
            toolbar.BtnPen.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            Assert.Equal("None", selectedTool);
            Assert.Equal(Visibility.Collapsed, toolbar.SubToolbarBorder.Visibility);
        });
    }

    [Fact]
    public void LineToolCanBeSelectedOnToolbar()
    {
        RunInSta(() =>
        {
            var toolbar = new ScreenshotToolbar();
            string selectedTool = "";
            toolbar.ToolSelected += t => selectedTool = t;

            toolbar.BtnLine.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            Assert.Equal("Line", selectedTool);
            Assert.Equal(Visibility.Visible, toolbar.SubToolbarBorder.Visibility);
        });
    }

    [Fact]
    public void AnnotationModeKeepsBlueSelectionHandlesAndUsesCrosshairAwayFromEdges()
    {
        RunInSta(() =>
        {
            var window = CreateSelectionWindow();
            window.Show();
            window.SetSelectionForTesting(new Rect(20, 20, 120, 80));

            window.SelectAnnotationToolForTesting("Pen");
            window.UpdatePointerForTesting(new Point(80, 60));

            Assert.True(window.AreSelectionHandlesVisible);
            Assert.Equal(Cursors.Cross, window.Cursor);
            window.Close();
        });
    }

    [Fact]
    public void AnnotationModeAllowsEdgeResizeWhileKeepingExistingMarks()
    {
        RunInSta(() =>
        {
            var window = CreateSelectionWindow();
            window.Show();
            window.SetSelectionForTesting(new Rect(20, 20, 120, 80));
            window.SelectAnnotationToolForTesting("Pen");
            window.AddRectangleAnnotationForTesting(
                new Rect(40, 35, 50, 30),
                Color.FromRgb(0xEF, 0x44, 0x44));

            Assert.True(window.BeginSelectionEditForTesting(new Point(140, 60)));
            window.ContinueSelectionEditForTesting(new Point(180, 60));
            window.EndSelectionEditForTesting();

            Assert.Equal(new Rect(20, 20, 160, 80), window.SelectionRectForTesting);
            Assert.Equal(1, window.AnnotationCountForTesting);
            window.Close();
        });
    }

    [Fact]
    public void RenderedPinBitmapContainsTheAnnotationLayer()
    {
        RunInSta(() =>
        {
            var window = CreateSelectionWindow();
            window.Show();
            window.SetSelectionForTesting(new Rect(20, 20, 120, 80));
            window.AddRectangleAnnotationForTesting(
                new Rect(40, 35, 50, 30),
                Color.FromRgb(0xEF, 0x44, 0x44));

            BitmapSource output = Assert.IsAssignableFrom<BitmapSource>(window.RenderedSelectionForTesting());

            Assert.True(ContainsRedPixel(output), "Pinned/copy/save output must contain the annotation visual");
            window.Close();
        });
    }

    [Fact]
    public void SelectionCrossingOverlayEdgesIsClampedBeforeRendering()
    {
        RunInSta(() =>
        {
            var window = CreateSelectionWindow();
            window.Show();

            window.SetSelectionForTesting(new Rect(-12, -8, 228, 164));

            Assert.Equal(new Rect(0, 0, 200, 140), window.SelectionRectForTesting);
            BitmapSource output = Assert.IsAssignableFrom<BitmapSource>(window.RenderedSelectionForTesting());
            Assert.Equal(200, output.PixelWidth);
            Assert.Equal(140, output.PixelHeight);
            window.Close();
        });
    }

    [Fact]
    public void MosaicStrokeInterpolatesAContinuousPathAsOneGesture()
    {
        Point[] points = MosaicStrokeBuilder.Interpolate(
            new Point(0, 0),
            new Point(30, 0),
            6).ToArray();

        Assert.Equal(new Point(6, 0), points[0]);
        Assert.Equal(new Point(30, 0), points[^1]);
        Assert.True(points.Length >= 5);
        Assert.All(points.Zip(points.Skip(1)), pair =>
            Assert.InRange((pair.Second - pair.First).Length, 0, 6.01));
    }

    [Fact]
    public void MosaicStrokeAlwaysIncludesShortDragEndpoint()
    {
        Point[] points = MosaicStrokeBuilder.Interpolate(
            new Point(4, 8),
            new Point(6, 9),
            6).ToArray();

        Assert.Single(points);
        Assert.Equal(new Point(6, 9), points[0]);
    }

    [Fact]
    public void OcrSelectionStartsAsAQuietImagePinAndEscapeExitsSelectionBeforeClosing()
    {
        RunInSta(() =>
        {
            var bitmap = BitmapSource.Create(
                80, 40, 96, 96, PixelFormats.Bgra32, null, new byte[80 * 40 * 4], 80 * 4);
            var document = new OcrTextDocument([
                new LayoutTextLine
                {
                    Text = "Hello",
                    X = 4,
                    Y = 4,
                    Width = 40,
                    Height = 18,
                    Words = [new LayoutTextWord
                    {
                        Text = "Hello",
                        X = 4,
                        Y = 4,
                        Width = 40,
                        Height = 18
                    }]
                }
            ]);
            var window = new OcrSelectionWindow(bitmap, document, null, null);
            window.Show();

            Assert.Equal(WindowStyle.None, window.WindowStyle);
            Assert.True(window.IsSelectionEnabled);
            Assert.False(window.AreContextualActionsVisible);

            window.ExitSelectionOrClose();

            Assert.False(window.IsSelectionEnabled);
            Assert.True(window.IsVisible);
            window.Close();
        });
    }

    private static void RunInSta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                action();
            }
            catch (Exception exception)
            {
                failure = exception;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null)
            ExceptionDispatchInfo.Capture(failure).Throw();
    }

    private static ScreenSelectionWindow CreateSelectionWindow(int width = 200, int height = 140)
    {
        byte[] pixels = new byte[width * height * 4];
        for (int offset = 0; offset < pixels.Length; offset += 4)
        {
            pixels[offset] = 0xFF;
            pixels[offset + 1] = 0xFF;
            pixels[offset + 2] = 0xFF;
            pixels[offset + 3] = 0xFF;
        }
        BitmapSource bitmap = BitmapSource.Create(
            width, height, 96, 96, PixelFormats.Bgra32, null, pixels, width * 4);
        return new ScreenSelectionWindow(
            bitmap,
            new Rect(0, 0, width, height),
            null!,
            new AppConfiguration());
    }

    private static bool ContainsRedPixel(BitmapSource image)
    {
        var converted = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0);
        int stride = converted.PixelWidth * 4;
        byte[] pixels = new byte[stride * converted.PixelHeight];
        converted.CopyPixels(pixels, stride, 0);
        for (int offset = 0; offset < pixels.Length; offset += 4)
        {
            byte blue = pixels[offset];
            byte green = pixels[offset + 1];
            byte red = pixels[offset + 2];
            if (red > 180 && green < 130 && blue < 130)
                return true;
        }
        return false;
    }
}
