using System;
using System.Windows.Input;
using Polyglance.Platform.Interop;

namespace Polyglance.Platform.HotKey;

/// <summary>
/// A stored shortcut string ("Ctrl+Shift+D1") resolved into the modifier mask
/// and virtual-key code RegisterHotKey expects.
/// </summary>
/// <remarks>
/// The recorder writes WPF <see cref="Key"/> names, so the key token is parsed
/// back into a <see cref="Key"/> and converted with
/// <see cref="KeyInterop.VirtualKeyFromKey"/>. Matching the name against a
/// different enumeration would resolve most keys and silently drop the rest.
/// </remarks>
public sealed record ShortcutDefinition(uint Modifiers, uint VirtualKey)
{
    /// <summary>
    /// Windows treats Shift alone as a text modifier, so a shortcut needs at
    /// least one of these to be registrable without hijacking ordinary typing.
    /// </summary>
    private const uint RequiredModifiers =
        NativeWin32.MOD_CONTROL | NativeWin32.MOD_ALT | NativeWin32.MOD_WIN;

    public static bool TryParse(string? text, out ShortcutDefinition? definition, out string? error)
    {
        definition = null;
        error = null;

        if (string.IsNullOrWhiteSpace(text))
        {
            error = "快捷键为空";
            return false;
        }

        uint modifiers = 0;
        uint virtualKey = 0;
        string[] parts = text.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        foreach (string part in parts)
        {
            if (part.Equals("Ctrl", StringComparison.OrdinalIgnoreCase)
                || part.Equals("Control", StringComparison.OrdinalIgnoreCase))
            {
                modifiers |= NativeWin32.MOD_CONTROL;
            }
            else if (part.Equals("Alt", StringComparison.OrdinalIgnoreCase))
            {
                modifiers |= NativeWin32.MOD_ALT;
            }
            else if (part.Equals("Shift", StringComparison.OrdinalIgnoreCase))
            {
                modifiers |= NativeWin32.MOD_SHIFT;
            }
            else if (part.Equals("Win", StringComparison.OrdinalIgnoreCase)
                || part.Equals("Windows", StringComparison.OrdinalIgnoreCase))
            {
                modifiers |= NativeWin32.MOD_WIN;
            }
            else if (virtualKey != 0)
            {
                error = $"快捷键包含多个主键：{text}";
                return false;
            }
            else if (TryParseKey(part, out uint parsedVirtualKey))
            {
                virtualKey = parsedVirtualKey;
            }
            else
            {
                error = $"无法识别的按键：{part}";
                return false;
            }
        }

        if (virtualKey == 0)
        {
            error = "快捷键缺少主键";
            return false;
        }

        if ((modifiers & RequiredModifiers) == 0)
        {
            error = "快捷键至少需要 Ctrl、Alt 或 Win 之一";
            return false;
        }

        definition = new ShortcutDefinition(modifiers, virtualKey);
        return true;
    }

    /// <summary>
    /// Some <see cref="Key"/> members stand for an input-method or menu state
    /// rather than a physical key, and there is no virtual-key code to register
    /// them under.
    /// </summary>
    private static bool IsRegistrable(Key key) =>
        key != Key.None
        && key != Key.System
        && key != Key.ImeProcessed
        && key != Key.DeadCharProcessed
        && KeyInterop.VirtualKeyFromKey(key) != 0;

    private static bool TryParseKey(string token, out uint virtualKey)
    {
        virtualKey = 0;

        // The recorder writes "D1", but the display form and hand-edited
        // configuration files both use a bare digit.
        string name = token.Length == 1 && char.IsAsciiDigit(token[0]) ? $"D{token}" : token;

        // Enum.TryParse also accepts raw numbers, which would quietly turn a
        // stray "12" into whichever key happens to carry that value.
        if (int.TryParse(name, out _))
        {
            return false;
        }

        if (!Enum.TryParse(name, ignoreCase: true, out Key key) || !IsRegistrable(key))
        {
            return false;
        }

        virtualKey = (uint)KeyInterop.VirtualKeyFromKey(key);
        return true;
    }
}
