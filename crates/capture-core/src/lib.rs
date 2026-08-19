//! Platform-agnostic capture logic shared by every Polyglance frontend.

pub mod alignment;
pub mod geometry;
pub mod pin;
pub mod rect;

pub use alignment::SegmentPair;
pub use geometry::{
    KeyboardAdjustment, KeyboardDirection, KeyboardOperation, KeyboardStep, ResizeHandle,
    SelectionEditTarget,
};
pub use pin::SizeLimits;
pub use rect::{Point, Rect, Size};
