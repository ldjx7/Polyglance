//! Polyglance C ABI Export Layer for Windows (.NET 9 / C#) and non-Swift platforms.
//!
//! Exposes thread-safe, memory-managed C-compatible functions matching the
//! architecture specifications in docs/CROSS_PLATFORM_ARCHITECTURE.md.
//!
//! # C caller safety contract
//!
//! Every non-null pointer must reference readable or writable memory for the
//! length documented by that function and remain valid for the duration of the
//! call. Handles and output buffers must be released exactly once with the
//! matching `polyglance_*_free` function. Status-returning exports catch Rust
//! panics and report `POLYGLANCE_ERR_PANIC` instead of unwinding across the ABI.

#![allow(
    clippy::missing_safety_doc,
    reason = "all exports share the crate-level C caller safety contract"
)]

pub mod alignment;
pub mod engine;
pub mod geometry;
pub mod layout;
pub mod recording;
pub mod stitch;

use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

pub const POLYGLANCE_OK: i32 = 0;
pub const POLYGLANCE_ERR_INVALID_INPUT: i32 = 1;
pub const POLYGLANCE_ERR_INVALID_CONFIG: i32 = 2;
pub const POLYGLANCE_ERR_AUTH: i32 = 3;
pub const POLYGLANCE_ERR_RATE_LIMIT: i32 = 4;
pub const POLYGLANCE_ERR_NETWORK: i32 = 5;
pub const POLYGLANCE_ERR_PROVIDER: i32 = 6;
pub const POLYGLANCE_ERR_INVALID_RESPONSE: i32 = 7;
pub const POLYGLANCE_ERR_INIT: i32 = 8;
pub const POLYGLANCE_ERR_NULL_PTR: i32 = 9;
pub const POLYGLANCE_ERR_PANIC: i32 = 10;
pub const POLYGLANCE_ERR_STITCH_FAILED: i32 = 11;

/// Runs a C ABI operation without allowing a Rust panic to unwind into the caller.
pub fn ffi_status(operation: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(operation)).unwrap_or(POLYGLANCE_ERR_PANIC)
}

/// Runs a C ABI destructor without allowing a Rust panic to unwind into the caller.
pub fn ffi_void(operation: impl FnOnce()) {
    let _ = catch_unwind(AssertUnwindSafe(operation));
}

/// Converts Rust-owned bytes into an allocation that can be released with only
/// its pointer and length. A boxed slice does not require a `Vec` capacity.
pub fn owned_bytes_into_raw(bytes: Vec<u8>) -> (*mut u8, usize) {
    if bytes.is_empty() {
        return (std::ptr::null_mut(), 0);
    }

    let boxed = bytes.into_boxed_slice();
    let len = boxed.len();
    (Box::into_raw(boxed) as *mut u8, len)
}

/// Safely frees a C string allocated by Rust.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_free_string(ptr: *mut c_char) {
    ffi_void(|| {
        if !ptr.is_null() {
            drop(unsafe { CString::from_raw(ptr) });
        }
    });
}

/// Safely frees a byte buffer allocated by Rust.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_free_buffer(ptr: *mut u8, len: usize) {
    ffi_void(|| {
        if !ptr.is_null() && len > 0 {
            let slice = std::ptr::slice_from_raw_parts_mut(ptr, len);
            drop(unsafe { Box::<[u8]>::from_raw(slice) });
        }
    });
}

pub(crate) fn string_to_c_char(s: String) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

pub(crate) unsafe fn c_char_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        None
    } else {
        unsafe { std::ffi::CStr::from_ptr(ptr).to_str().ok() }
    }
}
