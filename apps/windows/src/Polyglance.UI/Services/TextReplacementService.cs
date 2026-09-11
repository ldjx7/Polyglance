using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;

namespace Polyglance.UI.Services;

public static class TextReplacementService
{
    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;
    private const ushort VirtualKeyControl = 0x11;
    private const ushort VirtualKeyV = 0x56;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, [In] INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    public static IntPtr LastTargetHwnd { get; set; } = IntPtr.Zero;

    public static void RecordTargetWindow()
    {
        IntPtr hwnd = GetForegroundWindow();
        if (hwnd != IntPtr.Zero)
        {
            LastTargetHwnd = hwnd;
        }
    }

    public static void RestoreTargetWindow()
    {
        if (LastTargetHwnd != IntPtr.Zero)
        {
            SetForegroundWindow(LastTargetHwnd);
        }
    }

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
        [FieldOffset(4)]
        public KEYBDINPUT keyboard;
    }

    private static INPUT KeyboardInput(ushort virtualKey, bool keyUp) => new()
    {
        type = InputKeyboard,
        keyboard = new KEYBDINPUT
        {
            virtualKey = virtualKey,
            flags = keyUp ? KeyEventKeyUp : 0
        }
    };

    public static async Task ReplaceSelectedTextAsync(string text)
    {
        if (string.IsNullOrEmpty(text)) return;

        RestoreTargetWindow();

        for (int i = 0; i < 3; i++)
        {
            try
            {
                Clipboard.SetText(text);
                break;
            }
            catch
            {
                await Task.Delay(20);
            }
        }

        await Task.Delay(120);

        INPUT[] inputs =
        [
            KeyboardInput(VirtualKeyControl, keyUp: false),
            KeyboardInput(VirtualKeyV, keyUp: false),
            KeyboardInput(VirtualKeyV, keyUp: true),
            KeyboardInput(VirtualKeyControl, keyUp: true)
        ];
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }
}
