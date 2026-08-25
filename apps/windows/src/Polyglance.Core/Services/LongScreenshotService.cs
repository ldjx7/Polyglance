using System;
using System.Runtime.InteropServices;
using Polyglance.Core.Models;
using Polyglance.Core.Native;

namespace Polyglance.Core.Services;

public sealed class LongScreenshotService : IDisposable
{
    private IntPtr _stitcher = IntPtr.Zero;
    private bool _disposed;

    public LongScreenshotService(StitchConfiguration? config = null, bool vertical = true)
    {
        var cfg = config ?? StitchConfiguration.Default;
        int ret = NativeMethods.polyglance_stitcher_new(in cfg, vertical ? 0 : 1, out _stitcher);
        if (ret != 0 || _stitcher == IntPtr.Zero)
        {
            throw new InvalidOperationException($"Failed to initialize stitcher (code: {ret})");
        }
    }

    public unsafe StitchAppendResult AppendFrame(ReadOnlySpan<byte> rgbaBytes, uint width, uint height)
    {
        if (_disposed || _stitcher == IntPtr.Zero)
            throw new ObjectDisposedException(nameof(LongScreenshotService));

        fixed (byte* ptr = rgbaBytes)
        {
            int ret = NativeMethods.polyglance_stitcher_append(
                _stitcher,
                ptr,
                (nuint)rgbaBytes.Length,
                width,
                height,
                out var result);

            if (ret != 0)
                throw new InvalidOperationException($"Stitcher append error: {ret}");

            return result;
        }
    }

    public RgbaImageBuffer Render()
    {
        if (_disposed || _stitcher == IntPtr.Zero)
            throw new ObjectDisposedException(nameof(LongScreenshotService));

        int ret = NativeMethods.polyglance_stitcher_render(_stitcher, out IntPtr outBytes, out nuint outLen);
        if (ret != 0 || outBytes == IntPtr.Zero || outLen == 0)
            throw new InvalidOperationException("Failed to render stitched screenshot");

        try
        {
            byte[] managed = new byte[(int)outLen];
            Marshal.Copy(outBytes, managed, 0, (int)outLen);
            var dimensions = GetDimensions();
            return new RgbaImageBuffer(managed, dimensions.Width, dimensions.Height);
        }
        finally
        {
            NativeMethods.polyglance_free_buffer(outBytes, outLen);
        }
    }

    public RgbaImageBuffer RenderPreview(uint maximumWidth = 220, uint maximumHeight = 1600)
    {
        if (_disposed || _stitcher == IntPtr.Zero)
            throw new ObjectDisposedException(nameof(LongScreenshotService));

        int ret = NativeMethods.polyglance_stitcher_render_preview(
            _stitcher,
            maximumWidth,
            maximumHeight,
            out IntPtr outBytes,
            out nuint outLen,
            out uint width,
            out uint height);
        if (ret != 0 || outBytes == IntPtr.Zero || outLen == 0)
            throw new InvalidOperationException("Failed to render stitched screenshot preview");

        try
        {
            byte[] managed = new byte[(int)outLen];
            Marshal.Copy(outBytes, managed, 0, (int)outLen);
            return new RgbaImageBuffer(managed, width, height);
        }
        finally
        {
            NativeMethods.polyglance_free_buffer(outBytes, outLen);
        }
    }

    public (uint FrameCount, uint Width, uint Height, long Offset) GetDimensions()
    {
        if (_disposed || _stitcher == IntPtr.Zero)
            throw new ObjectDisposedException(nameof(LongScreenshotService));

        NativeMethods.polyglance_stitcher_get_dimensions(
            _stitcher,
            out uint frameCount,
            out uint width,
            out uint height,
            out long offset);

        return (frameCount, width, height, offset);
    }

    public void Dispose()
    {
        if (!_disposed)
        {
            if (_stitcher != IntPtr.Zero)
            {
                NativeMethods.polyglance_stitcher_free(_stitcher);
                _stitcher = IntPtr.Zero;
            }
            _disposed = true;
        }
    }
}
