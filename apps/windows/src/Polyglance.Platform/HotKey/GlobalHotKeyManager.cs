using System;
using System.Collections.Generic;
using System.Windows.Interop;
using Polyglance.Platform.Interop;

namespace Polyglance.Platform.HotKey;

public sealed class GlobalHotKeyManager : IDisposable
{
    private readonly IntPtr _hWnd;
    private readonly HwndSource? _source;
    private readonly Dictionary<int, Action> _callbacks = new();
    private int _currentId = 100;
    private bool _disposed;

    public GlobalHotKeyManager(IntPtr hWnd)
    {
        _hWnd = hWnd;
        _source = HwndSource.FromHwnd(hWnd);
        _source?.AddHook(WndProc);
    }

    public int Register(uint modifiers, uint key, Action callback)
    {
        // A disposed manager has already removed its message hook, so anything
        // registered through it would be claimed from every other application
        // and then never delivered anywhere.
        if (_disposed)
        {
            return -1;
        }

        int id = ++_currentId;
        bool success = NativeWin32.RegisterHotKey(_hWnd, id, modifiers | NativeWin32.MOD_NOREPEAT, key);
        if (success)
        {
            _callbacks[id] = callback;
            return id;
        }
        return -1;
    }

    public void Unregister(int id)
    {
        if (_callbacks.Remove(id))
        {
            NativeWin32.UnregisterHotKey(_hWnd, id);
        }
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == NativeWin32.WM_HOTKEY)
        {
            int id = wParam.ToInt32();
            if (_callbacks.TryGetValue(id, out var callback))
            {
                callback?.Invoke();
                handled = true;
            }
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        if (!_disposed)
        {
            _source?.RemoveHook(WndProc);
            foreach (var id in _callbacks.Keys)
            {
                NativeWin32.UnregisterHotKey(_hWnd, id);
            }
            _callbacks.Clear();
            _disposed = true;
        }
    }
}
