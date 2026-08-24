using System;
using System.Runtime.InteropServices;
using Polyglance.Core.Models;

namespace Polyglance.Core.Native;

public static partial class NativeMethods
{
    private const string DllName = "polyglance_cabi";

    [LibraryImport(DllName)]
    public static unsafe partial void polyglance_free_string(IntPtr ptr);

    [LibraryImport(DllName)]
    public static unsafe partial void polyglance_free_buffer(IntPtr ptr, nuint len);

    [LibraryImport(DllName)]
    public static unsafe partial int polyglance_engine_new(out IntPtr outEngine);

    [LibraryImport(DllName)]
    public static unsafe partial void polyglance_engine_free(IntPtr engine);

    [LibraryImport(DllName, StringMarshalling = StringMarshalling.Utf8)]
    public static unsafe partial int polyglance_translate(
        IntPtr engine,
        string inputJson,
        out IntPtr outJson);

    [LibraryImport(DllName, StringMarshalling = StringMarshalling.Utf8)]
    public static unsafe partial int polyglance_stream_event_parse(
        string line,
        out int outEventType,
        out IntPtr outText);

    [LibraryImport(DllName)]
    public static unsafe partial int polyglance_stitcher_new(
        in StitchConfiguration config,
        int direction,
        out IntPtr outStitcher);

    [LibraryImport(DllName)]
    public static unsafe partial void polyglance_stitcher_free(IntPtr stitcher);

    [LibraryImport(DllName)]
    public static unsafe partial int polyglance_stitcher_append(
        IntPtr stitcher,
        byte* bytes,
        nuint len,
        uint width,
        uint height,
        out StitchAppendResult outResult);

    [LibraryImport(DllName)]
    public static unsafe partial int polyglance_stitcher_render(
        IntPtr stitcher,
        out IntPtr outBytes,
        out nuint outLen);

    [LibraryImport(DllName)]
    public static unsafe partial int polyglance_stitcher_render_preview(
        IntPtr stitcher,
        uint maxPixelWidth,
        uint maxPixelHeight,
        out IntPtr outBytes,
        out nuint outLen,
        out uint outWidth,
        out uint outHeight);

    [LibraryImport(DllName)]
    public static unsafe partial int polyglance_stitcher_get_dimensions(
        IntPtr stitcher,
        out uint outFrameCount,
        out uint outWidth,
        out uint outHeight,
        out long outOffset);

    [LibraryImport(DllName, StringMarshalling = StringMarshalling.Utf8)]
    public static unsafe partial int polyglance_layout_paragraphs(
        string linesJson,
        out IntPtr outParagraphsJson);

    [LibraryImport(DllName, StringMarshalling = StringMarshalling.Utf8)]
    public static unsafe partial int polyglance_alignment_pairs(
        string sourceText,
        string targetText,
        out IntPtr outPairsJson);

    [LibraryImport(DllName)]
    public static partial int polyglance_selection_rect(
        NativePoint start,
        NativePoint end,
        NativeRect bounds,
        out NativeRect outRect);

    [LibraryImport(DllName)]
    public static partial int polyglance_selection_edit_target(
        NativePoint point,
        NativeRect selection,
        double handleTolerance,
        out int outTarget);

    [LibraryImport(DllName)]
    public static partial int polyglance_selection_expanded_toward(
        NativeRect selection,
        NativePoint point,
        NativeRect bounds,
        out NativeRect outRect);

    [LibraryImport(DllName)]
    public static partial int polyglance_selection_edited(
        NativeRect original,
        NativePoint dragStart,
        NativePoint current,
        int target,
        NativeRect bounds,
        double minimumSide,
        out NativeRect outRect);
}
