//! Swift-facing mirror of `capture_core::layout`.

use capture_core::layout;

use crate::geometry::CaptureRect;

#[derive(Clone, Debug, uniffi::Record)]
pub struct LayoutTextLine {
    pub text: String,
    pub bounding_box: CaptureRect,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LayoutParagraph {
    pub text: String,
    pub bounding_box: CaptureRect,
    pub line_count: u32,
}

impl From<LayoutTextLine> for layout::TextLine {
    fn from(value: LayoutTextLine) -> Self {
        Self {
            text: value.text,
            bounding_box: value.bounding_box.into(),
        }
    }
}

impl From<layout::Paragraph> for LayoutParagraph {
    fn from(value: layout::Paragraph) -> Self {
        Self {
            text: value.text,
            bounding_box: value.bounding_box.into(),
            line_count: value.line_count,
        }
    }
}

#[uniffi::export]
pub fn layout_paragraphs(lines: Vec<LayoutTextLine>) -> Vec<LayoutParagraph> {
    let lines: Vec<layout::TextLine> = lines.into_iter().map(Into::into).collect();
    layout::paragraphs(&lines)
        .into_iter()
        .map(Into::into)
        .collect()
}
