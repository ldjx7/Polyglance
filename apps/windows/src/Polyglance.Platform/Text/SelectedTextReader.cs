using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using Polyglance.Platform.Interop;

namespace Polyglance.Platform.Text;

/// <summary>
/// Reads the selection owned by the currently focused application. UI
/// Automation is preferred because it does not mutate the clipboard; Ctrl+C is
/// retained as a compatibility fallback for browsers and custom editors.
/// </summary>
public static class SelectedTextReader
{
    public static Task<string?> GetSelectedTextAsync() =>
        new SelectedTextCapturePipeline(new WindowsSelectedTextCaptureEnvironment()).ReadAsync();
}

internal sealed class SelectedTextCapturePipeline
{
    private const int ModifierReleaseAttempts = 25;
    private const int ClipboardChangeAttempts = 25;
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(20);

    private readonly ISelectedTextCaptureEnvironment _environment;

    internal SelectedTextCapturePipeline(ISelectedTextCaptureEnvironment environment)
    {
        _environment = environment;
    }

    internal async Task<string?> ReadAsync()
    {
        string? directSelection = TryReadDirectSelection();
        if (Normalize(directSelection) is { } directText)
        {
            return directText;
        }

        ClipboardSnapshot snapshot;
        try
        {
            snapshot = _environment.CaptureClipboard();
        }
        catch
        {
            // Never clear a clipboard that we could not preserve first. A
            // temporarily busy OLE clipboard is safer to report as no
            // selection than to destroy the user's existing contents.
            return null;
        }

        if (!await WaitForModifierReleaseAsync())
        {
            return null;
        }

        uint clearedSequence;
        try
        {
            _environment.ClearClipboard();
            clearedSequence = _environment.ClipboardSequenceNumber;
        }
        catch
        {
            return null;
        }

        if (!_environment.SendCopyShortcut())
        {
            TryRestore(snapshot);
            return null;
        }

        bool clipboardChanged = await WaitForClipboardChangeAsync(clearedSequence);
        if (!clipboardChanged)
        {
            TryRestore(snapshot);
            return null;
        }

        uint copiedSequence = _environment.ClipboardSequenceNumber;
        string? copiedText;
        try
        {
            copiedText = _environment.ReadClipboardText();
        }
        catch
        {
            copiedText = null;
        }

        // Do not overwrite a clipboard update that happened after the target
        // application answered our Ctrl+C request.
        if (_environment.ClipboardSequenceNumber == copiedSequence)
        {
            TryRestore(snapshot);
        }

        return Normalize(copiedText);
    }

    private string? TryReadDirectSelection()
    {
        try
        {
            return _environment.ReadFocusedSelection();
        }
        catch
        {
            return null;
        }
    }

    private async Task<bool> WaitForModifierReleaseAsync()
    {
        for (int attempt = 0; attempt < ModifierReleaseAttempts; attempt++)
        {
            if (!_environment.AreShortcutModifiersPressed())
            {
                return true;
            }
            await _environment.DelayAsync(PollInterval);
        }
        return false;
    }

    private async Task<bool> WaitForClipboardChangeAsync(uint clearedSequence)
    {
        for (int attempt = 0; attempt < ClipboardChangeAttempts; attempt++)
        {
            if (_environment.ClipboardSequenceNumber != clearedSequence)
            {
                return true;
            }
            await _environment.DelayAsync(PollInterval);
        }
        return false;
    }

    private void TryRestore(ClipboardSnapshot snapshot)
    {
        try
        {
            _environment.RestoreClipboard(snapshot);
        }
        catch
        {
            // Selection capture is still allowed to succeed when another
            // process temporarily owns the OLE clipboard.
        }
    }

    private static string? Normalize(string? text)
    {
        string? trimmed = text?.Trim();
        return string.IsNullOrWhiteSpace(trimmed) ? null : trimmed;
    }
}

