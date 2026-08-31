using System;
using System.Runtime.ExceptionServices;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Input;
using System.Windows.Threading;
using Polyglance.Core.Models;
using Polyglance.UI.Controls;
using Polyglance.UI.Views;

namespace Polyglance.UI.Tests;

public sealed class MagnifierWindowTests
{
    [Fact]
    public void WindowHostedMagnifierKeepsEdgeSampleUnderCenterCrosshair()
    {
        RunInSta(() =>
        {
            var magnifier = new MagnifierControl();
            var window = new Window { Content = magnifier, Width = 200, Height = 220 };
            window.Measure(new Size(200, 220));
            window.Arrange(new Rect(0, 0, 200, 220));

            BitmapSource source = CreateBitmap(3, 3, (x, y) =>
                x == 0 && y == 0
                    ? ((byte)0x12, (byte)0x34, (byte)0x56)
                    : ((byte)0xEE, (byte)0xEE, (byte)0xEE));
            magnifier.Update(source, 0, 0);

            BitmapSource preview = Assert.IsAssignableFrom<BitmapSource>(magnifier.PreviewSource);
            Assert.Equal(21, preview.PixelWidth);
            Assert.Equal(21, preview.PixelHeight);
            Assert.Equal((0x12, 0x34, 0x56), ReadRgb(preview, 10, 10));
            Assert.Equal("C 复制色值 · ⇧C 切换 HEX/RGB", magnifier.InstructionText);
        });
    }

    [Fact]
    public void ColourAndCoordinateEachGetTheirOwnUntruncatedLine()
    {
        RunInSta(() =>
        {
            var magnifier = new MagnifierControl();
            var window = new Window { Content = magnifier };
            window.Measure(new Size(300, 320));
            window.Arrange(new Rect(0, 0, 300, 320));

            // The widest readout the panel has to hold.
            BitmapSource source = CreateBitmap(1, 1, (_, _) => (0xFF, 0xFF, 0xFF));
            magnifier.Update(source, 0, 0);
            magnifier.ToggleDisplayFormat();

            Assert.Equal("RGB(255, 255, 255)", magnifier.ColorValueText);
            Assert.Equal("(0, 0) px", magnifier.CoordinateLabelText);

            // Each line must fit the panel's inner width on its own; sharing one
            // line is what clipped the value.
            double available = magnifier.Width - 16;
            Assert.True(
                magnifier.ColorValueWidth <= available,
                $"colour line {magnifier.ColorValueWidth} exceeds {available}");
            Assert.True(
                magnifier.CoordinateWidth <= available,
                $"coordinate line {magnifier.CoordinateWidth} exceeds {available}");
            Assert.True(magnifier.InstructionWraps);
        });
    }

    [Fact]
    public void WindowHostedMagnifierShowsAndRestoresCopyConfirmation()
    {
        RunInSta(() =>
        {
            var magnifier = new MagnifierControl
            {
                CopyFeedbackDuration = TimeSpan.FromMilliseconds(10)
            };
            var window = new Window { Content = magnifier };

            magnifier.ShowCopyConfirmation("#123456");
            Assert.Equal("已复制 #123456", magnifier.InstructionText);

            var frame = new DispatcherFrame();
            var timer = new DispatcherTimer(
                TimeSpan.FromMilliseconds(50),
                DispatcherPriority.Background,
                (_, _) => frame.Continue = false,
                Dispatcher.CurrentDispatcher);
            timer.Start();
            Dispatcher.PushFrame(frame);
            timer.Stop();

            Assert.Equal("C 复制色值 · ⇧C 切换 HEX/RGB", magnifier.InstructionText);
        });
    }

    [Fact]
    public void ScreenSelectionWindowRoutesPlainAndShiftCWithoutClosingCapture()
    {
        RunInSta(() =>
        {
            BitmapSource source = CreateBitmap(3, 3, (x, y) =>
                x == 1 && y == 1
                    ? ((byte)0x12, (byte)0x34, (byte)0x56)
                    : ((byte)0xEE, (byte)0xEE, (byte)0xEE));
            string? copied = null;
            var selection = new ScreenSelectionWindow(
                source,
                new Rect(0, 0, 3, 3),
                null!,
                new AppConfiguration(),
                ScreenshotCaptureIntent.Standard,
                value => copied = value);
            selection.ColorMagnifier.Visibility = Visibility.Visible;
            selection.ColorMagnifier.Update(source, 1, 1);
            selection.Show();
            Assert.True(selection.IsVisible);

            Assert.True(selection.HandleColorShortcut(Key.C, ModifierKeys.None));
            Assert.Equal("#123456", copied);
            Assert.Equal("已复制 #123456", selection.ColorMagnifier.InstructionText);
            Assert.True(selection.IsVisible);

            Assert.True(selection.HandleColorShortcut(Key.C, ModifierKeys.Shift));
            Assert.Equal(ColorDisplayFormat.Rgb, selection.ColorMagnifier.DisplayFormat);
            Assert.Equal("RGB(18, 52, 86)", selection.ColorMagnifier.CurrentSample?.Text(
                selection.ColorMagnifier.DisplayFormat));
            Assert.False(selection.HandleColorShortcut(Key.C, ModifierKeys.Control));
            selection.Close();
        });
    }

    private static BitmapSource CreateBitmap(
        int width,
        int height,
        Func<int, int, (byte Red, byte Green, byte Blue)> color)
    {
        byte[] pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                var value = color(x, y);
                int offset = (y * width + x) * 4;
                pixels[offset] = value.Blue;
                pixels[offset + 1] = value.Green;
                pixels[offset + 2] = value.Red;
                pixels[offset + 3] = 0xFF;
            }
        }

        return BitmapSource.Create(
            width,
            height,
            96,
            96,
            PixelFormats.Bgra32,
            null,
            pixels,
            width * 4);
    }

    private static (int Red, int Green, int Blue) ReadRgb(BitmapSource image, int x, int y)
    {
        byte[] pixel = new byte[4];
        image.CopyPixels(new Int32Rect(x, y, 1, 1), pixel, 4, 0);
        return (pixel[2], pixel[1], pixel[0]);
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
        {
            ExceptionDispatchInfo.Capture(failure).Throw();
        }
    }
}
