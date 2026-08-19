//! Rectangle math that mirrors CoreGraphics semantics.
//!
//! The macOS app was written against `CGRect`, so its geometry relies on
//! CoreGraphics behaviour that is easy to get subtly wrong: a dedicated null
//! sentinel, half-open containment, and outward rounding. Reproducing those
//! rules here keeps every platform on identical results.

pub const NULL_ORIGIN: f64 = f64::INFINITY;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

impl Point {
    pub const ZERO: Self = Self { x: 0.0, y: 0.0 };

    pub fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }

    pub fn clamped_to(self, bounds: Rect) -> Self {
        Self {
            x: self.x.max(bounds.min_x()).min(bounds.max_x()),
            y: self.y.max(bounds.min_y()).min(bounds.max_y()),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

impl Size {
    pub const ZERO: Self = Self {
        width: 0.0,
        height: 0.0,
    };

    pub fn new(width: f64, height: f64) -> Self {
        Self { width, height }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const ZERO: Self = Self {
        x: 0.0,
        y: 0.0,
        width: 0.0,
        height: 0.0,
    };

    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    pub fn from_origin_size(origin: Point, size: Size) -> Self {
        Self::new(origin.x, origin.y, size.width, size.height)
    }

    /// The sentinel CoreGraphics returns for "no rectangle", distinct from an
    /// empty rectangle at the origin.
    pub fn null() -> Self {
        Self {
            x: NULL_ORIGIN,
            y: NULL_ORIGIN,
            width: 0.0,
            height: 0.0,
        }
    }

    pub fn is_null(self) -> bool {
        self.x == NULL_ORIGIN || self.y == NULL_ORIGIN
    }

    pub fn is_empty(self) -> bool {
        self.is_null() || self.width == 0.0 || self.height == 0.0
    }

    pub fn standardized(self) -> Self {
        if self.is_null() {
            return Self::null();
        }
        let (x, width) = if self.width < 0.0 {
            (self.x + self.width, -self.width)
        } else {
            (self.x, self.width)
        };
        let (y, height) = if self.height < 0.0 {
            (self.y + self.height, -self.height)
        } else {
            (self.y, self.height)
        };
        Self::new(x, y, width, height)
    }

    pub fn origin(self) -> Point {
        Point::new(self.x, self.y)
    }

    pub fn size(self) -> Size {
        Size::new(self.width, self.height)
    }

    pub fn min_x(self) -> f64 {
        self.x.min(self.x + self.width)
    }

    pub fn max_x(self) -> f64 {
        self.x.max(self.x + self.width)
    }

    pub fn min_y(self) -> f64 {
        self.y.min(self.y + self.height)
    }

    pub fn max_y(self) -> f64 {
        self.y.max(self.y + self.height)
    }

    pub fn mid_x(self) -> f64 {
        (self.min_x() + self.max_x()) / 2.0
    }

    pub fn mid_y(self) -> f64 {
        (self.min_y() + self.max_y()) / 2.0
    }

    /// Half-open on the upper edges, matching `CGRectContainsPoint`.
    pub fn contains(self, point: Point) -> bool {
        if self.is_empty() {
            return false;
        }
        point.x >= self.min_x()
            && point.x < self.max_x()
            && point.y >= self.min_y()
            && point.y < self.max_y()
    }

    /// Only genuinely disjoint rectangles collapse to null: rectangles that
    /// merely touch, or that are empty but overlapping, intersect to a
    /// zero-area rectangle. `CGRectIntersection` draws the line the same way.
    pub fn intersection(self, other: Self) -> Self {
        let min_x = self.min_x().max(other.min_x());
        let max_x = self.max_x().min(other.max_x());
        let min_y = self.min_y().max(other.min_y());
        let max_y = self.max_y().min(other.max_y());
        if min_x > max_x || min_y > max_y {
            return Self::null();
        }
        Self::new(min_x, min_y, max_x - min_x, max_y - min_y)
    }

    pub fn union(self, other: Self) -> Self {
        if self.is_null() {
            return other;
        }
        if other.is_null() {
            return self;
        }
        let min_x = self.min_x().min(other.min_x());
        let max_x = self.max_x().max(other.max_x());
        let min_y = self.min_y().min(other.min_y());
        let max_y = self.max_y().max(other.max_y());
        Self::new(min_x, min_y, max_x - min_x, max_y - min_y)
    }

    /// Collapses to the null rectangle when the inset consumes the rectangle,
    /// matching `CGRectInset`.
    pub fn inset_by(self, dx: f64, dy: f64) -> Self {
        if self.is_null() {
            return Self::null();
        }
        let standardized = self.standardized();
        let width = standardized.width - dx * 2.0;
        let height = standardized.height - dy * 2.0;
        if width < 0.0 || height < 0.0 {
            return Self::null();
        }
        Self::new(standardized.x + dx, standardized.y + dy, width, height)
    }

    /// The smallest rectangle with integral bounds that contains this one.
    pub fn integral(self) -> Self {
        if self.is_null() {
            return Self::null();
        }
        let standardized = self.standardized();
        let min_x = standardized.min_x().floor();
        let min_y = standardized.min_y().floor();
        let max_x = standardized.max_x().ceil();
        let max_y = standardized.max_y().ceil();
        Self::new(min_x, min_y, max_x - min_x, max_y - min_y)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn standardizing_flips_negative_extents() {
        let rect = Rect::new(10.0, 20.0, -4.0, -6.0).standardized();

        assert_eq!(rect, Rect::new(6.0, 14.0, 4.0, 6.0));
    }

    #[test]
    fn only_disjoint_rectangles_intersect_to_null() {
        let left = Rect::new(0.0, 0.0, 10.0, 10.0);

        assert!(left.intersection(Rect::new(20.0, 0.0, 5.0, 5.0)).is_null());
        assert!(left.intersection(Rect::null()).is_null());
    }

    #[test]
    fn touching_rectangles_intersect_to_a_zero_area_rectangle() {
        let intersection =
            Rect::new(0.0, 0.0, 10.0, 10.0).intersection(Rect::new(10.0, 0.0, 5.0, 5.0));

        assert!(!intersection.is_null());
        assert_eq!(intersection, Rect::new(10.0, 0.0, 0.0, 5.0));
    }

    #[test]
    fn overlapping_rectangles_intersect_to_the_shared_area() {
        let intersection =
            Rect::new(0.0, 0.0, 10.0, 10.0).intersection(Rect::new(5.0, 5.0, 10.0, 10.0));

        assert_eq!(intersection, Rect::new(5.0, 5.0, 5.0, 5.0));
    }

    #[test]
    fn an_overlapping_empty_rectangle_keeps_its_zero_extent() {
        let empty = Rect::new(0.0, 0.0, 0.0, 10.0);
        let inside = empty.intersection(Rect::new(0.0, 0.0, 10.0, 10.0));

        assert!(!inside.is_null());
        assert_eq!(inside, Rect::new(0.0, 0.0, 0.0, 10.0));

        let outside = Rect::new(50.0, 0.0, 0.0, 10.0).intersection(Rect::new(0.0, 0.0, 10.0, 10.0));
        assert!(outside.is_null());
    }

    #[test]
    fn containment_excludes_the_upper_edges() {
        let rect = Rect::new(0.0, 0.0, 10.0, 10.0);

        assert!(rect.contains(Point::new(0.0, 0.0)));
        assert!(rect.contains(Point::new(9.999, 9.999)));
        assert!(!rect.contains(Point::new(10.0, 5.0)));
        assert!(!rect.contains(Point::new(5.0, 10.0)));
    }

    #[test]
    fn an_empty_rectangle_contains_nothing() {
        assert!(!Rect::new(0.0, 0.0, 0.0, 0.0).contains(Point::ZERO));
        assert!(!Rect::null().contains(Point::ZERO));
    }

    #[test]
    fn insetting_past_the_centre_returns_null() {
        let rect = Rect::new(0.0, 0.0, 10.0, 10.0);

        assert_eq!(rect.inset_by(2.0, 2.0), Rect::new(2.0, 2.0, 6.0, 6.0));
        assert_eq!(rect.inset_by(-1.0, -1.0), Rect::new(-1.0, -1.0, 12.0, 12.0));
        assert!(rect.inset_by(6.0, 0.0).is_null());
    }

    #[test]
    fn integral_rounds_outward() {
        assert_eq!(
            Rect::new(1.2, 2.7, 3.1, 4.4).integral(),
            Rect::new(1.0, 2.0, 4.0, 6.0)
        );
        assert_eq!(
            Rect::new(1.2, 2.7, 0.0, 0.0).integral(),
            Rect::new(1.0, 2.0, 1.0, 1.0)
        );
    }

    #[test]
    fn null_rectangles_stay_null_through_transforms() {
        assert!(Rect::null().standardized().is_null());
        assert!(Rect::null().integral().is_null());
        assert!(Rect::null().inset_by(1.0, 1.0).is_null());
        assert!(Rect::null().is_empty());
    }
}
