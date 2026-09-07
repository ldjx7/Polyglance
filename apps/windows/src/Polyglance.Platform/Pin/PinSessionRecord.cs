using System;

namespace Polyglance.Platform.Pin;

public enum PinSessionStatus { Active, Closed, Archived }

public sealed record PinSessionRecord
{
    public string Id { get; init; } = Guid.NewGuid().ToString("N");
    public string ArchiveId { get; init; } = "";
    public string? Text { get; init; }
    public double X { get; init; }
    public double Y { get; init; }
    public double Width { get; init; } = 400;
    public double Height { get; init; } = 300;
    public double Opacity { get; init; } = 1;
    public bool IsLocked { get; init; }
    public bool IsAlwaysOnTop { get; init; } = true;
    public PinSessionStatus Status { get; init; } = PinSessionStatus.Active;

    public bool IsValid => double.IsFinite(X) && double.IsFinite(Y) && double.IsFinite(Width) && double.IsFinite(Height)
        && Width > 0 && Height > 0 && Width <= 32768 && Height <= 32768
        && double.IsFinite(Opacity) && Opacity >= .1 && Opacity <= 1
        && System.Text.Encoding.UTF8.GetByteCount(Text ?? "") <= 1048576;
}
