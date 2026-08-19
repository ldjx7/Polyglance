//! Platform-agnostic capture logic shared by every Polyglance frontend.

pub mod geometry;
pub mod rect;

pub use geometry::{
    KeyboardAdjustment, KeyboardDirection, KeyboardOperation, KeyboardStep, ResizeHandle,
    SelectionEditTarget,
};
pub use rect::{Point, Rect, Size};
