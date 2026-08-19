//! Swift-facing mirror of `capture_core::recording`.

use capture_core::recording;

use crate::geometry::CaptureSize;

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum RecordingFormatKind {
    Mp4,
    Gif,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum RecordingQualityKind {
    Compact,
    Standard,
    High,
}

#[derive(Clone, Copy, Debug, uniffi::Record)]
pub struct RecordingEncodingProfile {
    pub frame_rate: u32,
    pub max_dimension: u32,
    pub bits_per_pixel_per_frame: f64,
    pub minimum_video_bitrate: u32,
    pub maximum_video_bitrate: u32,
    pub maximum_duration: Option<f64>,
    pub maximum_frame_count: Option<u32>,
}

impl From<RecordingFormatKind> for recording::RecordingFormat {
    fn from(value: RecordingFormatKind) -> Self {
        match value {
            RecordingFormatKind::Mp4 => Self::Mp4,
            RecordingFormatKind::Gif => Self::Gif,
        }
    }
}

impl From<RecordingQualityKind> for recording::RecordingQuality {
    fn from(value: RecordingQualityKind) -> Self {
        match value {
            RecordingQualityKind::Compact => Self::Compact,
            RecordingQualityKind::Standard => Self::Standard,
            RecordingQualityKind::High => Self::High,
        }
    }
}

impl From<recording::EncodingProfile> for RecordingEncodingProfile {
    fn from(value: recording::EncodingProfile) -> Self {
        Self {
            frame_rate: value.frame_rate,
            max_dimension: value.max_dimension,
            bits_per_pixel_per_frame: value.bits_per_pixel_per_frame,
            minimum_video_bitrate: value.minimum_video_bitrate,
            maximum_video_bitrate: value.maximum_video_bitrate,
            maximum_duration: value.maximum_duration,
            maximum_frame_count: value.maximum_frame_count,
        }
    }
}

impl From<RecordingEncodingProfile> for recording::EncodingProfile {
    fn from(value: RecordingEncodingProfile) -> Self {
        Self {
            frame_rate: value.frame_rate,
            max_dimension: value.max_dimension,
            bits_per_pixel_per_frame: value.bits_per_pixel_per_frame,
            minimum_video_bitrate: value.minimum_video_bitrate,
            maximum_video_bitrate: value.maximum_video_bitrate,
            maximum_duration: value.maximum_duration,
            maximum_frame_count: value.maximum_frame_count,
        }
    }
}

#[uniffi::export]
pub fn recording_profile(
    quality: RecordingQualityKind,
    format: RecordingFormatKind,
) -> RecordingEncodingProfile {
    recording::profile(quality.into(), format.into()).into()
}

#[uniffi::export]
pub fn recording_output_size(
    profile: RecordingEncodingProfile,
    source_size: CaptureSize,
) -> CaptureSize {
    recording::EncodingProfile::from(profile)
        .output_size(source_size.into())
        .into()
}

#[uniffi::export]
pub fn recording_video_bitrate(
    profile: RecordingEncodingProfile,
    output_size: CaptureSize,
    override_frame_rate: Option<u32>,
) -> u32 {
    recording::EncodingProfile::from(profile).video_bitrate(output_size.into(), override_frame_rate)
}

#[uniffi::export]
pub fn recording_frame_rate_choices(format: RecordingFormatKind) -> Vec<u32> {
    recording::frame_rate_choices(format.into())
}

#[uniffi::export]
pub fn recording_normalized_frame_rate(requested: u32, format: RecordingFormatKind) -> u32 {
    recording::normalized_frame_rate(requested, format.into())
}
