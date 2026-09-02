using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Runtime.ExceptionServices;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.UI.Views;

namespace Polyglance.UI.Tests;

public sealed class BarcodeResultWindowTests
{
    [Fact]
    public void MarkerCenterMapsNormalizedCoordinatesIntoTopLeftViewSpace()
    {
        var observation = new BarcodeObservation(
            "payload",
            BarcodeSymbology.Qr,
            new NativeRect(0.25, 0.6, 0.2, 0.2));

        var point = BarcodeResultWindow.MarkerCenter(observation, new Size(1000, 800));

        Assert.Equal(350, point.X, 3);
        Assert.Equal(240, point.Y, 3);
    }

    [Fact]
    public void MarkerUsesTheSharedLargerDiameter()
    {
        Assert.Equal(22, BarcodeResultWindow.MarkerDiameter);
        Assert.Equal(11, BarcodeResultWindow.MarkerCoreDiameter);
    }

    [Fact]
    public void DoubleClickClosesRecognitionOverlay()
    {
        RunInSta(() =>
        {
            var observations = new[]
            {
                new BarcodeObservation("payload", BarcodeSymbology.Qr, new NativeRect(0.2, 0.2, 0.2, 0.2))
            };
            var window = new BarcodeResultWindow(
                observations,
                CreateSolidBitmap(800, 600),
                new Rect(0, 0, 800, 600));

            window.Show();
            Assert.True(window.IsVisible);
            window.HandlePointerDoubleClick(MouseButton.Left);

            Assert.False(window.IsVisible);
        });
    }

    [Fact]
    public void MultipleResultHeaderUsesQrCodeWording()
    {
        var observations = new[]
        {
            new BarcodeObservation("first", BarcodeSymbology.Qr, new NativeRect(0.1, 0.6, 0.2, 0.2)),
            new BarcodeObservation("second", BarcodeSymbology.Qr, new NativeRect(0.6, 0.1, 0.2, 0.2))
        };

        Assert.Equal("识别到 2 个二维码", BarcodeResultWindow.HeaderTitle(observations));
    }

    [Fact]
    public void WifiContentUsesTheSystemWifiGlyphInsteadOfTheNetworkLabel()
    {
        RunInSta(() =>
        {
            var content = new BarcodeContent.Wifi("Polyglance-Test", "secret", "WPA");
            var panel = Assert.IsType<StackPanel>(BarcodeResultWindow.BuildContentView(content));
            var networkLine = Assert.IsType<StackPanel>(panel.Children[0]);
            var icon = Assert.IsType<TextBlock>(networkLine.Children[0]);
            var ssid = Assert.IsType<TextBlock>(networkLine.Children[1]);

            Assert.Equal("\uE701", icon.Text);
            Assert.Contains("Segoe MDL2 Assets", icon.FontFamily.Source);
            Assert.Equal("Polyglance-Test", ssid.Text);
        });
    }

    [Fact]
    public void DismissIsIdempotentSoCloseAndDeactivationCannotTerminateTheProcess()
    {
        RunInSta(() =>
        {
            var observations = new[]
            {
                new BarcodeObservation("payload", BarcodeSymbology.Qr, new NativeRect(0.2, 0.2, 0.2, 0.2))
            };
            var window = new BarcodeResultWindow(
                observations,
                CreateSolidBitmap(800, 600),
                new Rect(0, 0, 800, 600));

            window.Show();
            Assert.Equal(1, window.MarkerCount);
            window.Dismiss();
            window.Dismiss();

            Assert.False(window.IsVisible);
        });
    }

    [Fact]
    public void RecognitionOverlayUsesTheExactSelectionFrame()
    {
        RunInSta(() =>
        {
            var selectedFrame = new Rect(-900, 80, 740, 520);
            var observations = new[]
            {
                new BarcodeObservation("payload", BarcodeSymbology.Qr, new NativeRect(0.2, 0.2, 0.2, 0.2))
            };
            var window = new BarcodeResultWindow(
                observations,
                CreateSolidBitmap(740, 520),
                selectedFrame);

            Assert.Equal(selectedFrame.Left, window.Left);
            Assert.Equal(selectedFrame.Top, window.Top);
            Assert.Equal(selectedFrame.Width, window.Width);
            Assert.Equal(selectedFrame.Height, window.Height);
        });
    }

    private static BitmapSource CreateSolidBitmap(int width, int height)
    {
        var pixels = new byte[width * height * 4];
        Array.Fill<byte>(pixels, 0xFF);
        var bitmap = BitmapSource.Create(
            width,
            height,
            96,
            96,
            PixelFormats.Bgra32,
            null,
            pixels,
            width * 4);
        bitmap.Freeze();
        return bitmap;
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
