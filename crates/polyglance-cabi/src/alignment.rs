use capture_core::alignment::{self, SegmentPair};
use serde::Serialize;
use std::ffi::c_char;

use crate::{
    POLYGLANCE_ERR_INVALID_INPUT, POLYGLANCE_ERR_NULL_PTR, POLYGLANCE_OK, c_char_to_str,
    ffi_status, string_to_c_char,
};

#[derive(Clone, Debug, Serialize)]
pub struct CSegmentPair {
    pub id: u32,
    pub source_text: String,
    pub target_text: String,
    pub source_location: u32,
    pub source_length: u32,
    pub target_location: u32,
    pub target_length: u32,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_alignment_pairs(
    source_text: *const c_char,
    target_text: *const c_char,
    out_pairs_json: *mut *mut c_char,
) -> i32 {
    ffi_status(|| unsafe { alignment_pairs(source_text, target_text, out_pairs_json) })
}

unsafe fn alignment_pairs(
    source_text: *const c_char,
    target_text: *const c_char,
    out_pairs_json: *mut *mut c_char,
) -> i32 {
    if source_text.is_null() || target_text.is_null() || out_pairs_json.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }

    let source = match unsafe { c_char_to_str(source_text) } {
        Some(s) => s,
        None => return POLYGLANCE_ERR_INVALID_INPUT,
    };

    let target = match unsafe { c_char_to_str(target_text) } {
        Some(s) => s,
        None => return POLYGLANCE_ERR_INVALID_INPUT,
    };

    let rust_pairs: Vec<SegmentPair> = alignment::pairs(source, target);
    let output: Vec<CSegmentPair> = rust_pairs
        .into_iter()
        .map(|p| CSegmentPair {
            id: p.id,
            source_text: p.source_text,
            target_text: p.target_text,
            source_location: p.source_location,
            source_length: p.source_length,
            target_location: p.target_location,
            target_length: p.target_length,
        })
        .collect();

    match serde_json::to_string(&output) {
        Ok(json_str) => {
            unsafe {
                *out_pairs_json = string_to_c_char(json_str);
            }
            POLYGLANCE_OK
        }
        Err(_) => POLYGLANCE_ERR_INVALID_INPUT,
    }
}
