use capture_core::stitch;
use std::sync::Mutex;

use crate::{
    POLYGLANCE_ERR_INVALID_CONFIG, POLYGLANCE_ERR_NULL_PTR, POLYGLANCE_ERR_STITCH_FAILED,
    POLYGLANCE_OK, ffi_status, ffi_void, owned_bytes_into_raw,
};

pub struct StitcherHandle {
    inner: Mutex<stitch::Stitcher>,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CStitchConfiguration {
    pub capture_interval: f64,
    pub maximum_frame_count: u32,
    pub maximum_output_width: u32,
    pub maximum_output_height: u32,
    pub maximum_pixel_count: u64,
    pub maximum_working_bytes: u64,
    pub minimum_overlap_rows: u32,
    pub maximum_scroll_fraction: f64,
    pub match_threshold: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CStitchAppendResult {
    pub disposition: i32, // 0: Initial, 1: Appended, 2: Unchanged
    pub offset: i64,
    pub frame_count: u32,
    pub total_width: u32,
    pub total_height: u32,
    pub limit_reached: i32, // 0: None, 1: Width, 2: Height, 3: Frames
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_stitcher_new(
    config: *const CStitchConfiguration,
    direction: i32, // 0: Vertical, 1: Horizontal
    out_stitcher: *mut *mut StitcherHandle,
) -> i32 {
    ffi_status(|| unsafe { stitcher_new(config, direction, out_stitcher) })
}

unsafe fn stitcher_new(
    config: *const CStitchConfiguration,
    direction: i32,
    out_stitcher: *mut *mut StitcherHandle,
) -> i32 {
    if config.is_null() || out_stitcher.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }

    let c = unsafe { &*config };
    let rust_config = stitch::Configuration {
        capture_interval: c.capture_interval,
        maximum_frame_count: c.maximum_frame_count,
        maximum_output_width: c.maximum_output_width as usize,
        maximum_output_height: c.maximum_output_height as usize,
        maximum_pixel_count: c.maximum_pixel_count as usize,
        maximum_working_bytes: c.maximum_working_bytes as usize,
        minimum_overlap_rows: c.minimum_overlap_rows as usize,
        maximum_scroll_fraction: c.maximum_scroll_fraction,
        match_threshold: c.match_threshold,
    };

    let dir = match direction {
        0 => stitch::Direction::Vertical,
        1 => stitch::Direction::Horizontal,
        _ => return POLYGLANCE_ERR_INVALID_CONFIG,
    };

    let stitcher = Box::new(StitcherHandle {
        inner: Mutex::new(stitch::Stitcher::new(rust_config, dir)),
    });

    unsafe {
        *out_stitcher = Box::into_raw(stitcher);
    }
    POLYGLANCE_OK
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_stitcher_free(stitcher: *mut StitcherHandle) {
    ffi_void(|| {
        if !stitcher.is_null() {
            drop(unsafe { Box::from_raw(stitcher) });
        }
    });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_stitcher_append(
    stitcher: *mut StitcherHandle,
    bytes: *const u8,
    len: usize,
    width: u32,
    height: u32,
    out_result: *mut CStitchAppendResult,
) -> i32 {
    ffi_status(|| unsafe { stitcher_append(stitcher, bytes, len, width, height, out_result) })
}

unsafe fn stitcher_append(
    stitcher: *mut StitcherHandle,
    bytes: *const u8,
    len: usize,
    width: u32,
    height: u32,
    out_result: *mut CStitchAppendResult,
) -> i32 {
    if stitcher.is_null() || bytes.is_null() || out_result.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }

    let slice = unsafe { std::slice::from_raw_parts(bytes, len) };
    let stitcher_ref = unsafe { &*stitcher };
    let mut guard = stitcher_ref.inner.lock().unwrap_or_else(|e| e.into_inner());

    match guard.append(slice.to_vec(), width, height) {
        Ok(res) => {
            let (disp, offset) = match res.disposition {
                stitch::Disposition::Initial => (0, 0),
                stitch::Disposition::Appended { offset, .. } => (1, offset),
                stitch::Disposition::Unchanged => (2, 0),
            };
            let limit = match res.limit_reached {
                None => 0,
                Some(stitch::Limit::OutputWidth) => 1,
                Some(stitch::Limit::OutputHeight) => 2,
                Some(stitch::Limit::FrameCount) => 3,
            };

            unsafe {
                *out_result = CStitchAppendResult {
                    disposition: disp,
                    offset,
                    frame_count: res.frame_count,
                    total_width: res.total_width,
                    total_height: res.total_height,
                    limit_reached: limit,
                };
            }
            POLYGLANCE_OK
        }
        Err(_) => POLYGLANCE_ERR_STITCH_FAILED,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_stitcher_render(
    stitcher: *mut StitcherHandle,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    ffi_status(|| unsafe { stitcher_render(stitcher, out_bytes, out_len) })
}

unsafe fn stitcher_render(
    stitcher: *mut StitcherHandle,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if stitcher.is_null() || out_bytes.is_null() || out_len.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }

    let stitcher_ref = unsafe { &*stitcher };
    let guard = stitcher_ref.inner.lock().unwrap_or_else(|e| e.into_inner());

    match guard.render() {
        Ok(buffer) => {
            let (pointer, length) = owned_bytes_into_raw(buffer);
            unsafe {
                *out_len = length;
                *out_bytes = pointer;
            }
            POLYGLANCE_OK
        }
        Err(_) => POLYGLANCE_ERR_STITCH_FAILED,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_stitcher_render_preview(
    stitcher: *mut StitcherHandle,
    max_pixel_width: u32,
    max_pixel_height: u32,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
    out_width: *mut u32,
    out_height: *mut u32,
) -> i32 {
    ffi_status(|| unsafe {
        stitcher_render_preview(
            stitcher,
            max_pixel_width,
            max_pixel_height,
            out_bytes,
            out_len,
            out_width,
            out_height,
        )
    })
}

#[allow(clippy::too_many_arguments)]
unsafe fn stitcher_render_preview(
    stitcher: *mut StitcherHandle,
    max_pixel_width: u32,
    max_pixel_height: u32,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
    out_width: *mut u32,
    out_height: *mut u32,
) -> i32 {
    if stitcher.is_null()
        || out_bytes.is_null()
        || out_len.is_null()
        || out_width.is_null()
        || out_height.is_null()
    {
        return POLYGLANCE_ERR_NULL_PTR;
    }

    let stitcher_ref = unsafe { &*stitcher };
    let guard = stitcher_ref.inner.lock().unwrap_or_else(|e| e.into_inner());

    match guard.render_preview(max_pixel_width as usize, max_pixel_height as usize) {
        Ok((buffer, w, h)) => {
            let (pointer, length) = owned_bytes_into_raw(buffer);
            unsafe {
                *out_len = length;
                *out_bytes = pointer;
                *out_width = w;
                *out_height = h;
            }
            POLYGLANCE_OK
        }
        Err(_) => POLYGLANCE_ERR_STITCH_FAILED,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_stitcher_get_dimensions(
    stitcher: *mut StitcherHandle,
    out_frame_count: *mut u32,
    out_width: *mut u32,
    out_height: *mut u32,
    out_offset: *mut i64,
) -> i32 {
    ffi_status(|| unsafe {
        stitcher_get_dimensions(stitcher, out_frame_count, out_width, out_height, out_offset)
    })
}

unsafe fn stitcher_get_dimensions(
    stitcher: *mut StitcherHandle,
    out_frame_count: *mut u32,
    out_width: *mut u32,
    out_height: *mut u32,
    out_offset: *mut i64,
) -> i32 {
    if stitcher.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }

    let stitcher_ref = unsafe { &*stitcher };
    let guard = stitcher_ref.inner.lock().unwrap_or_else(|e| e.into_inner());

    unsafe {
        if !out_frame_count.is_null() {
            *out_frame_count = guard.frame_count();
        }
        if !out_width.is_null() {
            *out_width = guard.output_width();
        }
        if !out_height.is_null() {
            *out_height = guard.output_height();
        }
        if !out_offset.is_null() {
            *out_offset = guard.current_frame_offset();
        }
    }

    POLYGLANCE_OK
}
