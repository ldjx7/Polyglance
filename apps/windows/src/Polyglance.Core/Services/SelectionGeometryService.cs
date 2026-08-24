using Polyglance.Core.Models;
using Polyglance.Core.Native;

namespace Polyglance.Core.Services;

public static class SelectionGeometryService
{
    private const int Success = 0;

    public static NativeRect SelectionRect(NativePoint start, NativePoint end, NativeRect bounds)
    {
        EnsureSuccess(NativeMethods.polyglance_selection_rect(start, end, bounds, out NativeRect result));
        return result;
    }

    public static NativeSelectionEditTarget EditTarget(
        NativePoint point,
        NativeRect selection,
        double handleTolerance)
    {
        EnsureSuccess(NativeMethods.polyglance_selection_edit_target(
            point,
            selection,
            handleTolerance,
            out int target));
        return Enum.IsDefined(typeof(NativeSelectionEditTarget), target)
            ? (NativeSelectionEditTarget)target
            : NativeSelectionEditTarget.None;
    }

    public static NativeRect ExpandedToward(
        NativeRect selection,
        NativePoint point,
        NativeRect bounds)
    {
        EnsureSuccess(NativeMethods.polyglance_selection_expanded_toward(
            selection,
            point,
            bounds,
            out NativeRect result));
        return result;
    }

    public static NativeRect Edited(
        NativeRect original,
        NativePoint dragStart,
        NativePoint current,
        NativeSelectionEditTarget target,
        NativeRect bounds,
        double minimumSide)
    {
        EnsureSuccess(NativeMethods.polyglance_selection_edited(
            original,
            dragStart,
            current,
            (int)target,
            bounds,
            minimumSide,
            out NativeRect result));
        return result;
    }

    private static void EnsureSuccess(int status)
    {
        if (status != Success)
            throw new InvalidOperationException($"共享截图几何计算失败（错误码：{status}）。");
    }
}
