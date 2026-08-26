using System;
using System.Windows;

namespace Polyglance.Platform.Capture;

/// <summary>
/// Converts overlay selections into pixel indices of the captured bitmap.
///
/// A capture overlay straddles two coordinate spaces. WPF input and layout are
/// device-independent pixels (DIPs): everything the user drags, and every mask,
/// border and toolbar placed in response, lives there. The captured bitmap is
/// raw desktop pixels from BitBlt over the virtual screen, so indexing into it
/// requires physical pixels. The two are equal only at 100% scaling, which is
/// why confusing them stays invisible on a typical development machine and
/// misplaces the crop on any scaled display.
///
/// The scale is derived from the bitmap and view extents rather than from a DPI
/// matrix, mirroring capture-core's <c>pixel_crop_rect</c>. Because the overlay
/// draws its background with <c>Stretch="Fill"</c>, the bitmap covers exactly
/// the view extent, so their ratio is the true mapping however Windows arrived
/// at the scale factor — per-monitor DPI, system DPI virtualization or RDP.
/// Unlike macOS, Windows bitmaps are top-left origin, so there is no Y flip.
/// </summary>
public static class CaptureRegionGeometry
{
    /// <summary>
    /// Maps a selection in overlay-local DIPs onto pixel indices of the captured
    /// bitmap. The selection is clipped to the view, scaled, then rounded
    /// outward so a fractional selection never drops edge content.
    /// </summary>
    public static Int32Rect ToBitmapRegion(
        Rect regionInDips,
        Size viewSizeInDips,
        int bitmapPixelWidth,
        int bitmapPixelHeight)
    {
        if (viewSizeInDips.Width <= 0
            || viewSizeInDips.Height <= 0
            || bitmapPixelWidth <= 0
            || bitmapPixelHeight <= 0
            || regionInDips.IsEmpty)
        {
            return Int32Rect.Empty;
        }

        Rect clipped = Rect.Intersect(
            regionInDips,
            new Rect(0, 0, viewSizeInDips.Width, viewSizeInDips.Height));
        if (clipped.IsEmpty || clipped.Width <= 0 || clipped.Height <= 0)
        {
            return Int32Rect.Empty;
        }

        double scaleX = bitmapPixelWidth / viewSizeInDips.Width;
        double scaleY = bitmapPixelHeight / viewSizeInDips.Height;

        int left = (int)Math.Floor(clipped.Left * scaleX);
        int top = (int)Math.Floor(clipped.Top * scaleY);
        int right = (int)Math.Ceiling(clipped.Right * scaleX);
        int bottom = (int)Math.Ceiling(clipped.Bottom * scaleY);

        left = Math.Clamp(left, 0, bitmapPixelWidth);
        top = Math.Clamp(top, 0, bitmapPixelHeight);
        right = Math.Clamp(right, 0, bitmapPixelWidth);
        bottom = Math.Clamp(bottom, 0, bitmapPixelHeight);

        if (right <= left || bottom <= top)
        {
            return Int32Rect.Empty;
        }

        return new Int32Rect(left, top, right - left, bottom - top);
    }

    /// <summary>
    /// Maps one pointer position in overlay-local DIPs onto the bitmap pixel
    /// underneath it, clamped to the bitmap. Used by the magnifier so the
    /// sampled colour is the pixel the crosshair actually sits on.
    /// </summary>
    public static (int X, int Y) ToBitmapPoint(
        Point pointInDips,
        Size viewSizeInDips,
        int bitmapPixelWidth,
        int bitmapPixelHeight)
    {
        if (viewSizeInDips.Width <= 0
            || viewSizeInDips.Height <= 0
            || bitmapPixelWidth <= 0
            || bitmapPixelHeight <= 0)
        {
            return (0, 0);
        }

        double scaleX = bitmapPixelWidth / viewSizeInDips.Width;
        double scaleY = bitmapPixelHeight / viewSizeInDips.Height;

        int x = (int)Math.Floor(pointInDips.X * scaleX);
        int y = (int)Math.Floor(pointInDips.Y * scaleY);

        return (
            Math.Clamp(x, 0, bitmapPixelWidth - 1),
            Math.Clamp(y, 0, bitmapPixelHeight - 1));
    }
}
