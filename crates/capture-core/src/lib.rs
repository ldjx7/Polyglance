//! Platform-agnostic capture logic shared by every Polyglance frontend.

pub mod alignment;
pub mod geometry;
pub mod layout;
pub mod pin;
pub mod rect;
pub mod recording;
pub mod text;

pub use alignment::SegmentPair;
pub use geometry::{
    KeyboardAdjustment, KeyboardDirection, KeyboardOperation, KeyboardStep, ResizeHandle,
    SelectionEditTarget,
};
pub use layout::{Paragraph, TextLine};
pub use pin::SizeLimits;
pub use rect::{Point, Rect, Size};
pub use recording::{EncodingProfile, RecordingFormat, RecordingQuality};
