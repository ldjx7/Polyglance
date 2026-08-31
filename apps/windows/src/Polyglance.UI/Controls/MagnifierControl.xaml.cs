using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Polyglance.Core.Models;

namespace Polyglance.UI.Controls;

public partial class MagnifierControl : UserControl
{
    private const int SampleRadius = 10;
    private const int SampleSide = SampleRadius * 2 + 1;
    private const string ShortcutHint = "C 复制色值 · ⇧C 切换 HEX/RGB";
    private readonly DispatcherTimer _copyFeedbackTimer;

    public MagnifierControl()
    {
        InitializeComponent();
        _copyFeedbackTimer = new DispatcherTimer(DispatcherPriority.Background, Dispatcher)
        {
            Interval = CopyFeedbackDuration
        };
        _copyFeedbackTimer.Tick += (_, _) => RestoreShortcutHint();
    }

    /// <summary>
    /// The pixel under the crosshair, or null when the pointer is outside the
    /// captured image. Callers copy from this rather than reading label text.
    /// </summary>
    public PixelSample? CurrentSample { get; private set; }

    public ColorDisplayFormat DisplayFormat { get; private set; } = ColorDisplayFormat.Hex;

    public ImageSource? PreviewSource => MagnifierImage.Source;

    public string InstructionText => TxtInstruction.Text;

    internal string ColorValueText => TxtColorValue.Text;

    internal string CoordinateLabelText => TxtCoordinate.Text;

    internal double ColorValueWidth => MeasuredWidth(TxtColorValue);

    internal double CoordinateWidth => MeasuredWidth(TxtCoordinate);

    internal bool InstructionWraps => TxtInstruction.TextWrapping != TextWrapping.NoWrap;

    public TimeSpan CopyFeedbackDuration { get; set; } = TimeSpan.FromSeconds(1.2);

    /// <summary>
    /// Samples the pixel at the given physical image coordinate and refreshes
    /// the preview patch, colour swatch and labels.
    /// </summary>
    public void Update(BitmapSource fullImage, int pixelX, int pixelY)
    {
        if (fullImage.PixelWidth <= 0 || fullImage.PixelHeight <= 0)
        {
            CurrentSample = null;
            return;
        }

        BitmapSource source = fullImage.Format == PixelFormats.Bgra32
            ? fullImage
            : new FormatConvertedBitmap(fullImage, PixelFormats.Bgra32, null, 0);

        int targetX = Math.Clamp(pixelX, 0, source.PixelWidth - 1);
        int targetY = Math.Clamp(pixelY, 0, source.PixelHeight - 1);

        int requestedX = targetX - SampleRadius;
        int requestedY = targetY - SampleRadius;
        int srcX = Math.Max(0, requestedX);
        int srcY = Math.Max(0, requestedY);
        int width = Math.Min(SampleSide, source.PixelWidth - srcX);
        int height = Math.Min(SampleSide, source.PixelHeight - srcY);
        if (width <= 0 || height <= 0)
        {
            CurrentSample = null;
            return;
        }

        // Keep a fixed 21x21 patch even at image edges. Missing cells stay black,
        // and the target pixel remains at (10, 10), exactly under the fixed
        // crosshair instead of shifting when a cropped patch is stretched.
        int destinationX = srcX - requestedX;
        int destinationY = srcY - requestedY;
        byte[] croppedPixels = new byte[width * height * 4];
        source.CopyPixels(
            new Int32Rect(srcX, srcY, width, height),
            croppedPixels,
            width * 4,
            0);
        byte[] patchPixels = new byte[SampleSide * SampleSide * 4];
        for (int index = 3; index < patchPixels.Length; index += 4)
            patchPixels[index] = 0xFF;
        for (int row = 0; row < height; row++)
        {
            Buffer.BlockCopy(
                croppedPixels,
                row * width * 4,
                patchPixels,
                ((destinationY + row) * SampleSide + destinationX) * 4,
                width * 4);
        }
        MagnifierImage.Source = BitmapSource.Create(
            SampleSide,
            SampleSide,
            96,
            96,
            PixelFormats.Bgra32,
            null,
            patchPixels,
            SampleSide * 4);

        var singlePixel = new CroppedBitmap(source, new Int32Rect(targetX, targetY, 1, 1));
        byte[] pixels = new byte[4];
        singlePixel.CopyPixels(pixels, 4, 0);

        // CreateBitmapSourceFromHBitmap yields BGRA channel order.
        CurrentSample = new PixelSample(targetX, targetY, pixels[2], pixels[1], pixels[0]);
        RefreshLabels();
    }

    /// <summary>
    /// Switches between HEX and RGB, matching the macOS Shift+C behaviour.
    /// </summary>
    public void ToggleDisplayFormat()
    {
        DisplayFormat = DisplayFormat.Toggled();
        RefreshLabels();
    }

    public void ShowCopyConfirmation(string copiedValue)
    {
        _copyFeedbackTimer.Stop();
        TxtInstruction.Text = $"已复制 {copiedValue}";
        TxtInstruction.Foreground = new SolidColorBrush(Color.FromRgb(0x22, 0xC5, 0x5E));
        _copyFeedbackTimer.Interval = CopyFeedbackDuration;
        _copyFeedbackTimer.Start();
    }

    private void RefreshLabels()
    {
        if (CurrentSample is not { } sample)
        {
            return;
        }

        TxtColorValue.Text = sample.Text(DisplayFormat);
        TxtCoordinate.Text = sample.CoordinateText;
        ColorPreviewBox.Background = new SolidColorBrush(
            Color.FromRgb(sample.Red, sample.Green, sample.Blue));
    }

    private void RestoreShortcutHint()
    {
        _copyFeedbackTimer.Stop();
        TxtInstruction.Text = ShortcutHint;
        TxtInstruction.Foreground = new SolidColorBrush(Color.FromRgb(0x94, 0xA3, 0xB8));
    }

    /// <summary>
    /// The width the text wants, independent of the slot it was given, so a
    /// test can tell "fits" from "was clipped to fit".
    /// </summary>
    private static double MeasuredWidth(TextBlock label)
    {
        label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        return label.DesiredSize.Width;
    }
}
