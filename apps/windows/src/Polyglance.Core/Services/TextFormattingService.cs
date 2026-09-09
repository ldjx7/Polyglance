using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using Polyglance.Core.Models;
using Polyglance.Core.Native;

namespace Polyglance.Core.Services;

/// <summary>
/// How OCR output is reflowed before it reaches the clipboard or a translation
/// request. The numeric values are persisted in the user's configuration and
/// must stay in step with <c>capture_core::formatting::TextFormattingMode</c>.
/// </summary>
public enum TextFormattingMode
{
    SmartMerge = 0,
    PreserveBreaks = 1,
    RemoveSpaces = 2,
    Raw = 3
}

/// <summary>
/// Thin wrapper over the shared Rust implementation in
/// <c>capture_core::formatting</c>. The algorithm itself lives there so macOS
/// and Windows cannot drift apart; only the P/Invoke marshalling is local.
/// </summary>
public static class TextFormattingService
{
    public static string Format(IEnumerable<LayoutTextLine> lines, TextFormattingMode mode)
    {
        if (lines == null)
            return string.Empty;

        var list = lines as IList<LayoutTextLine> ?? lines.ToList();
        if (list.Count == 0)
            return string.Empty;

        string linesJson = JsonSerializer.Serialize(list);
        int status = NativeMethods.polyglance_layout_format_text(linesJson, (byte)mode, out IntPtr outText);
        if (status != 0 || outText == IntPtr.Zero)
        {
            string plainText = string.Join("\n", list.Select(l => l.Text));
            return Format(plainText, mode);
        }

        try
        {
            return Marshal.PtrToStringUTF8(outText) ?? string.Empty;
        }
        finally
        {
            NativeMethods.polyglance_free_string(outText);
        }
    }

    public static string Format(string text, TextFormattingMode mode)
    {
        if (string.IsNullOrEmpty(text))
            return string.Empty;

        return Transform(
            text,
            (string input, out IntPtr output) =>
                NativeMethods.polyglance_text_format(input, (byte)mode, out output));
    }

    public static string SmartMergeLines(string text)
    {
        if (string.IsNullOrEmpty(text))
            return string.Empty;

        return Transform(text, NativeMethods.polyglance_text_smart_merge_lines);
    }

    public static string ApplyPanguSpacing(string text)
    {
        if (string.IsNullOrEmpty(text))
            return string.Empty;

        return Transform(text, NativeMethods.polyglance_text_apply_pangu_spacing);
    }

    public static string RemoveExtraneousSpaces(string text)
    {
        if (string.IsNullOrEmpty(text))
            return string.Empty;

        return Transform(text, NativeMethods.polyglance_text_remove_extraneous_spaces);
    }

    /// <summary>
    /// A UTF-16 code unit outside the Basic Multilingual Plane is half of a
    /// surrogate pair and never CJK on its own, which matches how the callers
    /// inspect one <c>char</c> at a time.
    /// </summary>
    public static bool IsCjk(char value) =>
        NativeMethods.polyglance_text_is_cjk_scalar(value);

    private delegate int NativeTransform(string text, out IntPtr outText);

    /// <summary>
    /// Returns the input unchanged if the native call fails, so a formatting
    /// problem degrades to raw OCR text instead of losing it.
    /// </summary>
    private static string Transform(string text, NativeTransform operation)
    {
        int status = operation(text, out IntPtr outText);
        if (status != 0 || outText == IntPtr.Zero)
        {
            return text;
        }

        try
        {
            return Marshal.PtrToStringUTF8(outText) ?? text;
        }
        finally
        {
            NativeMethods.polyglance_free_string(outText);
        }
    }
}
