using System;
using Polyglance.Platform.Interop;

namespace Polyglance.Platform.Pin;

public sealed record PinPlacement(
    double WindowLeftDips,
    double WindowTopDips,
    double WindowWidthDips,
    double WindowHeightDips,
    double ImageWidthDips,
    double ImageHeightDips
);

public static class PinPositioning
{
    public const double DefaultContentInset = 9.0;

    public static PinPlacement CalculatePlacement(
        int pixelWidth,
        int pixelHeight,
        int cursorPhysicalX,
        int cursorPhysicalY,
        int workAreaPhysicalX,
        int workAreaPhysicalY,
        int workAreaPhysicalWidth,
        int workAreaPhysicalHeight,
        double dpiScale,
        double contentInsetDips = DefaultContentInset)
    {
        double effectiveDpi = Math.Max(0.1, dpiScale);

        // Convert physical work area and cursor to DIPs for WPF
        double workAreaDipsX = workAreaPhysicalX / effectiveDpi;
        double workAreaDipsY = workAreaPhysicalY / effectiveDpi;
        double workAreaDipsWidth = workAreaPhysicalWidth / effectiveDpi;
        double workAreaDipsHeight = workAreaPhysicalHeight / effectiveDpi;

        double cursorDipsX = cursorPhysicalX / effectiveDpi;
        double cursorDipsY = cursorPhysicalY / effectiveDpi;

        // Available DIP space for the image within this monitor's working area
        double maxImageWidthDips = Math.Max(1.0, workAreaDipsWidth - 2 * contentInsetDips);
        double maxImageHeightDips = Math.Max(1.0, workAreaDipsHeight - 2 * contentInsetDips);

        // Scale proportionally if image exceeds available working area; otherwise keep 1:1 DIP
        double scale = Math.Min(1.0, Math.Min(
            maxImageWidthDips / Math.Max(1.0, pixelWidth),
            maxImageHeightDips / Math.Max(1.0, pixelHeight)));

        double imageWidthDips = Math.Max(1.0, pixelWidth * scale);
        double imageHeightDips = Math.Max(1.0, pixelHeight * scale);

        double windowWidthDips = imageWidthDips + 2 * contentInsetDips;
        double windowHeightDips = imageHeightDips + 2 * contentInsetDips;

        // Center window on cursor in DIPs
        double windowLeftDips = cursorDipsX - windowWidthDips / 2.0;
        double windowTopDips = cursorDipsY - windowHeightDips / 2.0;

        // Clamp inside working area
        if (windowWidthDips <= workAreaDipsWidth)
        {
            windowLeftDips = Math.Max(workAreaDipsX, Math.Min(workAreaDipsX + workAreaDipsWidth - windowWidthDips, windowLeftDips));
        }
        else
        {
            windowLeftDips = workAreaDipsX;
        }

        if (windowHeightDips <= workAreaDipsHeight)
        {
            windowTopDips = Math.Max(workAreaDipsY, Math.Min(workAreaDipsY + workAreaDipsHeight - windowHeightDips, windowTopDips));
        }
        else
        {
            windowTopDips = workAreaDipsY;
        }

        return new PinPlacement(
            WindowLeftDips: windowLeftDips,
            WindowTopDips: windowTopDips,
            WindowWidthDips: windowWidthDips,
            WindowHeightDips: windowHeightDips,
            ImageWidthDips: imageWidthDips,
            ImageHeightDips: imageHeightDips
        );
    }

    public static double GetDpiScaleForPoint(int x, int y)
    {
        try
        {
            var pt = new NativeWin32.POINT { X = x, Y = y };
            IntPtr hMon = NativeWin32.MonitorFromPoint(pt, NativeWin32.MONITOR_DEFAULTTONEAREST);
            if (hMon != IntPtr.Zero && NativeWin32.GetDpiForMonitor(hMon, NativeWin32.MDT_EFFECTIVE_DPI, out uint dpiX, out _) == 0)
            {
                if (dpiX > 0)
                {
                    return dpiX / 96.0;
                }
            }
        }
        catch { }

        return 1.0;
    }

    public static PinPlacement CalculatePlacementForCursor(
        int pixelWidth,
        int pixelHeight,
        double contentInsetDips = DefaultContentInset)
    {
        var cursor = System.Windows.Forms.Cursor.Position;
        var screen = System.Windows.Forms.Screen.FromPoint(cursor);
        double dpi = GetDpiScaleForPoint(cursor.X, cursor.Y);

        return CalculatePlacement(
            pixelWidth,
            pixelHeight,
            cursor.X,
            cursor.Y,
            screen.WorkingArea.X,
            screen.WorkingArea.Y,
            screen.WorkingArea.Width,
            screen.WorkingArea.Height,
            dpi,
            contentInsetDips);
    }
}
