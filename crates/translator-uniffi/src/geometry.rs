//! Swift-facing mirror of `capture_core::geometry`.
//!
//! `capture-core` stays free of FFI concerns so non-Apple frontends can link it
//! directly, so the uniffi record/enum shapes live here instead.

use capture_core::geometry as core;
use capture_core::rect::{Point as CorePoint, Rect as CoreRect, Size as CoreSize};

#[derive(Clone, Copy, Debug, uniffi::Record)]
pub struct CapturePoint {
    pub x: f64,
    pub y: f64,
}

#[derive(Clone, Copy, Debug, uniffi::Record)]
pub struct CaptureSize {
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Copy, Debug, uniffi::Record)]
pub struct CaptureRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum CaptureResizeHandle {
    TopLeft,
    Top,
    TopRight,
    Right,
    BottomRight,
    Bottom,
    BottomLeft,
    Left,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum CaptureEditTarget {
    Move,
    Resize { handle: CaptureResizeHandle },
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum CaptureKeyboardDirection {
    Left,
    Right,
    Up,
    Down,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum CaptureKeyboardOperation {
    Move,
    Shrink,
    Expand,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum CaptureKeyboardStep {
    Standard,
    Accelerated,
}

#[derive(Clone, Copy, Debug, uniffi::Record)]
pub struct CaptureKeyboardAdjustment {
    pub direction: CaptureKeyboardDirection,
    pub operation: CaptureKeyboardOperation,
    pub step: CaptureKeyboardStep,
}

impl From<CapturePoint> for CorePoint {
    fn from(value: CapturePoint) -> Self {
        Self::new(value.x, value.y)
    }
}

impl From<CorePoint> for CapturePoint {
    fn from(value: CorePoint) -> Self {
        Self {
            x: value.x,
            y: value.y,
        }
    }
}

impl From<CaptureSize> for CoreSize {
    fn from(value: CaptureSize) -> Self {
        Self::new(value.width, value.height)
    }
}

impl From<CoreSize> for CaptureSize {
    fn from(value: CoreSize) -> Self {
        Self {
            width: value.width,
            height: value.height,
        }
    }
}

impl From<CaptureRect> for CoreRect {
    fn from(value: CaptureRect) -> Self {
        Self::new(value.x, value.y, value.width, value.height)
    }
}

impl From<CoreRect> for CaptureRect {
    fn from(value: CoreRect) -> Self {
        Self {
            x: value.x,
            y: value.y,
            width: value.width,
            height: value.height,
        }
    }
}

impl From<CaptureResizeHandle> for core::ResizeHandle {
    fn from(value: CaptureResizeHandle) -> Self {
        match value {
            CaptureResizeHandle::TopLeft => Self::TopLeft,
            CaptureResizeHandle::Top => Self::Top,
            CaptureResizeHandle::TopRight => Self::TopRight,
            CaptureResizeHandle::Right => Self::Right,
            CaptureResizeHandle::BottomRight => Self::BottomRight,
            CaptureResizeHandle::Bottom => Self::Bottom,
            CaptureResizeHandle::BottomLeft => Self::BottomLeft,
            CaptureResizeHandle::Left => Self::Left,
        }
    }
}

impl From<core::ResizeHandle> for CaptureResizeHandle {
    fn from(value: core::ResizeHandle) -> Self {
        match value {
            core::ResizeHandle::TopLeft => Self::TopLeft,
            core::ResizeHandle::Top => Self::Top,
            core::ResizeHandle::TopRight => Self::TopRight,
            core::ResizeHandle::Right => Self::Right,
            core::ResizeHandle::BottomRight => Self::BottomRight,
            core::ResizeHandle::Bottom => Self::Bottom,
            core::ResizeHandle::BottomLeft => Self::BottomLeft,
            core::ResizeHandle::Left => Self::Left,
        }
    }
}

impl From<CaptureEditTarget> for core::SelectionEditTarget {
    fn from(value: CaptureEditTarget) -> Self {
        match value {
            CaptureEditTarget::Move => Self::Move,
            CaptureEditTarget::Resize { handle } => Self::Resize(handle.into()),
        }
    }
}

impl From<core::SelectionEditTarget> for CaptureEditTarget {
    fn from(value: core::SelectionEditTarget) -> Self {
        match value {
            core::SelectionEditTarget::Move => Self::Move,
            core::SelectionEditTarget::Resize(handle) => Self::Resize {
                handle: handle.into(),
            },
        }
    }
}

impl From<CaptureKeyboardAdjustment> for core::KeyboardAdjustment {
    fn from(value: CaptureKeyboardAdjustment) -> Self {
        Self {
            direction: match value.direction {
                CaptureKeyboardDirection::Left => core::KeyboardDirection::Left,
                CaptureKeyboardDirection::Right => core::KeyboardDirection::Right,
                CaptureKeyboardDirection::Up => core::KeyboardDirection::Up,
                CaptureKeyboardDirection::Down => core::KeyboardDirection::Down,
            },
            operation: match value.operation {
                CaptureKeyboardOperation::Move => core::KeyboardOperation::Move,
                CaptureKeyboardOperation::Shrink => core::KeyboardOperation::Shrink,
                CaptureKeyboardOperation::Expand => core::KeyboardOperation::Expand,
            },
            step: match value.step {
                CaptureKeyboardStep::Standard => core::KeyboardStep::Standard,
                CaptureKeyboardStep::Accelerated => core::KeyboardStep::Accelerated,
            },
        }
    }
}

#[uniffi::export]
pub fn capture_selection_rect(
    start: CapturePoint,
    end: CapturePoint,
    bounds: CaptureRect,
) -> CaptureRect {
    core::selection_rect(start.into(), end.into(), bounds.into()).into()
}

#[uniffi::export]
pub fn capture_pixel_crop_rect(
    selection: CaptureRect,
    view_size: CaptureSize,
    image_pixel_size: CaptureSize,
) -> CaptureRect {
    core::pixel_crop_rect(selection.into(), view_size.into(), image_pixel_size.into()).into()
}

#[uniffi::export]
pub fn capture_output_pixel_size(
    selection: CaptureRect,
    view_size: CaptureSize,
    image_pixel_size: CaptureSize,
) -> CaptureSize {
    core::output_pixel_size(selection.into(), view_size.into(), image_pixel_size.into()).into()
}

#[uniffi::export]
pub fn capture_is_usable(selection: CaptureRect, minimum_side: f64) -> bool {
    core::is_usable(selection.into(), minimum_side)
}

#[uniffi::export]
pub fn capture_fitted_pin_size(image_size: CaptureSize, maximum_size: CaptureSize) -> CaptureSize {
    core::fitted_pin_size(image_size.into(), maximum_size.into()).into()
}

#[uniffi::export]
pub fn capture_preferred_capture_pixel_size(
    screen_point_size: CaptureSize,
    backing_scale_factor: f64,
    reported_pixel_size: CaptureSize,
) -> CaptureSize {
    core::preferred_capture_pixel_size(
        screen_point_size.into(),
        backing_scale_factor,
        reported_pixel_size.into(),
    )
    .into()
}

#[uniffi::export]
pub fn capture_toolbar_origin(
    selection: CaptureRect,
    toolbar_size: CaptureSize,
    bounds: CaptureRect,
    spacing: f64,
    edge_inset: f64,
) -> CapturePoint {
    core::toolbar_origin(
        selection.into(),
        toolbar_size.into(),
        bounds.into(),
        spacing,
        edge_inset,
    )
    .into()
}

#[uniffi::export]
pub fn capture_fitted_toolbar_size(
    preferred: CaptureSize,
    bounds: CaptureRect,
    edge_inset: f64,
) -> CaptureSize {
    core::fitted_toolbar_size(preferred.into(), bounds.into(), edge_inset).into()
}

#[uniffi::export]
pub fn capture_annotation_pixel_point(
    point: CapturePoint,
    selection: CaptureRect,
    image_pixel_size: CaptureSize,
) -> CapturePoint {
    core::annotation_pixel_point(point.into(), selection.into(), image_pixel_size.into()).into()
}

#[uniffi::export]
pub fn capture_selection_edit_target(
    point: CapturePoint,
    selection: CaptureRect,
    handle_tolerance: f64,
) -> Option<CaptureEditTarget> {
    core::selection_edit_target(point.into(), selection.into(), handle_tolerance).map(Into::into)
}

#[uniffi::export]
pub fn capture_selection_expansion_target(
    point: CapturePoint,
    selection: CaptureRect,
) -> Option<CaptureEditTarget> {
    core::selection_expansion_target(point.into(), selection.into()).map(Into::into)
}

#[uniffi::export]
pub fn capture_expanded_selection_toward(
    selection: CaptureRect,
    point: CapturePoint,
    bounds: CaptureRect,
) -> CaptureRect {
    core::expanded_selection_toward(selection.into(), point.into(), bounds.into()).into()
}

#[uniffi::export]
pub fn capture_expanded_selection(
    selection: CaptureRect,
    point: CapturePoint,
    target: CaptureEditTarget,
    bounds: CaptureRect,
) -> CaptureRect {
    core::expanded_selection(selection.into(), point.into(), target.into(), bounds.into()).into()
}

#[uniffi::export]
pub fn capture_edited_selection(
    original: CaptureRect,
    drag_start: CapturePoint,
    current: CapturePoint,
    target: CaptureEditTarget,
    bounds: CaptureRect,
    minimum_side: f64,
) -> CaptureRect {
    core::edited_selection(
        original.into(),
        drag_start.into(),
        current.into(),
        target.into(),
        bounds.into(),
        minimum_side,
    )
    .into()
}

#[uniffi::export]
pub fn capture_adjusted_selection(
    selection: CaptureRect,
    adjustment: CaptureKeyboardAdjustment,
    bounds: CaptureRect,
    minimum_side: f64,
    pixels_per_point: f64,
) -> CaptureRect {
    core::adjusted_selection(
        selection.into(),
        adjustment.into(),
        bounds.into(),
        minimum_side,
        pixels_per_point,
    )
    .into()
}
