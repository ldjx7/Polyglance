//! Platform-agnostic annotation models and undo-redo state management.
//!
//! Replaces UIElement-coupled annotations with pure serializable data structures
//! supporting rectangles, ellipses, arrows, lines, freehand pens, text labels,
//! number badges, and mosaic regions.

use serde::{Deserialize, Serialize};

use crate::rect::{Point, Rect};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ColorRgba {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl ColorRgba {
    pub const RED: Self = Self::new(239, 68, 68, 255);
    pub const GREEN: Self = Self::new(34, 197, 94, 255);
    pub const BLUE: Self = Self::new(59, 130, 246, 255);
    pub const YELLOW: Self = Self::new(234, 179, 8, 255);
    pub const WHITE: Self = Self::new(255, 255, 255, 255);
    pub const BLACK: Self = Self::new(0, 0, 0, 255);
    pub const TRANSPARENT: Self = Self::new(0, 0, 0, 0);

    pub const fn new(r: u8, g: u8, b: u8, a: u8) -> Self {
        Self { r, g, b, a }
    }

    pub fn to_hex(&self) -> String {
        format!("#{:02X}{:02X}{:02X}{:02X}", self.r, self.g, self.b, self.a)
    }

    pub fn from_hex(hex: &str) -> Option<Self> {
        let hex = hex.strip_prefix('#').unwrap_or(hex);
        match hex.len() {
            6 => {
                let r = u8::from_str_radix(&hex[0..2], 16).ok()?;
                let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
                let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
                Some(Self::new(r, g, b, 255))
            }
            8 => {
                let r = u8::from_str_radix(&hex[0..2], 16).ok()?;
                let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
                let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
                let a = u8::from_str_radix(&hex[6..8], 16).ok()?;
                Some(Self::new(r, g, b, a))
            }
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum AnnotationKind {
    Rectangle {
        rect: Rect,
        stroke_color: ColorRgba,
        stroke_width: f64,
        fill_color: Option<ColorRgba>,
    },
    Ellipse {
        rect: Rect,
        stroke_color: ColorRgba,
        stroke_width: f64,
        fill_color: Option<ColorRgba>,
    },
    Arrow {
        start: Point,
        end: Point,
        color: ColorRgba,
        stroke_width: f64,
    },
    Line {
        start: Point,
        end: Point,
        color: ColorRgba,
        stroke_width: f64,
    },
    Pen {
        points: Vec<Point>,
        color: ColorRgba,
        stroke_width: f64,
    },
    Text {
        position: Point,
        text: String,
        font_size: f64,
        color: ColorRgba,
    },
    NumberBadge {
        number: u32,
        center: Point,
        radius: f64,
        color: ColorRgba,
    },
    Mosaic {
        rect: Rect,
        block_size: f64,
    },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Annotation {
    pub id: u64,
    pub kind: AnnotationKind,
}

impl Annotation {
    pub fn new(id: u64, kind: AnnotationKind) -> Self {
        Self { id, kind }
    }

    pub fn bounds(&self) -> Rect {
        match &self.kind {
            AnnotationKind::Rectangle { rect, .. }
            | AnnotationKind::Ellipse { rect, .. }
            | AnnotationKind::Mosaic { rect, .. } => *rect,
            AnnotationKind::Arrow { start, end, .. } | AnnotationKind::Line { start, end, .. } => {
                let min_x = start.x.min(end.x);
                let min_y = start.y.min(end.y);
                let max_x = start.x.max(end.x);
                let max_y = start.y.max(end.y);
                Rect::new(
                    min_x,
                    min_y,
                    (max_x - min_x).max(1.0),
                    (max_y - min_y).max(1.0),
                )
            }
            AnnotationKind::Pen { points, .. } => {
                if points.is_empty() {
                    return Rect::ZERO;
                }
                let mut min_x = points[0].x;
                let mut min_y = points[0].y;
                let mut max_x = points[0].x;
                let mut max_y = points[0].y;
                for p in &points[1..] {
                    min_x = min_x.min(p.x);
                    min_y = min_y.min(p.y);
                    max_x = max_x.max(p.x);
                    max_y = max_y.max(p.y);
                }
                Rect::new(
                    min_x,
                    min_y,
                    (max_x - min_x).max(1.0),
                    (max_y - min_y).max(1.0),
                )
            }
            AnnotationKind::Text {
                position,
                font_size,
                text,
                ..
            } => {
                let approx_width = text.chars().count() as f64 * (*font_size * 0.6);
                let approx_height = *font_size * 1.2;
                Rect::new(
                    position.x,
                    position.y,
                    approx_width.max(10.0),
                    approx_height.max(10.0),
                )
            }
            AnnotationKind::NumberBadge { center, radius, .. } => Rect::new(
                center.x - radius,
                center.y - radius,
                radius * 2.0,
                radius * 2.0,
            ),
        }
    }

    pub fn hit_test(&self, point: Point, tolerance: f64) -> bool {
        let tolerance = if tolerance.is_finite() {
            tolerance.max(0.0)
        } else {
            0.0
        };
        match &self.kind {
            AnnotationKind::Line {
                start,
                end,
                stroke_width,
                ..
            }
            | AnnotationKind::Arrow {
                start,
                end,
                stroke_width,
                ..
            } => {
                return segment_distance(point, *start, *end)
                    <= tolerance + stroke_width.max(0.0) / 2.0;
            }
            AnnotationKind::Pen {
                points,
                stroke_width,
                ..
            } => {
                let radius = tolerance + stroke_width.max(0.0) / 2.0;
                return points
                    .windows(2)
                    .any(|segment| segment_distance(point, segment[0], segment[1]) <= radius)
                    || points.len() == 1 && point_distance(point, points[0]) <= radius;
            }
            AnnotationKind::Ellipse { rect, .. } => {
                let rx = rect.width.abs() / 2.0 + tolerance;
                let ry = rect.height.abs() / 2.0 + tolerance;
                if rx == 0.0 || ry == 0.0 {
                    return false;
                }
                let cx = rect.x + rect.width / 2.0;
                let cy = rect.y + rect.height / 2.0;
                return ((point.x - cx) / rx).powi(2) + ((point.y - cy) / ry).powi(2) <= 1.0;
            }
            _ => {}
        }
        let b = self.bounds();
        let expanded = Rect::new(
            b.x - tolerance,
            b.y - tolerance,
            b.width + tolerance * 2.0,
            b.height + tolerance * 2.0,
        );
        expanded.contains(point)
    }

    pub fn translate(&mut self, dx: f64, dy: f64) {
        match &mut self.kind {
            AnnotationKind::Rectangle { rect, .. }
            | AnnotationKind::Ellipse { rect, .. }
            | AnnotationKind::Mosaic { rect, .. } => {
                rect.x += dx;
                rect.y += dy;
            }
            AnnotationKind::Arrow { start, end, .. } | AnnotationKind::Line { start, end, .. } => {
                start.x += dx;
                start.y += dy;
                end.x += dx;
                end.y += dy;
            }
            AnnotationKind::Pen { points, .. } => {
                for p in points {
                    p.x += dx;
                    p.y += dy;
                }
            }
            AnnotationKind::Text { position, .. } => {
                position.x += dx;
                position.y += dy;
            }
            AnnotationKind::NumberBadge { center, .. } => {
                center.x += dx;
                center.y += dy;
            }
        }
    }
}

fn point_distance(a: Point, b: Point) -> f64 {
    (a.x - b.x).hypot(a.y - b.y)
}

fn segment_distance(point: Point, start: Point, end: Point) -> f64 {
    let dx = end.x - start.x;
    let dy = end.y - start.y;
    let length_squared = dx * dx + dy * dy;
    if length_squared <= f64::EPSILON {
        return point_distance(point, start);
    }
    let t =
        (((point.x - start.x) * dx + (point.y - start.y) * dy) / length_squared).clamp(0.0, 1.0);
    point_distance(point, Point::new(start.x + t * dx, start.y + t * dy))
}

/// Maps coordinates between Screen Logical, Screen Physical, and Image Bitmap pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CoordinateMapper {
    pub selection_origin: Point,
    pub scale_factor: f64,
}

impl CoordinateMapper {
    pub fn new(selection_origin: Point, scale_factor: f64) -> Self {
        Self {
            selection_origin,
            scale_factor: if scale_factor.is_finite() && scale_factor > 0.0 {
                scale_factor
            } else {
                1.0
            },
        }
    }

    pub fn screen_to_image_point(&self, screen_pt: Point) -> Point {
        Point::new(
            (screen_pt.x - self.selection_origin.x) * self.scale_factor,
            (screen_pt.y - self.selection_origin.y) * self.scale_factor,
        )
    }

    pub fn image_to_screen_point(&self, img_pt: Point) -> Point {
        Point::new(
            img_pt.x / self.scale_factor + self.selection_origin.x,
            img_pt.y / self.scale_factor + self.selection_origin.y,
        )
    }

    pub fn screen_to_image_rect(&self, screen_rect: Rect) -> Rect {
        Rect::new(
            (screen_rect.x - self.selection_origin.x) * self.scale_factor,
            (screen_rect.y - self.selection_origin.y) * self.scale_factor,
            screen_rect.width * self.scale_factor,
            screen_rect.height * self.scale_factor,
        )
    }

    pub fn image_to_screen_rect(&self, img_rect: Rect) -> Rect {
        Rect::new(
            img_rect.x / self.scale_factor + self.selection_origin.x,
            img_rect.y / self.scale_factor + self.selection_origin.y,
            img_rect.width / self.scale_factor,
            img_rect.height / self.scale_factor,
        )
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
enum Action {
    Add(Annotation),
    Remove {
        annotation: Annotation,
        index: usize,
    },
    Modify {
        before: Annotation,
        after: Annotation,
    },
    Clear(Vec<Annotation>),
}

/// Document model managing all annotations on a canvas with full undo/redo history.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AnnotationDocument {
    annotations: Vec<Annotation>,
    undo_stack: Vec<Action>,
    redo_stack: Vec<Action>,
    next_id: u64,
}

impl Default for AnnotationDocument {
    fn default() -> Self {
        Self::new()
    }
}

impl AnnotationDocument {
    pub fn new() -> Self {
        Self {
            annotations: Vec::new(),
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            next_id: 1,
        }
    }

    pub fn annotations(&self) -> &[Annotation] {
        &self.annotations
    }

    pub fn count(&self) -> usize {
        self.annotations.len()
    }

    pub fn is_empty(&self) -> bool {
        self.annotations.is_empty()
    }

    pub fn can_undo(&self) -> bool {
        !self.undo_stack.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo_stack.is_empty()
    }

    pub fn add(&mut self, kind: AnnotationKind) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        let annotation = Annotation::new(id, kind);
        self.annotations.push(annotation.clone());
        self.undo_stack.push(Action::Add(annotation));
        self.redo_stack.clear();
        id
    }

    pub fn remove(&mut self, id: u64) -> bool {
        if let Some(index) = self.annotations.iter().position(|a| a.id == id) {
            let removed = self.annotations.remove(index);
            self.undo_stack.push(Action::Remove {
                annotation: removed,
                index,
            });
            self.redo_stack.clear();
            true
        } else {
            false
        }
    }

    pub fn modify(&mut self, id: u64, new_kind: AnnotationKind) -> bool {
        if let Some(annotation) = self.annotations.iter_mut().find(|a| a.id == id) {
            let before = annotation.clone();
            annotation.kind = new_kind;
            let after = annotation.clone();
            self.undo_stack.push(Action::Modify { before, after });
            self.redo_stack.clear();
            true
        } else {
            false
        }
    }

    pub fn clear(&mut self) {
        if !self.annotations.is_empty() {
            let previous = std::mem::take(&mut self.annotations);
            self.undo_stack.push(Action::Clear(previous));
            self.redo_stack.clear();
        }
    }

    pub fn undo(&mut self) -> bool {
        let Some(action) = self.undo_stack.pop() else {
            return false;
        };
        match action {
            Action::Add(annotation) => {
                self.annotations.retain(|a| a.id != annotation.id);
                self.redo_stack.push(Action::Add(annotation));
            }
            Action::Remove { annotation, index } => {
                self.annotations
                    .insert(index.min(self.annotations.len()), annotation.clone());
                self.redo_stack.push(Action::Remove { annotation, index });
            }
            Action::Modify { before, after } => {
                if let Some(item) = self.annotations.iter_mut().find(|a| a.id == before.id) {
                    *item = before.clone();
                }
                self.redo_stack.push(Action::Modify { before, after });
            }
            Action::Clear(items) => {
                self.annotations = items.clone();
                self.redo_stack.push(Action::Clear(items));
            }
        }
        true
    }

    pub fn redo(&mut self) -> bool {
        let Some(action) = self.redo_stack.pop() else {
            return false;
        };
        match action {
            Action::Add(annotation) => {
                self.annotations.push(annotation.clone());
                self.undo_stack.push(Action::Add(annotation));
            }
            Action::Remove { annotation, index } => {
                self.annotations.retain(|a| a.id != annotation.id);
                self.undo_stack.push(Action::Remove { annotation, index });
            }
            Action::Modify { before, after } => {
                if let Some(item) = self.annotations.iter_mut().find(|a| a.id == after.id) {
                    *item = after.clone();
                }
                self.undo_stack.push(Action::Modify { before, after });
            }
            Action::Clear(items) => {
                self.annotations.clear();
                self.undo_stack.push(Action::Clear(items));
            }
        }
        true
    }

    pub fn hit_test(&self, point: Point, tolerance: f64) -> Option<u64> {
        // Reverse iteration so top-most drawn item is picked first
        for annotation in self.annotations.iter().rev() {
            if annotation.hit_test(point, tolerance) {
                return Some(annotation.id);
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn color_rgba_hex_round_trip() {
        let color = ColorRgba::new(0xEF, 0x44, 0x44, 0xFF);
        let hex = color.to_hex();
        assert_eq!(hex, "#EF4444FF");
        assert_eq!(ColorRgba::from_hex(&hex), Some(color));
        assert_eq!(ColorRgba::from_hex("#EF4444"), Some(color));
    }

    #[test]
    fn coordinate_mapper_scales_and_offsets() {
        let mapper = CoordinateMapper::new(Point::new(100.0, 50.0), 2.0);
        let screen_pt = Point::new(150.0, 80.0);
        let img_pt = mapper.screen_to_image_point(screen_pt);
        assert_eq!(img_pt, Point::new(100.0, 60.0));
        assert_eq!(mapper.image_to_screen_point(img_pt), screen_pt);

        let screen_rect = Rect::new(100.0, 50.0, 200.0, 100.0);
        let img_rect = mapper.screen_to_image_rect(screen_rect);
        assert_eq!(img_rect, Rect::new(0.0, 0.0, 400.0, 200.0));
        assert_eq!(mapper.image_to_screen_rect(img_rect), screen_rect);
    }

    #[test]
    fn document_add_undo_redo_lifecycle() {
        let mut doc = AnnotationDocument::new();
        assert_eq!(doc.count(), 0);
        assert!(!doc.can_undo());
        assert!(!doc.can_redo());

        let id = doc.add(AnnotationKind::Rectangle {
            rect: Rect::new(10.0, 20.0, 100.0, 50.0),
            stroke_color: ColorRgba::RED,
            stroke_width: 2.0,
            fill_color: None,
        });

        assert_eq!(id, 1);
        assert_eq!(doc.count(), 1);
        assert!(doc.can_undo());
        assert!(!doc.can_redo());

        assert!(doc.undo());
        assert_eq!(doc.count(), 0);
        assert!(!doc.can_undo());
        assert!(doc.can_redo());

        assert!(doc.redo());
        assert_eq!(doc.count(), 1);
        assert!(doc.can_undo());
        assert!(!doc.can_redo());
    }

    #[test]
    fn document_hit_test_prefers_topmost() {
        let mut doc = AnnotationDocument::new();
        let id1 = doc.add(AnnotationKind::Rectangle {
            rect: Rect::new(0.0, 0.0, 100.0, 100.0),
            stroke_color: ColorRgba::RED,
            stroke_width: 2.0,
            fill_color: None,
        });
        let id2 = doc.add(AnnotationKind::Rectangle {
            rect: Rect::new(10.0, 10.0, 50.0, 50.0),
            stroke_color: ColorRgba::BLUE,
            stroke_width: 2.0,
            fill_color: None,
        });

        assert_eq!(doc.hit_test(Point::new(20.0, 20.0), 0.0), Some(id2));
        assert_eq!(doc.hit_test(Point::new(80.0, 80.0), 0.0), Some(id1));
        assert_eq!(doc.hit_test(Point::new(200.0, 200.0), 0.0), None);
    }

    #[test]
    fn undo_remove_restores_original_z_order() {
        let mut doc = AnnotationDocument::new();
        let bottom = doc.add(AnnotationKind::Rectangle {
            rect: Rect::new(0.0, 0.0, 30.0, 30.0),
            stroke_color: ColorRgba::RED,
            stroke_width: 2.0,
            fill_color: None,
        });
        let top = doc.add(AnnotationKind::Rectangle {
            rect: Rect::new(0.0, 0.0, 30.0, 30.0),
            stroke_color: ColorRgba::BLUE,
            stroke_width: 2.0,
            fill_color: None,
        });
        assert!(doc.remove(bottom));
        assert!(doc.undo());
        assert_eq!(doc.hit_test(Point::new(10.0, 10.0), 0.0), Some(top));
        assert!(doc.redo());
        assert_eq!(doc.annotations().len(), 1);
        assert_eq!(doc.annotations()[0].id, top);
    }

    #[test]
    fn mapper_rejects_non_finite_scale() {
        let origin = Point::new(-100.0, 50.0);
        for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 0.0] {
            let mapper = CoordinateMapper::new(origin, invalid);
            assert_eq!(
                mapper.screen_to_image_point(Point::new(-90.0, 60.0)),
                Point::new(10.0, 10.0)
            );
        }
    }

    #[test]
    fn default_document_uses_the_same_first_id_as_new() {
        let mut doc = AnnotationDocument::default();
        assert_eq!(
            doc.add(AnnotationKind::Mosaic {
                rect: Rect::new(0.0, 0.0, 10.0, 10.0),
                block_size: 5.0,
            }),
            1
        );
    }

    #[test]
    fn line_hit_testing_uses_stroke_distance() {
        let line = Annotation::new(
            1,
            AnnotationKind::Line {
                start: Point::new(0.0, 0.0),
                end: Point::new(100.0, 100.0),
                color: ColorRgba::RED,
                stroke_width: 2.0,
            },
        );
        assert!(line.hit_test(Point::new(50.0, 50.0), 2.0));
        assert!(!line.hit_test(Point::new(10.0, 90.0), 2.0));
    }

    #[test]
    fn ellipse_hit_testing_rejects_bbox_corners() {
        let ellipse = Annotation::new(
            1,
            AnnotationKind::Ellipse {
                rect: Rect::new(0.0, 0.0, 100.0, 100.0),
                stroke_color: ColorRgba::BLUE,
                stroke_width: 2.0,
                fill_color: None,
            },
        );
        assert!(ellipse.hit_test(Point::new(50.0, 50.0), 0.0));
        assert!(!ellipse.hit_test(Point::new(1.0, 1.0), 0.0));
    }
}
