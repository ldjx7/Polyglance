using System;
using Polyglance.Platform.Interop;

namespace Polyglance.Platform.Capture;

/// <summary>
/// Locates the first visible foreign-process window below Polyglance at the
/// capture-region centre and forwards wheel input to it. This keeps the long
/// screenshot controls interactive while the document underneath still
/// receives both upward and downward scrolling.
/// </summary>
public static class UnderlyingWindowScroller
{
    private const int MaximumChildDepth = 32;

    public static IntPtr FindTarget(int screenX, int screenY)
    {
        uint currentProcessId = checked((uint)Environment.ProcessId);
        IntPtr target = IntPtr.Zero;

        NativeWin32.EnumWindows((window, _) =>
        {
            if (!NativeWin32.IsWindowVisible(window))
            {
                return true;
            }

            NativeWin32.GetWindowThreadProcessId(window, out uint processId);
            if (processId == currentProcessId)
            {
                return true;
            }

            if (NativeWin32.GetWindowRect(window, out var rect)
                && screenX >= rect.Left
                && screenX < rect.Right
                && screenY >= rect.Top
                && screenY < rect.Bottom)
            {
                target = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);

        return target;
    }

    public static bool ForwardWheel(IntPtr target, int delta, int screenX, int screenY)
    {
        if (target == IntPtr.Zero || delta == 0)
        {
            return false;
        }

        IntPtr recipient = WalkToDeepestChild(
            target,
            parent => ChildAtScreenPoint(parent, screenX, screenY));
        return NativeWin32.PostMessage(
            recipient,
            NativeWin32.WM_MOUSEWHEEL,
            EncodeWheelWParam(delta),
            EncodePointLParam(screenX, screenY));
    }

    internal static IntPtr WalkToDeepestChild(
        IntPtr root,
        Func<IntPtr, IntPtr> childAtPoint)
    {
        if (root == IntPtr.Zero)
        {
            return IntPtr.Zero;
        }

        var visited = new HashSet<IntPtr> { root };
        IntPtr current = root;
        for (int depth = 0; depth < MaximumChildDepth; depth++)
        {
            IntPtr child = childAtPoint(current);
            if (child == IntPtr.Zero || child == current || !visited.Add(child))
            {
                break;
            }
            current = child;
        }
        return current;
    }

    private static IntPtr ChildAtScreenPoint(IntPtr parent, int screenX, int screenY)
    {
        var point = new NativeWin32.POINT { X = screenX, Y = screenY };
        if (!NativeWin32.ScreenToClient(parent, ref point))
        {
            return IntPtr.Zero;
        }
        return NativeWin32.ChildWindowFromPointEx(
            parent,
            point,
            NativeWin32.CWP_SKIPINVISIBLE
                | NativeWin32.CWP_SKIPDISABLED
                | NativeWin32.CWP_SKIPTRANSPARENT);
    }

    public static IntPtr EncodeWheelWParam(int delta) =>
        new(unchecked((long)(uint)(delta << 16)));

    public static IntPtr EncodePointLParam(int screenX, int screenY) =>
        new(unchecked((long)(uint)(((ushort)screenY << 16) | (ushort)screenX)));
}
