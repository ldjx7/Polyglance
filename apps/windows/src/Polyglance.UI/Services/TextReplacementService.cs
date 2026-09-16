using System;
using System.Runtime.InteropServices;
using System.Threading;
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

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, [MarshalAs(UnmanagedType.Bool)] bool fAttach);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    public static IntPtr LastTargetHwnd { get; set; } = IntPtr.Zero;

    public static void RecordTargetWindow()
    {
        IntPtr hwnd = GetForegroundWindow();
        if (hwnd != IntPtr.Zero)
        {
            GetWindowThreadProcessId(hwnd, out uint pid);
            if (pid != (uint)Environment.ProcessId)
            {
                LastTargetHwnd = hwnd;
            }
        }
    }

    public static void RestoreTargetWindow()
    {
        if (LastTargetHwnd == IntPtr.Zero) return;

        IntPtr foreground = GetForegroundWindow();
        if (foreground == LastTargetHwnd) return;

        uint currentThreadId = GetCurrentThreadId();
        uint targetThreadId = GetWindowThreadProcessId(LastTargetHwnd, out _);
        uint foregroundThreadId = foreground != IntPtr.Zero ? GetWindowThreadProcessId(foreground, out _) : 0;

        if (currentThreadId != targetThreadId && targetThreadId != 0)
        {
            AttachThreadInput(currentThreadId, targetThreadId, true);
        }
        if (foregroundThreadId != 0 && foregroundThreadId != currentThreadId && foregroundThreadId != targetThreadId)
        {
            AttachThreadInput(foregroundThreadId, targetThreadId, true);
        }

        BringWindowToTop(LastTargetHwnd);
        SetForegroundWindow(LastTargetHwnd);

        if (currentThreadId != targetThreadId && targetThreadId != 0)
        {
            AttachThreadInput(currentThreadId, targetThreadId, false);
        }
        if (foregroundThreadId != 0 && foregroundThreadId != currentThreadId && foregroundThreadId != targetThreadId)
        {
            AttachThreadInput(foregroundThreadId, targetThreadId, false);
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

    [StructLayout(LayoutKind.Explicit, Size = 40)]
    private struct INPUT
    {
        [FieldOffset(0)]
        public uint type;
        [FieldOffset(8)]
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
        await Task.Delay(80);

        await SetClipboardTextAsync(text);

        for (int attempt = 0; attempt < 15; attempt++)
        {
            bool modifierPressed = false;
            foreach (int vk in new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C })
            {
                if ((GetAsyncKeyState(vk) & 0x8000) != 0)
                {
                    modifierPressed = true;
                    break;
                }
            }
            if (!modifierPressed) break;
            await Task.Delay(20);
        }

        await Task.Delay(40);

        INPUT[] inputs =
        [
            KeyboardInput(VirtualKeyControl, keyUp: false),
            KeyboardInput(VirtualKeyV, keyUp: false),
            KeyboardInput(VirtualKeyV, keyUp: true),
            KeyboardInput(VirtualKeyControl, keyUp: true)
        ];
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private static async Task<bool> SetClipboardTextAsync(string text)
    {
        for (int i = 0; i < 5; i++)
        {
            bool success = false;
            var app = System.Windows.Application.Current;
            if (app?.Dispatcher != null)
            {
                if (app.Dispatcher.CheckAccess())
                {
                    try
                    {
                        Clipboard.SetText(text);
                        success = true;
                    }
                    catch
                    {
                        success = false;
                    }
                }
                else
                {
                    await app.Dispatcher.InvokeAsync(() =>
                    {
                        try
                        {
                            Clipboard.SetText(text);
                            success = true;
                        }
                        catch
                        {
                            success = false;
                        }
                    });
                }
            }
            else
            {
                var tcs = new TaskCompletionSource<bool>();
                var thread = new Thread(() =>
                {
                    try
                    {
                        Clipboard.SetText(text);
                        tcs.SetResult(true);
                    }
                    catch
                    {
                        tcs.SetResult(false);
                    }
                });
                thread.SetApartmentState(ApartmentState.STA);
                thread.Start();
                success = await tcs.Task;
            }

            if (success) return true;
            await Task.Delay(30);
        }
        return false;
    }
}
