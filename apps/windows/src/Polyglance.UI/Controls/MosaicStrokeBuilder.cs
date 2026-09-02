using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Polyglance.UI.Controls;

internal static class MosaicStrokeBuilder
{
    internal static IEnumerable<Point> Interpolate(Point from, Point to, double spacing)
    {
        Vector delta = to - from;
        double distance = delta.Length;
        double safeSpacing = Math.Max(1, spacing);
        int steps = Math.Max(1, (int)Math.Ceiling(distance / safeSpacing));
        for (int index = 1; index <= steps; index++)
        {
            double progress = (double)index / steps;
            yield return from + delta * progress;
        }
    }

    internal static Canvas Begin(
        BitmapSource source,
        Size viewSize,
        Point point,
        double diameter,
        bool isBlur = false)
    {
        var stroke = new Canvas
        {
            Width = viewSize.Width,
            Height = viewSize.Height,
            IsHitTestVisible = false
        };
        AddStamp(stroke, source, viewSize, point, diameter, isBlur);
        return stroke;
    }

    internal static void AddStamp(
        Canvas stroke,
        BitmapSource source,
        Size viewSize,
        Point point,
        double diameter,
        bool isBlur = false)
    {
        if (viewSize.Width <= 0 || viewSize.Height <= 0 ||
            source.PixelWidth <= 0 || source.PixelHeight <= 0)
            return;

        double scaleX = source.PixelWidth / viewSize.Width;
        double scaleY = source.PixelHeight / viewSize.Height;
        int centerX = Math.Clamp((int)Math.Floor(point.X * scaleX), 0, source.PixelWidth - 1);
        int centerY = Math.Clamp((int)Math.Floor(point.Y * scaleY), 0, source.PixelHeight - 1);
        int radiusX = Math.Max(1, (int)Math.Ceiling(diameter * scaleX / 2));
        int radiusY = Math.Max(1, (int)Math.Ceiling(diameter * scaleY / 2));
        int left = Math.Max(0, centerX - radiusX);
        int top = Math.Max(0, centerY - radiusY);
        int right = Math.Min(source.PixelWidth, centerX + radiusX);
        int bottom = Math.Min(source.PixelHeight, centerY + radiusY);
        if (right <= left || bottom <= top)
            return;

        var crop = new CroppedBitmap(source, new Int32Rect(left, top, right - left, bottom - top));
        int coarseWidth = isBlur ? Math.Max(2, crop.PixelWidth / 12) : Math.Max(1, Math.Min(6, crop.PixelWidth));
        int coarseHeight = isBlur ? Math.Max(2, crop.PixelHeight / 12) : Math.Max(1, Math.Min(6, crop.PixelHeight));
        var pixelated = new TransformedBitmap(
            crop,
            new ScaleTransform(
                (double)coarseWidth / crop.PixelWidth,
                (double)coarseHeight / crop.PixelHeight));
        pixelated.Freeze();

        var image = new System.Windows.Controls.Image
        {
            Source = pixelated,
            Width = diameter,
            Height = diameter,
            Stretch = Stretch.Fill,
            Clip = new EllipseGeometry(new Point(diameter / 2, diameter / 2), diameter / 2, diameter / 2),
            IsHitTestVisible = false
        };
        RenderOptions.SetBitmapScalingMode(image, isBlur ? BitmapScalingMode.Linear : BitmapScalingMode.NearestNeighbor);
        Canvas.SetLeft(image, point.X - diameter / 2);
        Canvas.SetTop(image, point.Y - diameter / 2);
        stroke.Children.Add(image);
    }

    internal static System.Windows.Controls.Image CreateRectMosaic(
        BitmapSource source,
        Size viewSize,
        Rect rect,
        double blockSize,
        bool isBlur = false)
    {
        if (viewSize.Width <= 0 || viewSize.Height <= 0 ||
            source.PixelWidth <= 0 || source.PixelHeight <= 0 ||
            rect.Width < 1 || rect.Height < 1)
        {
            return new System.Windows.Controls.Image { Width = 0, Height = 0 };
        }

        double scaleX = source.PixelWidth / viewSize.Width;
        double scaleY = source.PixelHeight / viewSize.Height;
        int left = Math.Clamp((int)Math.Floor(rect.Left * scaleX), 0, source.PixelWidth - 1);
        int top = Math.Clamp((int)Math.Floor(rect.Top * scaleY), 0, source.PixelHeight - 1);
        int right = Math.Clamp((int)Math.Ceiling(rect.Right * scaleX), left + 1, source.PixelWidth);
        int bottom = Math.Clamp((int)Math.Ceiling(rect.Bottom * scaleY), top + 1, source.PixelHeight);

        var crop = new CroppedBitmap(source, new Int32Rect(left, top, right - left, bottom - top));
        int coarseWidth = isBlur ? Math.Max(2, (int)Math.Ceiling((right - left) / (blockSize * 2))) : Math.Max(1, (int)Math.Ceiling((right - left) / blockSize));
        int coarseHeight = isBlur ? Math.Max(2, (int)Math.Ceiling((bottom - top) / (blockSize * 2))) : Math.Max(1, (int)Math.Ceiling((bottom - top) / blockSize));
        var pixelated = new TransformedBitmap(
            crop,
            new ScaleTransform(
                (double)coarseWidth / crop.PixelWidth,
                (double)coarseHeight / crop.PixelHeight));
        pixelated.Freeze();

        var image = new System.Windows.Controls.Image
        {
            Source = pixelated,
            Width = rect.Width,
            Height = rect.Height,
            Stretch = Stretch.Fill,
            IsHitTestVisible = false
        };
        RenderOptions.SetBitmapScalingMode(image, isBlur ? BitmapScalingMode.Linear : BitmapScalingMode.NearestNeighbor);
        Canvas.SetLeft(image, rect.Left);
        Canvas.SetTop(image, rect.Top);
        return image;
    }
}
