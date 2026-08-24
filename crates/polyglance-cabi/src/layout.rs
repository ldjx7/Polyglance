use capture_core::layout::{self, Paragraph, TextLine};
use capture_core::rect::Rect;
use serde::{Deserialize, Serialize};
use std::ffi::c_char;

use crate::{
    POLYGLANCE_ERR_INVALID_INPUT, POLYGLANCE_ERR_NULL_PTR, POLYGLANCE_OK, c_char_to_str,
    ffi_status, string_to_c_char,
};

#[derive(Clone, Debug, Deserialize)]
pub struct CLayoutTextLine {
    pub text: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Debug, Serialize)]
pub struct CLayoutParagraph {
    pub text: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub line_count: u32,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_layout_paragraphs(
    lines_json: *const c_char,
    out_paragraphs_json: *mut *mut c_char,
) -> i32 {
    ffi_status(|| unsafe { layout_paragraphs(lines_json, out_paragraphs_json) })
}

unsafe fn layout_paragraphs(
    lines_json: *const c_char,
    out_paragraphs_json: *mut *mut c_char,
) -> i32 {
    if lines_json.is_null() || out_paragraphs_json.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }

    let input_str = match unsafe { c_char_to_str(lines_json) } {
        Some(s) => s,
        None => return POLYGLANCE_ERR_INVALID_INPUT,
    };

    let lines: Vec<CLayoutTextLine> = match serde_json::from_str(input_str) {
        Ok(l) => l,
        Err(_) => return POLYGLANCE_ERR_INVALID_INPUT,
    };

    let rust_lines: Vec<TextLine> = lines
        .into_iter()
        .map(|l| TextLine {
            text: l.text,
            bounding_box: Rect::new(l.x, l.y, l.width, l.height),
        })
        .collect();

    let paragraphs: Vec<Paragraph> = layout::paragraphs(&rust_lines);
    let output: Vec<CLayoutParagraph> = paragraphs
        .into_iter()
        .map(|p| CLayoutParagraph {
            text: p.text,
            x: p.bounding_box.origin().x,
            y: p.bounding_box.origin().y,
            width: p.bounding_box.size().width,
            height: p.bounding_box.size().height,
            line_count: p.line_count,
        })
        .collect();

    match serde_json::to_string(&output) {
        Ok(json_str) => {
            unsafe {
                *out_paragraphs_json = string_to_c_char(json_str);
            }
            POLYGLANCE_OK
        }
        Err(_) => POLYGLANCE_ERR_INVALID_INPUT,
    }
}
