using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Polyglance.Platform.Interop;

namespace Polyglance.Platform.Text;

public static class SelectedTextReader
{
    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const ushort VK_CONTROL = 0x11;
    private const ushort VK_C = 0x43;

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUT
    {
        [FieldOffset(0)]
        public uint type;
        [FieldOffset(8)]
        public KEYBDINPUT ki;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] INPUT[] pInputs, int cbSize);

    public static async Task<string?> GetSelectedTextAsync()
    {
        string? originalText = null;
        try
        {
            if (Clipboard.ContainsText())
            {
                originalText = Clipboard.GetText();
            }
        }
        catch { }

        try
        {
            Clipboard.Clear();

            // Simulate Ctrl+C
            INPUT[] inputs = new INPUT[4];

            // Ctrl down
            inputs[0].type = INPUT_KEYBOARD;
            inputs[0].ki.wVk = VK_CONTROL;

            // C down
            inputs[1].type = INPUT_KEYBOARD;
            inputs[1].ki.wVk = VK_C;

            // C up
            inputs[2].type = INPUT_KEYBOARD;
            inputs[2].ki.wVk = VK_C;
            inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;

            // Ctrl up
            inputs[3].type = INPUT_KEYBOARD;
            inputs[3].ki.wVk = VK_CONTROL;
            inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;

            SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));

            // Wait up to 300ms for clipboard content
            for (int i = 0; i < 6; i++)
            {
                await Task.Delay(50);
                try
                {
                    if (Clipboard.ContainsText())
                    {
                        string selected = Clipboard.GetText();
                        if (!string.IsNullOrWhiteSpace(selected))
                        {
                            return selected.Trim();
                        }
                    }
                }
                catch { }
            }
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"SelectedTextReader error: {ex.Message}");
        }

        return originalText;
    }
}
