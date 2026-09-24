using System;
using System.Runtime.InteropServices;
using Polyglance.Core.Models;

namespace Polyglance.Core.Native;

public static partial class NativeMethods
{
    [LibraryImport(DllName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int polyglance_windows_recording_encoder_new(
        string path, uint width, uint height, uint fps, uint bitrate, out IntPtr handle);

    [LibraryImport(DllName)]
    public static partial int polyglance_windows_recording_encoder_write(
        IntPtr handle, IntPtr pixels, nuint length, long timestamp);

    [LibraryImport(DllName)]
    public static partial int polyglance_windows_recording_encoder_finish(IntPtr handle, long endTime);

    [LibraryImport(DllName)]
    public static partial void polyglance_windows_recording_encoder_free(IntPtr handle);

    [LibraryImport(DllName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int polyglance_windows_recording_remux(string video, string audio, string output);

    [LibraryImport(DllName)]
    public static partial int polyglance_windows_capture_new(
        int x, int y, int width, int height, [MarshalAs(UnmanagedType.Bool)] bool cursor, out IntPtr handle);

    [LibraryImport(DllName)]
    public static partial int polyglance_windows_capture_frame(
        IntPtr handle, IntPtr buffer, nuint bufferLen, [MarshalAs(UnmanagedType.Bool)] bool cursor, [MarshalAs(UnmanagedType.Bool)] out bool captured);

    [LibraryImport(DllName)]
    public static partial void polyglance_windows_capture_free(IntPtr handle);

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
    public static unsafe partial int polyglance_stitcher_set_crop_insets(
        IntPtr stitcher,
        uint top,
        uint bottom,
        uint left,
        uint right);

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
    public static unsafe partial int polyglance_layout_format_text(
        string linesJson,
        byte mode,
        out IntPtr outText);

    [LibraryImport(DllName, StringMarshalling = StringMarshalling.Utf8)]
    public static unsafe partial int polyglance_alignment_pairs(
        string sourceText,
        string targetText,
        out IntPtr outPairsJson);

    [LibraryImport(DllName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int polyglance_text_format(
        string text,
        byte mode,
        out IntPtr outText);

    [LibraryImport(DllName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int polyglance_text_smart_merge_lines(
        string text,
        out IntPtr outText);

    [LibraryImport(DllName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int polyglance_text_apply_pangu_spacing(
        string text,
        out IntPtr outText);

    [LibraryImport(DllName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int polyglance_text_remove_extraneous_spaces(
        string text,
        out IntPtr outText);

    [LibraryImport(DllName)]
    [return: MarshalAs(UnmanagedType.U1)]
    public static partial bool polyglance_text_is_cjk_scalar(uint scalar);

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

    [LibraryImport(DllName)]
    public static unsafe partial int polyglance_windows_ocr_recognize(
        byte* pngBytes,
        nuint pngLen,
        out IntPtr outLinesJson);

    [LibraryImport(DllName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int polyglance_windows_recording_compose(
        string videoPath,
        string audioPathsJson,
        string outputPath,
        int width,
        int height,
        int frameRate,
        uint videoBitrate);

    [LibraryImport(DllName)]
    public static partial int polyglance_windows_store_check_updates(
        IntPtr ownerHwnd,
        out IntPtr outUpdateJson);

    [LibraryImport(DllName)]
    public static partial int polyglance_windows_store_install_updates(
        IntPtr ownerHwnd,
        out IntPtr outResultJson);
}
