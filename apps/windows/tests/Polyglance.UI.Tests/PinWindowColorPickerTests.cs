using System;
using System.Runtime.ExceptionServices;
using System.Threading;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Polyglance.Core.Models;
using Polyglance.UI.Views;

namespace Polyglance.UI.Tests;

public sealed class PinWindowColorPickerTests
{
    [Fact]
    public void ContextMenuColorPickerCopiesPixelsAndKeepsPinOpen()
    {
        RunInSta(() =>
        {
            BitmapSource image = CreateSolidBitmap(200, 120, 0x12, 0x34, 0x56);
            string? copied = null;
            var pin = new PinWindow(image, null, null, value => copied = value);
            pin.Show();

            Assert.Equal("取色", pin.ColorPickerMenuHeader);
            pin.ToggleColorPicking();
            Assert.True(pin.IsColorPicking);
            Assert.Equal("退出取色", pin.ColorPickerMenuHeader);

            pin.UpdateColorAt(new Point(100, 60));
            Assert.Equal("#123456", pin.ColorMagnifierControl.CurrentSample?.Hex);
            Assert.True(pin.HandleColorShortcut(Key.C, ModifierKeys.None));
            Assert.Equal("#123456", copied);
            Assert.True(pin.IsVisible);

            Assert.True(pin.HandleColorShortcut(Key.C, ModifierKeys.Shift));
            Assert.Equal(ColorDisplayFormat.Rgb, pin.ColorMagnifierControl.DisplayFormat);
            Assert.False(pin.HandleColorShortcut(Key.C, ModifierKeys.Control));

            pin.ToggleColorPicking();
            Assert.False(pin.IsColorPicking);
            pin.Close();
        });
    }

    [Fact]
    public void PinCanEnterAndLeaveAnnotationModeWithoutOpeningAnotherWindow()
    {
        RunInSta(() =>
        {
            var pin = new PinWindow(CreateSolidBitmap(80, 60, 0x12, 0x34, 0x56));
            pin.Show();

            pin.ToggleAnnotationEditing();
            Assert.True(pin.IsAnnotationEditing);
            Assert.Equal(Visibility.Visible, pin.AnnotationTools.Visibility);

            pin.ToggleAnnotationEditing();
            Assert.False(pin.IsAnnotationEditing);
            Assert.Equal(Visibility.Collapsed, pin.AnnotationTools.Visibility);
            pin.Close();
        });
    }

    private static BitmapSource CreateSolidBitmap(
        int width,
        int height,
        byte red,
        byte green,
        byte blue)
    {
        byte[] pixels = new byte[width * height * 4];
        for (int offset = 0; offset < pixels.Length; offset += 4)
        {
            pixels[offset] = blue;
            pixels[offset + 1] = green;
            pixels[offset + 2] = red;
            pixels[offset + 3] = 0xFF;
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
}
