using System.Windows;
using System.Windows.Media;

namespace Polyglance.Platform.Dpi;

public static class DpiHelper
{
    public static Point TransformToPixels(Visual visual, Point dipPoint)
    {
        var transform = PresentationSource.FromVisual(visual)?.CompositionTarget?.TransformToDevice;
        if (transform.HasValue)
        {
            return transform.Value.Transform(dipPoint);
        }
        return dipPoint;
    }

    public static Point TransformFromPixels(Visual visual, Point pixelPoint)
    {
        var transform = PresentationSource.FromVisual(visual)?.CompositionTarget?.TransformFromDevice;
        if (transform.HasValue)
        {
            return transform.Value.Transform(pixelPoint);
        }
        return pixelPoint;
    }
}
