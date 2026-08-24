//! C ABI adapters for capture geometry.
//!
//! Windows desktop coordinates grow downward, so the public target names in
//! this module use WPF's top-left convention and are mapped to capture-core's
//! platform-neutral rectangle math internally.

use capture_core::geometry;
use capture_core::rect::{Point, Rect};
use capture_core::{ResizeHandle, SelectionEditTarget};

use crate::{POLYGLANCE_ERR_INVALID_INPUT, POLYGLANCE_ERR_NULL_PTR, POLYGLANCE_OK, ffi_status};

pub const POLYGLANCE_SELECTION_NONE: i32 = 0;
pub const POLYGLANCE_SELECTION_MOVE: i32 = 1;
pub const POLYGLANCE_SELECTION_RESIZE_TOP_LEFT: i32 = 2;
pub const POLYGLANCE_SELECTION_RESIZE_TOP: i32 = 3;
pub const POLYGLANCE_SELECTION_RESIZE_TOP_RIGHT: i32 = 4;
pub const POLYGLANCE_SELECTION_RESIZE_RIGHT: i32 = 5;
pub const POLYGLANCE_SELECTION_RESIZE_BOTTOM_RIGHT: i32 = 6;
pub const POLYGLANCE_SELECTION_RESIZE_BOTTOM: i32 = 7;
pub const POLYGLANCE_SELECTION_RESIZE_BOTTOM_LEFT: i32 = 8;
pub const POLYGLANCE_SELECTION_RESIZE_LEFT: i32 = 9;
pub const POLYGLANCE_SELECTION_EXPAND: i32 = 10;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CPoint {
    pub x: f64,
    pub y: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl CPoint {
    fn is_finite(self) -> bool {
        self.x.is_finite() && self.y.is_finite()
    }
}

impl CRect {
    fn is_finite(self) -> bool {
        self.x.is_finite()
            && self.y.is_finite()
            && self.width.is_finite()
            && self.height.is_finite()
    }
}

impl From<CPoint> for Point {
    fn from(value: CPoint) -> Self {
        Self::new(value.x, value.y)
    }
}

impl From<CRect> for Rect {
    fn from(value: CRect) -> Self {
        Self::new(value.x, value.y, value.width, value.height)
    }
}

impl From<Rect> for CRect {
    fn from(value: Rect) -> Self {
        Self {
            x: value.x,
            y: value.y,
            width: value.width,
            height: value.height,
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_selection_rect(
    start: CPoint,
    end: CPoint,
    bounds: CRect,
    out_rect: *mut CRect,
) -> i32 {
    ffi_status(|| unsafe { selection_rect(start, end, bounds, out_rect) })
}

unsafe fn selection_rect(start: CPoint, end: CPoint, bounds: CRect, out_rect: *mut CRect) -> i32 {
    if out_rect.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }
    if !start.is_finite() || !end.is_finite() || !bounds.is_finite() {
        return POLYGLANCE_ERR_INVALID_INPUT;
    }

    unsafe {
        *out_rect = geometry::selection_rect(start.into(), end.into(), bounds.into()).into();
    }
    POLYGLANCE_OK
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_selection_edit_target(
    point: CPoint,
    selection: CRect,
    handle_tolerance: f64,
    out_target: *mut i32,
) -> i32 {
    ffi_status(|| unsafe { selection_edit_target(point, selection, handle_tolerance, out_target) })
}

unsafe fn selection_edit_target(
    point: CPoint,
    selection: CRect,
    handle_tolerance: f64,
    out_target: *mut i32,
) -> i32 {
    if out_target.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }
    if !point.is_finite()
        || !selection.is_finite()
        || !handle_tolerance.is_finite()
        || handle_tolerance < 0.0
    {
        return POLYGLANCE_ERR_INVALID_INPUT;
    }

    let target = geometry::selection_edit_target(point.into(), selection.into(), handle_tolerance)
        .map(windows_target_from_core)
        .or_else(|| {
            geometry::selection_expansion_target(point.into(), selection.into())
                .map(|_| POLYGLANCE_SELECTION_EXPAND)
        })
        .unwrap_or(POLYGLANCE_SELECTION_NONE);
    unsafe {
        *out_target = target;
    }
    POLYGLANCE_OK
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_selection_expanded_toward(
    selection: CRect,
    point: CPoint,
    bounds: CRect,
    out_rect: *mut CRect,
) -> i32 {
    ffi_status(|| unsafe { selection_expanded_toward(selection, point, bounds, out_rect) })
}

unsafe fn selection_expanded_toward(
    selection: CRect,
    point: CPoint,
    bounds: CRect,
    out_rect: *mut CRect,
) -> i32 {
    if out_rect.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }
    if !selection.is_finite() || !point.is_finite() || !bounds.is_finite() {
        return POLYGLANCE_ERR_INVALID_INPUT;
    }

    unsafe {
        *out_rect =
            geometry::expanded_selection_toward(selection.into(), point.into(), bounds.into())
                .into();
    }
    POLYGLANCE_OK
}

#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn polyglance_selection_edited(
    original: CRect,
    drag_start: CPoint,
    current: CPoint,
    target: i32,
    bounds: CRect,
    minimum_side: f64,
    out_rect: *mut CRect,
) -> i32 {
    ffi_status(|| unsafe {
        selection_edited(
            original,
            drag_start,
            current,
            target,
            bounds,
            minimum_side,
            out_rect,
        )
    })
}

#[allow(clippy::too_many_arguments)]
unsafe fn selection_edited(
    original: CRect,
    drag_start: CPoint,
    current: CPoint,
    target: i32,
    bounds: CRect,
    minimum_side: f64,
    out_rect: *mut CRect,
) -> i32 {
    if out_rect.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }
    if !original.is_finite()
        || !drag_start.is_finite()
        || !current.is_finite()
        || !bounds.is_finite()
        || !minimum_side.is_finite()
        || minimum_side <= 0.0
    {
        return POLYGLANCE_ERR_INVALID_INPUT;
    }
    let Some(core_target) = core_target_from_windows(target) else {
        return POLYGLANCE_ERR_INVALID_INPUT;
    };

    unsafe {
        *out_rect = geometry::edited_selection(
            original.into(),
            drag_start.into(),
            current.into(),
            core_target,
            bounds.into(),
            minimum_side,
        )
        .into();
    }
    POLYGLANCE_OK
}

fn windows_target_from_core(target: SelectionEditTarget) -> i32 {
    match target {
        SelectionEditTarget::Move => POLYGLANCE_SELECTION_MOVE,
        SelectionEditTarget::Resize(ResizeHandle::BottomLeft) => {
            POLYGLANCE_SELECTION_RESIZE_TOP_LEFT
        }
        SelectionEditTarget::Resize(ResizeHandle::Bottom) => POLYGLANCE_SELECTION_RESIZE_TOP,
        SelectionEditTarget::Resize(ResizeHandle::BottomRight) => {
            POLYGLANCE_SELECTION_RESIZE_TOP_RIGHT
        }
        SelectionEditTarget::Resize(ResizeHandle::Right) => POLYGLANCE_SELECTION_RESIZE_RIGHT,
        SelectionEditTarget::Resize(ResizeHandle::TopRight) => {
            POLYGLANCE_SELECTION_RESIZE_BOTTOM_RIGHT
        }
        SelectionEditTarget::Resize(ResizeHandle::Top) => POLYGLANCE_SELECTION_RESIZE_BOTTOM,
        SelectionEditTarget::Resize(ResizeHandle::TopLeft) => {
            POLYGLANCE_SELECTION_RESIZE_BOTTOM_LEFT
        }
        SelectionEditTarget::Resize(ResizeHandle::Left) => POLYGLANCE_SELECTION_RESIZE_LEFT,
    }
}

fn core_target_from_windows(target: i32) -> Option<SelectionEditTarget> {
    Some(match target {
        POLYGLANCE_SELECTION_MOVE => SelectionEditTarget::Move,
        POLYGLANCE_SELECTION_RESIZE_TOP_LEFT => {
            SelectionEditTarget::Resize(ResizeHandle::BottomLeft)
        }
        POLYGLANCE_SELECTION_RESIZE_TOP => SelectionEditTarget::Resize(ResizeHandle::Bottom),
        POLYGLANCE_SELECTION_RESIZE_TOP_RIGHT => {
            SelectionEditTarget::Resize(ResizeHandle::BottomRight)
        }
        POLYGLANCE_SELECTION_RESIZE_RIGHT => SelectionEditTarget::Resize(ResizeHandle::Right),
        POLYGLANCE_SELECTION_RESIZE_BOTTOM_RIGHT => {
            SelectionEditTarget::Resize(ResizeHandle::TopRight)
        }
        POLYGLANCE_SELECTION_RESIZE_BOTTOM => SelectionEditTarget::Resize(ResizeHandle::Top),
        POLYGLANCE_SELECTION_RESIZE_BOTTOM_LEFT => {
            SelectionEditTarget::Resize(ResizeHandle::TopLeft)
        }
        POLYGLANCE_SELECTION_RESIZE_LEFT => SelectionEditTarget::Resize(ResizeHandle::Left),
        _ => return None,
    })
}
