//! C ABI mirror of `capture_core::formatting`.

use capture_core::formatting;
use std::ffi::c_char;

use crate::{
    POLYGLANCE_ERR_INVALID_INPUT, POLYGLANCE_ERR_NULL_PTR, POLYGLANCE_OK, c_char_to_str,
    ffi_status, string_to_c_char,
};

/// Formats OCR text with the mode stored in the caller's configuration.
///
/// `mode` uses the persisted discriminant; unrecognised values fall back to
/// smart merge.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_text_format(
    text: *const c_char,
    mode: u8,
    out_text: *mut *mut c_char,
) -> i32 {
    ffi_status(|| unsafe {
        transform(text, out_text, |input| {
            formatting::format(input, formatting::TextFormattingMode::from_raw(mode))
        })
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_text_smart_merge_lines(
    text: *const c_char,
    out_text: *mut *mut c_char,
) -> i32 {
    ffi_status(|| unsafe { transform(text, out_text, formatting::smart_merge_lines) })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_text_apply_pangu_spacing(
    text: *const c_char,
    out_text: *mut *mut c_char,
) -> i32 {
    ffi_status(|| unsafe { transform(text, out_text, formatting::apply_pangu_spacing) })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_text_remove_extraneous_spaces(
    text: *const c_char,
    out_text: *mut *mut c_char,
) -> i32 {
    ffi_status(|| unsafe { transform(text, out_text, formatting::remove_extraneous_spaces) })
}

/// Reports whether a Unicode scalar belongs to the CJK tables this module uses.
/// An unpaired surrogate or out-of-range value is not CJK.
#[unsafe(no_mangle)]
pub extern "C" fn polyglance_text_is_cjk_scalar(scalar: u32) -> bool {
    char::from_u32(scalar).is_some_and(formatting::is_cjk)
}

unsafe fn transform(
    text: *const c_char,
    out_text: *mut *mut c_char,
    operation: impl FnOnce(&str) -> String,
) -> i32 {
    if text.is_null() || out_text.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }

    let input = match unsafe { c_char_to_str(text) } {
        Some(value) => value,
        None => return POLYGLANCE_ERR_INVALID_INPUT,
    };

    unsafe {
        *out_text = string_to_c_char(operation(input));
    }
    POLYGLANCE_OK
}
