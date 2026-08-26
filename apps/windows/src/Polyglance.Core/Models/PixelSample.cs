namespace Polyglance.Core.Models;

public enum ColorDisplayFormat
{
    Hex,
    Rgb
}

public static class ColorDisplayFormatExtensions
{
    public static ColorDisplayFormat Toggled(this ColorDisplayFormat format) =>
        format == ColorDisplayFormat.Hex ? ColorDisplayFormat.Rgb : ColorDisplayFormat.Hex;
}

/// <summary>
/// A single sampled screen pixel and its physical image coordinate. Mirrors the
/// macOS PixelSample so both platforms format and copy colours identically.
/// </summary>
public readonly record struct PixelSample(int X, int Y, byte Red, byte Green, byte Blue)
{
    public string Hex => $"#{Red:X2}{Green:X2}{Blue:X2}";

    public string Rgb => $"RGB({Red}, {Green}, {Blue})";

    public string Text(ColorDisplayFormat format) =>
        format == ColorDisplayFormat.Hex ? Hex : Rgb;

    public string CoordinateText => $"({X}, {Y}) px";
}
