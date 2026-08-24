using System.Windows;
using System.Windows.Media;

namespace Polyglance.Platform.Recording;

public static class ScreenRecordingCaptureGeometry
{
    public static Int32Rect ToPhysicalRegion(
        Point screenOriginInPixels,
        Rect localRegionInDips,
        Matrix transformToDevice)
    {
        var topLeft = transformToDevice.Transform(localRegionInDips.TopLeft);
        var bottomRight = transformToDevice.Transform(localRegionInDips.BottomRight);
        var left = (int)Math.Floor(screenOriginInPixels.X + Math.Min(topLeft.X, bottomRight.X));
        var top = (int)Math.Floor(screenOriginInPixels.Y + Math.Min(topLeft.Y, bottomRight.Y));
        var right = (int)Math.Ceiling(screenOriginInPixels.X + Math.Max(topLeft.X, bottomRight.X));
        var bottom = (int)Math.Ceiling(screenOriginInPixels.Y + Math.Max(topLeft.Y, bottomRight.Y));
        return new Int32Rect(left, top, Math.Max(1, right - left), Math.Max(1, bottom - top));
    }
}
