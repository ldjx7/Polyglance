//! Pin window sizing and placement.

use crate::rect::{Point, Rect, Size};

const MINIMUM_WIDTH: f64 = 96.0;
const MINIMUM_HEIGHT: f64 = 64.0;
const MINIMUM_SCALE: f64 = 0.1;
const MAXIMUM_SCALE: f64 = 8.0;
const MAXIMUM_DIMENSION: f64 = 8_192.0;

pub const DEFAULT_MINIMUM_VISIBLE_LENGTH: f64 = 32.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SizeLimits {
    pub minimum: Size,
    pub maximum: Size,
}

pub fn operable_initial_size(image_size: Size, maximum_size: Size) -> Size {
    if !image_size.width.is_finite()
        || !image_size.height.is_finite()
        || !maximum_size.width.is_finite()
        || !maximum_size.height.is_finite()
        || image_size.width <= 0.0
        || image_size.height <= 0.0
        || maximum_size.width <= 0.0
        || maximum_size.height <= 0.0
    {
        return Size::ZERO;
    }
    let scale_needed_for_minimum_size = 1.0_f64
        .max(MINIMUM_WIDTH / image_size.width)
        .max(MINIMUM_HEIGHT / image_size.height);
    let scale_allowed_by_screen =
        (maximum_size.width / image_size.width).min(maximum_size.height / image_size.height);
    scaled(
        image_size,
        scale_needed_for_minimum_size.min(scale_allowed_by_screen),
    )
}

pub fn size_limits(initial_size: Size) -> SizeLimits {
    if !initial_size.width.is_finite()
        || !initial_size.height.is_finite()
        || initial_size.width <= 0.0
        || initial_size.height <= 0.0
    {
        return SizeLimits {
            minimum: Size::new(1.0, 1.0),
            maximum: Size::new(1.0, 1.0),
        };
    }

    let scale_needed_for_minimum_size =
        (MINIMUM_WIDTH / initial_size.width).max(MINIMUM_HEIGHT / initial_size.height);
    let lower_scale = 1.0_f64.min(MINIMUM_SCALE.max(scale_needed_for_minimum_size));
    let scale_allowed_by_dimension_limit =
        (MAXIMUM_DIMENSION / initial_size.width).min(MAXIMUM_DIMENSION / initial_size.height);
    let upper_scale = 1.0_f64.max(
        MAXIMUM_SCALE
            .max(scale_needed_for_minimum_size)
            .min(scale_allowed_by_dimension_limit),
    );
    SizeLimits {
        minimum: scaled(initial_size, lower_scale),
        maximum: scaled(initial_size, upper_scale),
    }
}

pub fn scaled_frame(
    frame: Rect,
    requested_scale: f64,
    anchor_in_window: Point,
    minimum_size: Size,
    maximum_size: Size,
) -> Rect {
    if !frame.width.is_finite()
        || !frame.height.is_finite()
        || frame.width <= 0.0
        || frame.height <= 0.0
    {
        return frame;
    }

    let proposed_scale = if requested_scale.is_finite() && requested_scale > 0.0 {
        requested_scale
    } else {
        1.0
    };
    let lower_scale = positive_ratio(minimum_size.width, frame.width, 0.0).max(positive_ratio(
        minimum_size.height,
        frame.height,
        0.0,
    ));
    let upper_scale = positive_ratio(maximum_size.width, frame.width, f64::MAX)
        .min(positive_ratio(maximum_size.height, frame.height, f64::MAX));
    let valid_lower_scale = 0.0_f64.max(lower_scale.min(upper_scale));
    let valid_upper_scale = valid_lower_scale.max(upper_scale);
    let scale = proposed_scale.max(valid_lower_scale).min(valid_upper_scale);
    let anchor = Point::new(
        anchor_in_window.x.max(0.0).min(frame.width),
        anchor_in_window.y.max(0.0).min(frame.height),
    );
    Rect::from_origin_size(
        Point::new(
            frame.min_x() + anchor.x - anchor.x * scale,
            frame.min_y() + anchor.y - anchor.y * scale,
        ),
        Size::new(frame.width * scale, frame.height * scale),
    )
}

