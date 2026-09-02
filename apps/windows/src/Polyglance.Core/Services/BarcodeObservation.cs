using Polyglance.Core.Models;

namespace Polyglance.Core.Services;

/// <summary>
/// One barcode detected in a screenshot.
/// </summary>
/// <remarks>
/// <see cref="BoundingBox"/> is normalized to 0...1 with the origin at the
/// lower left — the project's shared convention, matching the macOS Vision
/// backend. The ZXing reader flips its top-left pixel corners into this space
/// so both platforms hand the UI the same shape.
/// </remarks>
public sealed record BarcodeObservation(
    string Payload,
    BarcodeSymbology Symbology,
    NativeRect BoundingBox,
    IReadOnlyList<NativePoint>? Corners = null)
{
    public BarcodeContent Content => BarcodeContent.From(Payload);
}

public enum BarcodeSymbology
{
    Qr,
    Aztec,
    Code128,
    Code39,
    Ean13,
    Upca,
    DataMatrix,
    Pdf417,
    Other
}

public static class BarcodeSymbologyExtensions
{
    public static string Title(this BarcodeSymbology symbology) => symbology switch
    {
        BarcodeSymbology.Qr => "二维码",
        BarcodeSymbology.Aztec => "Aztec",
        BarcodeSymbology.Code128 => "Code 128",
        BarcodeSymbology.Code39 => "Code 39",
        BarcodeSymbology.Ean13 => "EAN-13",
        BarcodeSymbology.Upca => "UPC-A",
        BarcodeSymbology.DataMatrix => "Data Matrix",
        BarcodeSymbology.Pdf417 => "PDF417",
        _ => "条码"
    };
}
