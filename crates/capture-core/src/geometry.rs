//! Selection, crop, and chrome placement math shared by every platform.

use crate::rect::{Point, Rect, Size};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResizeHandle {
    TopLeft,
    Top,
    TopRight,
    Right,
    BottomRight,
    Bottom,
    BottomLeft,
    Left,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SelectionEditTarget {
    Move,
    Resize(ResizeHandle),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyboardDirection {
    Left,
    Right,
    Up,
    Down,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyboardOperation {
    Move,
    Shrink,
    Expand,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyboardStep {
    Standard,
    Accelerated,
}

impl KeyboardStep {
    pub fn points(self) -> f64 {
        match self {
            Self::Standard => 1.0,
            Self::Accelerated => 10.0,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KeyboardAdjustment {
    pub direction: KeyboardDirection,
    pub operation: KeyboardOperation,
    pub step: KeyboardStep,
}

pub const DEFAULT_MINIMUM_SIDE: f64 = 4.0;
pub const DEFAULT_HANDLE_TOLERANCE: f64 = 6.0;
pub const DEFAULT_TOOLBAR_SPACING: f64 = 8.0;
pub const DEFAULT_TOOLBAR_EDGE_INSET: f64 = 8.0;

pub fn selection_rect(start: Point, end: Point, bounds: Rect) -> Rect {
    let start = start.clamped_to(bounds);
    let end = end.clamped_to(bounds);
    Rect::new(
        start.x.min(end.x),
        start.y.min(end.y),
        (end.x - start.x).abs(),
        (end.y - start.y).abs(),
    )
}

pub fn pixel_crop_rect(selection: Rect, view_size: Size, image_pixel_size: Size) -> Rect {
    if view_size.width <= 0.0
        || view_size.height <= 0.0
        || image_pixel_size.width <= 0.0
        || image_pixel_size.height <= 0.0
    {
        return Rect::ZERO;
    }

    let view_bounds = Rect::from_origin_size(Point::ZERO, view_size);
    let clipped = selection.standardized().intersection(view_bounds);
    if clipped.is_null() {
        return Rect::ZERO;
    }

    let scale_x = image_pixel_size.width / view_size.width;
    let scale_y = image_pixel_size.height / view_size.height;
    let crop = Rect::new(
        clipped.min_x() * scale_x,
        (view_size.height - clipped.max_y()) * scale_y,
        clipped.width * scale_x,
        clipped.height * scale_y,
    )
    .integral();
    crop.intersection(Rect::from_origin_size(Point::ZERO, image_pixel_size))
}

pub fn output_pixel_size(selection: Rect, view_size: Size, image_pixel_size: Size) -> Size {
    pixel_crop_rect(selection, view_size, image_pixel_size).size()
}

pub fn is_usable(selection: Rect, minimum_side: f64) -> bool {
    selection.width >= minimum_side && selection.height >= minimum_side
}

pub fn fitted_pin_size(image_size: Size, maximum_size: Size) -> Size {
    if image_size.width <= 0.0
        || image_size.height <= 0.0
        || maximum_size.width <= 0.0
        || maximum_size.height <= 0.0
    {
        return Size::ZERO;
    }

    let scale = 1.0_f64
        .min(maximum_size.width / image_size.width)
        .min(maximum_size.height / image_size.height);
    Size::new(image_size.width * scale, image_size.height * scale)
}

pub fn preferred_capture_pixel_size(
    screen_point_size: Size,
    backing_scale_factor: f64,
    reported_pixel_size: Size,
) -> Size {
    let scaled_width = (screen_point_size.width * backing_scale_factor).ceil();
    let scaled_height = (screen_point_size.height * backing_scale_factor).ceil();
    Size::new(
        scaled_width.max(reported_pixel_size.width),
        scaled_height.max(reported_pixel_size.height),
    )
}

pub fn toolbar_origin(
    selection: Rect,
    toolbar_size: Size,
    bounds: Rect,
    spacing: f64,
    edge_inset: f64,
) -> Point {
    let maximum_x =
        (bounds.min_x() + edge_inset).max(bounds.max_x() - toolbar_size.width - edge_inset);
    let x = (selection.max_x() - toolbar_size.width)
        .max(bounds.min_x() + edge_inset)
        .min(maximum_x);
    let below_y = selection.min_y() - toolbar_size.height - spacing;
    let y = if below_y >= bounds.min_y() + edge_inset {
        below_y
    } else {
        let above_y = selection.max_y() + spacing;
        if above_y + toolbar_size.height <= bounds.max_y() - edge_inset {
            above_y
        } else {
            // 上下间距都不够在外部展示：改到选区内部下方
            (selection.min_y() + spacing)
                .max(bounds.min_y() + edge_inset)
                .min(bounds.max_y() - toolbar_size.height - edge_inset)
        }
    };
    Point::new(x, y)
}

pub fn fitted_toolbar_size(preferred: Size, bounds: Rect, edge_inset: f64) -> Size {
    let bounds = bounds.standardized();
    if preferred.width <= 0.0 || preferred.height <= 0.0 || bounds.is_empty() {
        return Size::ZERO;
    }
    let available_width = 1.0_f64.max(bounds.width - edge_inset.max(0.0) * 2.0);
    let available_height = 1.0_f64.max(bounds.height - edge_inset.max(0.0) * 2.0);
    Size::new(
        preferred.width.min(available_width),
        preferred.height.min(available_height),
    )
}

pub fn annotation_pixel_point(point: Point, selection: Rect, image_pixel_size: Size) -> Point {
    if selection.width <= 0.0 || selection.height <= 0.0 {
        return Point::ZERO;
    }
    Point::new(
        (point.x - selection.min_x()) * image_pixel_size.width / selection.width,
        (point.y - selection.min_y()) * image_pixel_size.height / selection.height,
    )
}

pub fn selection_edit_target(
    point: Point,
    selection: Rect,
    handle_tolerance: f64,
) -> Option<SelectionEditTarget> {
    let selection = selection.standardized();
    if !selection
        .inset_by(-handle_tolerance, -handle_tolerance)
        .contains(point)
    {
        return None;
    }

    let distance_to_left = (point.x - selection.min_x()).abs();
    let distance_to_right = (point.x - selection.max_x()).abs();
    let distance_to_bottom = (point.y - selection.min_y()).abs();
    let distance_to_top = (point.y - selection.max_y()).abs();

    let horizontal = if distance_to_left.min(distance_to_right) <= handle_tolerance {
        Some(if distance_to_left <= distance_to_right {
            ResizeHandle::Left
        } else {
            ResizeHandle::Right
        })
    } else {
        None
    };
    let vertical = if distance_to_bottom.min(distance_to_top) <= handle_tolerance {
        Some(if distance_to_bottom <= distance_to_top {
            ResizeHandle::Bottom
        } else {
            ResizeHandle::Top
        })
    } else {
        None
    };

    match combined_handle(horizontal, vertical) {
        Some(handle) => Some(SelectionEditTarget::Resize(handle)),
        None => {
            if selection.contains(point) {
                Some(SelectionEditTarget::Move)
            } else {
                None
            }
        }
    }
}

pub fn selection_expansion_target(point: Point, selection: Rect) -> Option<SelectionEditTarget> {
    let selection = selection.standardized();
    if selection.is_null() || selection.is_empty() {
        return None;
    }
    let horizontal = if point.x < selection.min_x() {
        Some(ResizeHandle::Left)
    } else if point.x > selection.max_x() {
        Some(ResizeHandle::Right)
    } else {
        None
    };
    let vertical = if point.y < selection.min_y() {
        Some(ResizeHandle::Bottom)
    } else if point.y > selection.max_y() {
        Some(ResizeHandle::Top)
    } else {
        None
    };
    combined_handle(horizontal, vertical).map(SelectionEditTarget::Resize)
}

fn combined_handle(
    horizontal: Option<ResizeHandle>,
    vertical: Option<ResizeHandle>,
) -> Option<ResizeHandle> {
    match (horizontal, vertical) {
        (Some(ResizeHandle::Left), Some(ResizeHandle::Top)) => Some(ResizeHandle::TopLeft),
        (Some(ResizeHandle::Right), Some(ResizeHandle::Top)) => Some(ResizeHandle::TopRight),
        (Some(ResizeHandle::Right), Some(ResizeHandle::Bottom)) => Some(ResizeHandle::BottomRight),
        (Some(ResizeHandle::Left), Some(ResizeHandle::Bottom)) => Some(ResizeHandle::BottomLeft),
        (Some(horizontal), None) => Some(horizontal),
        (None, Some(vertical)) => Some(vertical),
        _ => None,
    }
}

pub fn expanded_selection_toward(selection: Rect, point: Point, bounds: Rect) -> Rect {
    match selection_expansion_target(point, selection) {
        Some(target) => expanded_selection(selection, point, target, bounds),
        None => {
            let clipped = selection.standardized().intersection(bounds.standardized());
            if clipped.is_null() {
                Rect::ZERO
            } else {
                clipped
            }
        }
    }
}

pub fn expanded_selection(
    selection: Rect,
    point: Point,
    target: SelectionEditTarget,
    bounds: Rect,
) -> Rect {
    let bounds = bounds.standardized();
    let selection = selection.standardized().intersection(bounds);
    if selection.is_null() || selection.is_empty() {
        return Rect::ZERO;
    }
    let point = point.clamped_to(bounds);
    let SelectionEditTarget::Resize(handle) = target else {
        return selection;
    };
    let (expands_left, expands_right, expands_bottom, expands_top) = match handle {
        ResizeHandle::TopLeft => (true, false, false, true),
        ResizeHandle::Top => (false, false, false, true),
        ResizeHandle::TopRight => (false, true, false, true),
        ResizeHandle::Right => (false, true, false, false),
        ResizeHandle::BottomRight => (false, true, true, false),
        ResizeHandle::Bottom => (false, false, true, false),
        ResizeHandle::BottomLeft => (true, false, true, false),
        ResizeHandle::Left => (true, false, false, false),
    };
    let minimum_x = if expands_left {
        selection.min_x().min(point.x)
    } else {
        selection.min_x()
    };
    let maximum_x = if expands_right {
        selection.max_x().max(point.x)
    } else {
        selection.max_x()
    };
    let minimum_y = if expands_bottom {
        selection.min_y().min(point.y)
    } else {
        selection.min_y()
    };
    let maximum_y = if expands_top {
        selection.max_y().max(point.y)
    } else {
        selection.max_y()
    };
    Rect::new(
        minimum_x,
        minimum_y,
        maximum_x - minimum_x,
        maximum_y - minimum_y,
    )
}

pub fn edited_selection(
    original: Rect,
    drag_start: Point,
    current: Point,
    target: SelectionEditTarget,
    bounds: Rect,
    minimum_side: f64,
) -> Rect {
    let original = original.standardized();
    let bounds = bounds.standardized();

    match target {
        SelectionEditTarget::Move => {
            let proposed_x = original.min_x() + current.x - drag_start.x;
            let proposed_y = original.min_y() + current.y - drag_start.y;
            let maximum_x = bounds.min_x().max(bounds.max_x() - original.width);
            let maximum_y = bounds.min_y().max(bounds.max_y() - original.height);
            Rect::from_origin_size(
                Point::new(
                    clamp(proposed_x, bounds.min_x(), maximum_x),
                    clamp(proposed_y, bounds.min_y(), maximum_y),
                ),
                original.size(),
            )
        }
        SelectionEditTarget::Resize(handle) => {
            let delta_x = current.x - drag_start.x;
            let delta_y = current.y - drag_start.y;
            let mut minimum_x = original.min_x();
            let mut maximum_x = original.max_x();
            let mut minimum_y = original.min_y();
            let mut maximum_y = original.max_y();

            match handle {
                ResizeHandle::TopLeft | ResizeHandle::Left | ResizeHandle::BottomLeft => {
                    minimum_x = clamp(
                        original.min_x() + delta_x,
                        bounds.min_x(),
                        original.max_x() - minimum_side,
                    );
                }
                ResizeHandle::TopRight | ResizeHandle::Right | ResizeHandle::BottomRight => {
                    maximum_x = clamp(
                        original.max_x() + delta_x,
                        original.min_x() + minimum_side,
                        bounds.max_x(),
                    );
                }
                ResizeHandle::Top | ResizeHandle::Bottom => {}
            }

            match handle {
                ResizeHandle::BottomLeft | ResizeHandle::Bottom | ResizeHandle::BottomRight => {
                    minimum_y = clamp(
                        original.min_y() + delta_y,
                        bounds.min_y(),
                        original.max_y() - minimum_side,
                    );
                }
                ResizeHandle::TopLeft | ResizeHandle::Top | ResizeHandle::TopRight => {
                    maximum_y = clamp(
                        original.max_y() + delta_y,
                        original.min_y() + minimum_side,
                        bounds.max_y(),
                    );
                }
                ResizeHandle::Left | ResizeHandle::Right => {}
            }

            Rect::new(
                minimum_x,
                minimum_y,
                maximum_x - minimum_x,
                maximum_y - minimum_y,
            )
        }
    }
}

pub fn adjusted_selection(
    selection: Rect,
    adjustment: KeyboardAdjustment,
    bounds: Rect,
    minimum_side: f64,
    pixels_per_point: f64,
) -> Rect {
    let bounds = bounds.standardized();
    if bounds.is_empty() {
        return Rect::ZERO;
    }
    let selection = selection.standardized().intersection(bounds);
    if selection.is_empty() {
        return Rect::ZERO;
    }

    let effective_pixels_per_point = if pixels_per_point.is_finite() && pixels_per_point > 0.0 {
        pixels_per_point
    } else {
        1.0
    };
    let distance = adjustment.step.points() / effective_pixels_per_point;

    match adjustment.operation {
        KeyboardOperation::Move => {
            let (delta_x, delta_y) = match adjustment.direction {
                KeyboardDirection::Left => (-distance, 0.0),
                KeyboardDirection::Right => (distance, 0.0),
                KeyboardDirection::Up => (0.0, distance),
                KeyboardDirection::Down => (0.0, -distance),
            };
            Rect::new(
                clamp(
                    selection.min_x() + delta_x,
                    bounds.min_x(),
                    bounds.max_x() - selection.width,
                ),
                clamp(
                    selection.min_y() + delta_y,
                    bounds.min_y(),
                    bounds.max_y() - selection.height,
                ),
                selection.width,
                selection.height,
            )
        }
        KeyboardOperation::Shrink => {
            let requested_minimum_side = if minimum_side.is_finite() && minimum_side > 0.0 {
                minimum_side
            } else {
                1.0
            };
            let minimum_width = selection.width.min(requested_minimum_side);
            let minimum_height = selection.height.min(requested_minimum_side);
            let mut minimum_x = selection.min_x();
            let mut maximum_x = selection.max_x();
            let mut minimum_y = selection.min_y();
            let mut maximum_y = selection.max_y();

            match adjustment.direction {
                KeyboardDirection::Left => {
                    minimum_x += distance.min(selection.width - minimum_width);
                }
                KeyboardDirection::Right => {
                    maximum_x -= distance.min(selection.width - minimum_width);
                }
                KeyboardDirection::Up => {
                    maximum_y -= distance.min(selection.height - minimum_height);
                }
                KeyboardDirection::Down => {
                    minimum_y += distance.min(selection.height - minimum_height);
                }
            }
            Rect::new(
                minimum_x,
                minimum_y,
                maximum_x - minimum_x,
                maximum_y - minimum_y,
            )
        }
        KeyboardOperation::Expand => {
            let mut minimum_x = selection.min_x();
            let mut maximum_x = selection.max_x();
            let mut minimum_y = selection.min_y();
            let mut maximum_y = selection.max_y();

            match adjustment.direction {
                KeyboardDirection::Left => {
                    minimum_x = bounds.min_x().max(minimum_x - distance);
                }
                KeyboardDirection::Right => {
                    maximum_x = bounds.max_x().min(maximum_x + distance);
                }
                KeyboardDirection::Up => {
                    maximum_y = bounds.max_y().min(maximum_y + distance);
                }
                KeyboardDirection::Down => {
                    minimum_y = bounds.min_y().max(minimum_y - distance);
                }
            }
            Rect::new(
                minimum_x,
                minimum_y,
                maximum_x - minimum_x,
                maximum_y - minimum_y,
            )
        }
    }
}

fn clamp(value: f64, minimum: f64, maximum: f64) -> f64 {
    value.max(minimum).min(maximum)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bounds() -> Rect {
        Rect::new(0.0, 0.0, 320.0, 200.0)
    }

    #[test]
    fn selection_is_clamped_to_bounds_and_normalized() {
        let rect = selection_rect(Point::new(-40.0, 260.0), Point::new(120.0, 40.0), bounds());

        assert_eq!(rect, Rect::new(0.0, 40.0, 120.0, 160.0));
    }

    #[test]
    fn crop_flips_to_top_left_pixels_and_stays_inside_the_image() {
        let crop = pixel_crop_rect(
            Rect::new(10.0, 20.0, 100.0, 50.0),
            Size::new(320.0, 200.0),
            Size::new(640.0, 400.0),
        );

        assert_eq!(crop, Rect::new(20.0, 260.0, 200.0, 100.0));
    }

    #[test]
    fn crop_returns_zero_for_degenerate_input() {
        assert_eq!(
            pixel_crop_rect(bounds(), Size::ZERO, Size::new(10.0, 10.0)),
            Rect::ZERO
        );
        assert_eq!(
            pixel_crop_rect(
                Rect::new(400.0, 0.0, 10.0, 10.0),
                Size::new(320.0, 200.0),
                Size::new(320.0, 200.0)
            ),
            Rect::ZERO
        );
    }

    #[test]
    fn toolbar_hugs_the_selection_trailing_edge_and_clamps_to_screen() {
        let origin = toolbar_origin(
            Rect::new(280.0, 80.0, 40.0, 50.0),
            Size::new(140.0, 36.0),
            bounds(),
            DEFAULT_TOOLBAR_SPACING,
            DEFAULT_TOOLBAR_EDGE_INSET,
        );

        assert_eq!(origin, Point::new(172.0, 36.0));
    }

    #[test]
    fn toolbar_moves_above_when_there_is_no_room_below() {
        let origin = toolbar_origin(
            Rect::new(20.0, 10.0, 100.0, 40.0),
            Size::new(140.0, 36.0),
            bounds(),
            DEFAULT_TOOLBAR_SPACING,
            DEFAULT_TOOLBAR_EDGE_INSET,
        );

        assert_eq!(origin, Point::new(8.0, 58.0));
    }

    #[test]
    fn toolbar_moves_inside_selection_at_bottom_when_there_is_no_room_above_or_below() {
        let origin = toolbar_origin(
            Rect::new(20.0, 10.0, 100.0, 185.0),
            Size::new(140.0, 36.0),
            bounds(),
            DEFAULT_TOOLBAR_SPACING,
            DEFAULT_TOOLBAR_EDGE_INSET,
        );

        // Selection spans from y=10 to y=195 in bounds height 200.
        // No room below (10 - 36 - 8 < 8), no room above (195 + 8 + 36 > 192).
        // Should place inside selection at bottom: y = 10 + 8 = 18.0
        assert_eq!(origin, Point::new(8.0, 18.0));
    }

    #[test]
    fn pin_size_only_shrinks() {
        assert_eq!(
            fitted_pin_size(Size::new(200.0, 100.0), Size::new(100.0, 100.0)),
            Size::new(100.0, 50.0)
        );
        assert_eq!(
            fitted_pin_size(Size::new(50.0, 50.0), Size::new(100.0, 100.0)),
            Size::new(50.0, 50.0)
        );
    }

    #[test]
    fn corner_hits_win_over_single_edges() {
        let selection = Rect::new(50.0, 50.0, 100.0, 100.0);

        assert_eq!(
            selection_edit_target(Point::new(50.0, 150.0), selection, DEFAULT_HANDLE_TOLERANCE),
            Some(SelectionEditTarget::Resize(ResizeHandle::TopLeft))
        );
        assert_eq!(
            selection_edit_target(
                Point::new(100.0, 150.0),
                selection,
                DEFAULT_HANDLE_TOLERANCE
            ),
            Some(SelectionEditTarget::Resize(ResizeHandle::Top))
        );
        assert_eq!(
            selection_edit_target(
                Point::new(100.0, 100.0),
                selection,
                DEFAULT_HANDLE_TOLERANCE
            ),
            Some(SelectionEditTarget::Move)
        );
        assert_eq!(
            selection_edit_target(Point::new(10.0, 10.0), selection, DEFAULT_HANDLE_TOLERANCE),
            None
        );
    }

    #[test]
    fn clicking_outside_expands_toward_that_corner() {
        let selection = Rect::new(50.0, 50.0, 100.0, 100.0);
        let expanded = expanded_selection_toward(selection, Point::new(20.0, 190.0), bounds());

        assert_eq!(expanded, Rect::new(20.0, 50.0, 130.0, 140.0));
    }

    #[test]
    fn clicking_inside_leaves_the_selection_clipped_to_bounds() {
        let selection = Rect::new(50.0, 50.0, 100.0, 100.0);

        assert_eq!(
            expanded_selection_toward(selection, Point::new(100.0, 100.0), bounds()),
            selection
        );
    }

    #[test]
    fn dragging_a_handle_respects_the_minimum_side() {
        let edited = edited_selection(
            Rect::new(50.0, 50.0, 100.0, 100.0),
            Point::new(50.0, 50.0),
            Point::new(200.0, 50.0),
            SelectionEditTarget::Resize(ResizeHandle::Left),
            bounds(),
            DEFAULT_MINIMUM_SIDE,
        );

        assert_eq!(edited, Rect::new(146.0, 50.0, 4.0, 100.0));
    }

    #[test]
    fn moving_keeps_the_selection_inside_bounds() {
        let edited = edited_selection(
            Rect::new(50.0, 50.0, 100.0, 100.0),
            Point::new(60.0, 60.0),
            Point::new(400.0, 400.0),
            SelectionEditTarget::Move,
            bounds(),
            DEFAULT_MINIMUM_SIDE,
        );

        assert_eq!(edited, Rect::new(220.0, 100.0, 100.0, 100.0));
    }

    #[test]
    fn keyboard_steps_scale_with_pixel_density() {
        let selection = Rect::new(50.0, 50.0, 100.0, 100.0);
        let adjusted = adjusted_selection(
            selection,
            KeyboardAdjustment {
                direction: KeyboardDirection::Right,
                operation: KeyboardOperation::Move,
                step: KeyboardStep::Accelerated,
            },
            bounds(),
            1.0,
            2.0,
        );

        assert_eq!(adjusted, Rect::new(55.0, 50.0, 100.0, 100.0));
    }

    #[test]
    fn shrinking_never_crosses_the_minimum_side() {
        let adjusted = adjusted_selection(
            Rect::new(50.0, 50.0, 3.0, 100.0),
            KeyboardAdjustment {
                direction: KeyboardDirection::Left,
                operation: KeyboardOperation::Shrink,
                step: KeyboardStep::Accelerated,
            },
            bounds(),
            4.0,
            1.0,
        );

        assert_eq!(adjusted.width, 3.0);
    }

    #[test]
    fn expanding_stops_at_the_bounds() {
        let adjusted = adjusted_selection(
            Rect::new(0.0, 0.0, 100.0, 100.0),
            KeyboardAdjustment {
                direction: KeyboardDirection::Left,
                operation: KeyboardOperation::Expand,
                step: KeyboardStep::Accelerated,
            },
            bounds(),
            1.0,
            1.0,
        );

        assert_eq!(adjusted, Rect::new(0.0, 0.0, 100.0, 100.0));
    }

    #[test]
    fn capture_size_never_drops_below_the_reported_pixels() {
        assert_eq!(
            preferred_capture_pixel_size(Size::new(1440.0, 900.0), 2.0, Size::new(3840.0, 2160.0)),
            Size::new(3840.0, 2160.0)
        );
        assert_eq!(
            preferred_capture_pixel_size(Size::new(1440.0, 900.0), 2.0, Size::new(1440.0, 900.0)),
            Size::new(2880.0, 1800.0)
        );
    }

    #[test]
    fn toolbar_size_fits_narrow_screens_without_changing_height() {
        assert_eq!(
            fitted_toolbar_size(
                Size::new(672.0, 44.0),
                Rect::new(0.0, 0.0, 640.0, 480.0),
                DEFAULT_TOOLBAR_EDGE_INSET
            ),
            Size::new(624.0, 44.0)
        );
        assert_eq!(
            fitted_toolbar_size(
                Size::new(672.0, 44.0),
                Rect::new(0.0, 0.0, 1440.0, 900.0),
                DEFAULT_TOOLBAR_EDGE_INSET
            ),
            Size::new(672.0, 44.0)
        );
    }
}