pub fn origin_keeping_window_visible(
    proposed_origin: Point,
    window_size: Size,
    visible_frame: Rect,
    minimum_visible_length: f64,
) -> Point {
    if !window_size.width.is_finite()
        || !window_size.height.is_finite()
        || window_size.width <= 0.0
        || window_size.height <= 0.0
        || visible_frame.is_empty()
    {
        return proposed_origin;
    }

    let visible_width = minimum_visible_length
        .max(0.0)
        .min(window_size.width)
        .min(visible_frame.width);
    let visible_height = minimum_visible_length
        .max(0.0)
        .min(window_size.height)
        .min(visible_frame.height);
    Point::new(
        proposed_origin
            .x
            .max(visible_frame.min_x() - window_size.width + visible_width)
            .min(visible_frame.max_x() - visible_width),
        proposed_origin
            .y
            .max(visible_frame.min_y() - window_size.height + visible_height)
            .min(visible_frame.max_y() - visible_height),
    )
}

fn scaled(size: Size, scale: f64) -> Size {
    Size::new(size.width * scale, size.height * scale)
}

fn positive_ratio(numerator: f64, denominator: f64, fallback: f64) -> f64 {
    if !numerator.is_finite() || numerator <= 0.0 || denominator <= 0.0 {
        return fallback;
    }
    numerator / denominator
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn small_images_are_enlarged_to_stay_operable() {
        let size = operable_initial_size(Size::new(20.0, 10.0), Size::new(1000.0, 1000.0));

        assert_eq!(size, Size::new(128.0, 64.0));
    }

    #[test]
    fn the_screen_limit_wins_over_the_minimum_size() {
        let size = operable_initial_size(Size::new(20.0, 10.0), Size::new(40.0, 40.0));

        assert_eq!(size, Size::new(40.0, 20.0));
    }

    #[test]
    fn degenerate_input_collapses_to_zero() {
        assert_eq!(
            operable_initial_size(Size::ZERO, Size::new(100.0, 100.0)),
            Size::ZERO
        );
        assert_eq!(
            operable_initial_size(Size::new(f64::NAN, 10.0), Size::new(100.0, 100.0)),
            Size::ZERO
        );
    }

    #[test]
    fn limits_never_shrink_below_the_operable_minimum() {
        let limits = size_limits(Size::new(200.0, 100.0));

        assert_eq!(limits.minimum, Size::new(128.0, 64.0));
        assert_eq!(limits.maximum, Size::new(1600.0, 800.0));
    }

    #[test]
    fn limits_are_safe_for_degenerate_sizes() {
        let limits = size_limits(Size::ZERO);

        assert_eq!(limits.minimum, Size::new(1.0, 1.0));
        assert_eq!(limits.maximum, Size::new(1.0, 1.0));
    }

    #[test]
    fn scaling_keeps_the_anchor_pinned() {
        let frame = scaled_frame(
            Rect::new(100.0, 100.0, 200.0, 100.0),
            2.0,
            Point::new(0.0, 0.0),
            Size::new(50.0, 25.0),
            Size::new(1000.0, 1000.0),
        );

        assert_eq!(frame, Rect::new(100.0, 100.0, 400.0, 200.0));
    }

    #[test]
    fn scaling_is_clamped_by_the_size_limits() {
        let frame = scaled_frame(
            Rect::new(0.0, 0.0, 200.0, 100.0),
            10.0,
            Point::ZERO,
            Size::new(100.0, 50.0),
            Size::new(400.0, 200.0),
        );

        assert_eq!(frame.size(), Size::new(400.0, 200.0));
    }

    #[test]
    fn windows_keep_a_visible_sliver_on_screen() {
        let visible = Rect::new(0.0, 0.0, 1000.0, 800.0);
        let origin = origin_keeping_window_visible(
            Point::new(-5000.0, 5000.0),
            Size::new(300.0, 200.0),
            visible,
            DEFAULT_MINIMUM_VISIBLE_LENGTH,
        );

        assert_eq!(origin, Point::new(-268.0, 768.0));
    }

    #[test]
    fn an_empty_screen_leaves_the_origin_untouched() {
        let origin = origin_keeping_window_visible(
            Point::new(10.0, 20.0),
            Size::new(300.0, 200.0),
            Rect::ZERO,
            DEFAULT_MINIMUM_VISIBLE_LENGTH,
        );

        assert_eq!(origin, Point::new(10.0, 20.0));
    }
}
