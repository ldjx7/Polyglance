using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Polyglance.UI.Controls;

public partial class MagnifierControl : UserControl
{
    public MagnifierControl()
    {
        InitializeComponent();
    }

    public void Update(BitmapSource fullImage, Point screenPoint, int pixelX, int pixelY)
    {
        const int sampleRadius = 10;
        int srcX = Math.Max(0, pixelX - sampleRadius);
        int srcY = Math.Max(0, pixelY - sampleRadius);
        int width = Math.Min(sampleRadius * 2 + 1, fullImage.PixelWidth - srcX);
        int height = Math.Min(sampleRadius * 2 + 1, fullImage.PixelHeight - srcY);

        if (width > 0 && height > 0)
        {
            var cropped = new CroppedBitmap(fullImage, new Int32Rect(srcX, srcY, width, height));
            MagnifierImage.Source = cropped;

            // 获取中心像素色值
            int targetX = Math.Clamp(pixelX, 0, fullImage.PixelWidth - 1);
            int targetY = Math.Clamp(pixelY, 0, fullImage.PixelHeight - 1);
            var singlePixel = new CroppedBitmap(fullImage, new Int32Rect(targetX, targetY, 1, 1));
            byte[] pixels = new byte[4];
            singlePixel.CopyPixels(pixels, 4, 0);

            byte b = pixels[0];
            byte g = pixels[1];
            byte r = pixels[2];

            TxtHexColor.Text = $"#{r:X2}{g:X2}{b:X2}";
            TxtRgbColor.Text = $"RGB({r}, {g}, {b})";
            ColorPreviewBox.Background = new SolidColorBrush(Color.FromRgb(r, g, b));
        }
    }
}
