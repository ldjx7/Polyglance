use capture_core::recording::{self, EncodingProfile, RecordingFormat, RecordingQuality};
use capture_core::rect::Size;

use crate::{POLYGLANCE_ERR_INVALID_INPUT, POLYGLANCE_ERR_NULL_PTR, POLYGLANCE_OK, ffi_status};

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CEncodingProfile {
    pub frame_rate: u32,
    pub max_dimension: u32,
    pub bits_per_pixel_per_frame: f64,
    pub minimum_video_bitrate: u32,
    pub maximum_video_bitrate: u32,
    pub maximum_duration: f64,    // <= 0 means None
    pub maximum_frame_count: u32, // 0 means None
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_recording_get_profile(
    format: i32,  // 0: Mp4, 1: Gif
    quality: i32, // 0: Compact, 1: Standard, 2: High
    out_profile: *mut CEncodingProfile,
) -> i32 {
    ffi_status(|| unsafe { recording_get_profile(format, quality, out_profile) })
}

unsafe fn recording_get_profile(
    format: i32,
    quality: i32,
    out_profile: *mut CEncodingProfile,
) -> i32 {
    if out_profile.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }

    let fmt = match format {
        0 => RecordingFormat::Mp4,
        1 => RecordingFormat::Gif,
        _ => return POLYGLANCE_ERR_INVALID_INPUT,
    };

    let q = match quality {
        0 => RecordingQuality::Compact,
        1 => RecordingQuality::Standard,
        2 => RecordingQuality::High,
        _ => return POLYGLANCE_ERR_INVALID_INPUT,
    };

    let profile: EncodingProfile = recording::profile(q, fmt);

    unsafe {
        *out_profile = CEncodingProfile {
            frame_rate: profile.frame_rate,
            max_dimension: profile.max_dimension,
            bits_per_pixel_per_frame: profile.bits_per_pixel_per_frame,
            minimum_video_bitrate: profile.minimum_video_bitrate,
            maximum_video_bitrate: profile.maximum_video_bitrate,
            maximum_duration: profile.maximum_duration.unwrap_or(0.0),
            maximum_frame_count: profile.maximum_frame_count.unwrap_or(0),
        };
    }

    POLYGLANCE_OK
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_recording_calculate_output(
    format: i32,
    quality: i32,
    source_width: f64,
    source_height: f64,
    override_fps: u32,
    out_width: *mut f64,
    out_height: *mut f64,
    out_bitrate: *mut u32,
) -> i32 {
    ffi_status(|| unsafe {
        recording_calculate_output(
            format,
            quality,
            source_width,
            source_height,
            override_fps,
            out_width,
            out_height,
            out_bitrate,
        )
    })
}

#[allow(clippy::too_many_arguments)]
unsafe fn recording_calculate_output(
    format: i32,
    quality: i32,
    source_width: f64,
    source_height: f64,
    override_fps: u32,
    out_width: *mut f64,
    out_height: *mut f64,
    out_bitrate: *mut u32,
) -> i32 {
    if out_width.is_null() || out_height.is_null() || out_bitrate.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }

    let fmt = match format {
        0 => RecordingFormat::Mp4,
        1 => RecordingFormat::Gif,
        _ => return POLYGLANCE_ERR_INVALID_INPUT,
    };

    let q = match quality {
        0 => RecordingQuality::Compact,
        1 => RecordingQuality::Standard,
        2 => RecordingQuality::High,
        _ => return POLYGLANCE_ERR_INVALID_INPUT,
    };

    let profile = recording::profile(q, fmt);
    let size = profile.output_size(Size::new(source_width, source_height));
    let fps_override = if override_fps > 0 {
        Some(override_fps)
    } else {
        None
    };
    let bitrate = profile.video_bitrate(size, fps_override);

    unsafe {
        *out_width = size.width;
        *out_height = size.height;
        *out_bitrate = bitrate;
    }

    POLYGLANCE_OK
}