internal interface ISelectedTextCaptureEnvironment
{
    string? ReadFocusedSelection();
    ClipboardSnapshot CaptureClipboard();
    void ClearClipboard();
    uint ClipboardSequenceNumber { get; }
    bool AreShortcutModifiersPressed();
    bool SendCopyShortcut();
    string? ReadClipboardText();
    void RestoreClipboard(ClipboardSnapshot snapshot);
    Task DelayAsync(TimeSpan delay);
}

internal readonly record struct ClipboardSnapshot(object? Value);

internal sealed class WindowsSelectedTextCaptureEnvironment : ISelectedTextCaptureEnvironment
{
    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;
    private const ushort VirtualKeyControl = 0x11;
    private const ushort VirtualKeyC = 0x43;
    private static readonly int[] ShortcutModifierKeys =
    [
        0x10, // Shift
        0x11, // Control
        0x12, // Alt
        0x5B, // Left Windows
        0x5C  // Right Windows
    ];

    public uint ClipboardSequenceNumber => NativeWin32.GetClipboardSequenceNumber();

    public string? ReadFocusedSelection()
    {
        AutomationElement? focusedElement = AutomationElement.FocusedElement;
        if (focusedElement == null
            || !focusedElement.TryGetCurrentPattern(TextPattern.Pattern, out object? patternObject)
            || patternObject is not TextPattern textPattern)
        {
            return null;
        }

        string[] selectedRanges = textPattern.GetSelection()
            .Select(range => range.GetText(-1).TrimEnd('\r', '\n'))
            .Where(text => !string.IsNullOrWhiteSpace(text))
            .ToArray();
        return selectedRanges.Length == 0
            ? null
            : string.Join(Environment.NewLine, selectedRanges);
    }

    public ClipboardSnapshot CaptureClipboard()
    {
        IDataObject? source = Clipboard.GetDataObject();
        if (source == null)
        {
            return new ClipboardSnapshot(null);
        }

        var copy = new DataObject();
        foreach (string format in source.GetFormats(autoConvert: false))
        {
            try
            {
                object? data = source.GetData(format, autoConvert: false);
                if (data != null)
                {
                    copy.SetData(format, data);
                }
            }
            catch
            {
                // A delayed-rendering clipboard owner can reject individual
                // formats; keep the remaining formats instead of failing all.
            }
        }
        return new ClipboardSnapshot(copy);
    }

    public void ClearClipboard() => Clipboard.Clear();

    public bool AreShortcutModifiersPressed() =>
        ShortcutModifierKeys.Any(key => (NativeWin32.GetAsyncKeyState(key) & 0x8000) != 0);

    public bool SendCopyShortcut()
    {
        INPUT[] inputs =
        [
            KeyboardInput(VirtualKeyControl, keyUp: false),
            KeyboardInput(VirtualKeyC, keyUp: false),
            KeyboardInput(VirtualKeyC, keyUp: true),
            KeyboardInput(VirtualKeyControl, keyUp: true)
        ];
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>()) == inputs.Length;
    }

    public string? ReadClipboardText() =>
        Clipboard.ContainsText() ? Clipboard.GetText() : null;

    public void RestoreClipboard(ClipboardSnapshot snapshot)
    {
        if (snapshot.Value is IDataObject dataObject)
        {
            Clipboard.SetDataObject(dataObject, copy: true);
        }
        else
        {
            Clipboard.Clear();
        }
    }

    public Task DelayAsync(TimeSpan delay) => Task.Delay(delay);

    private static INPUT KeyboardInput(ushort virtualKey, bool keyUp) => new()
    {
        type = InputKeyboard,
        keyboard = new KEYBDINPUT
        {
            virtualKey = virtualKey,
            flags = keyUp ? KeyEventKeyUp : 0
        }
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort virtualKey;
        public ushort scanCode;
        public uint flags;
        public uint time;
        public IntPtr extraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUT
    {
        [FieldOffset(0)]
        public uint type;

        [FieldOffset(8)]
        public KEYBDINPUT keyboard;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(
        uint inputCount,
        [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] INPUT[] inputs,
        int inputSize);
}
