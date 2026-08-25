using System;

namespace Polyglance.Core.Models;

/// <summary>
/// A tightly packed, row-major RGBA image returned by the native capture core.
/// This is raw pixel data rather than an encoded PNG or JPEG file.
/// </summary>
public sealed class RgbaImageBuffer
{
    public RgbaImageBuffer(byte[] pixels, uint width, uint height)
    {
        ArgumentNullException.ThrowIfNull(pixels);
        if (width == 0)
            throw new ArgumentOutOfRangeException(nameof(width), "Image width must be greater than zero.");
        if (height == 0)
            throw new ArgumentOutOfRangeException(nameof(height), "Image height must be greater than zero.");

        long expectedLength = checked((long)width * height * 4L);
        if (expectedLength > int.MaxValue || pixels.LongLength != expectedLength)
        {
            throw new ArgumentException(
                $"RGBA pixel data length must be {expectedLength} bytes for a {width}x{height} image.",
                nameof(pixels));
        }

        Pixels = pixels;
        Width = width;
        Height = height;
        Stride = checked((int)width * 4);
    }

    public byte[] Pixels { get; }

    public uint Width { get; }

    public uint Height { get; }

    public int Stride { get; }

    /// <summary>
    /// Converts the native RGBA channel order to the BGRA order expected by
    /// WPF's 32-bit bitmap pixel format.
    /// </summary>
    public byte[] CopyBgraPixels()
    {
        byte[] bgra = new byte[Pixels.Length];
        for (int index = 0; index < Pixels.Length; index += 4)
        {
            bgra[index] = Pixels[index + 2];
            bgra[index + 1] = Pixels[index + 1];
            bgra[index + 2] = Pixels[index];
            bgra[index + 3] = Pixels[index + 3];
        }
        return bgra;
    }
}
