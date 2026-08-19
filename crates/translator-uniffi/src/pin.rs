//! Swift-facing mirror of `capture_core::pin` and `capture_core::alignment`.

use capture_core::{alignment, pin};

use crate::geometry::{CapturePoint, CaptureRect, CaptureSize};

#[derive(Clone, Copy, Debug, uniffi::Record)]
pub struct PinSizeLimits {
    pub minimum: CaptureSize,
    pub maximum: CaptureSize,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct TranslationSegmentPair {
    pub id: u32,
    pub source_text: String,
    pub target_text: String,
    pub source_location: u32,
    pub source_length: u32,
    pub target_location: u32,
    pub target_length: u32,
}

impl From<alignment::SegmentPair> for TranslationSegmentPair {
    fn from(value: alignment::SegmentPair) -> Self {
        Self {
            id: value.id,
            source_text: value.source_text,
            target_text: value.target_text,
            source_location: value.source_location,
            source_length: value.source_length,
            target_location: value.target_location,
            target_length: value.target_length,
        }
    }
}

impl From<TranslationSegmentPair> for alignment::SegmentPair {
    fn from(value: TranslationSegmentPair) -> Self {
        Self {
            id: value.id,
            source_text: value.source_text,
            target_text: value.target_text,
            source_location: value.source_location,
            source_length: value.source_length,
            target_location: value.target_location,
            target_length: value.target_length,
        }
    }
}

#[uniffi::export]
pub fn pin_operable_initial_size(image_size: CaptureSize, maximum_size: CaptureSize) -> CaptureSize {
    pin::operable_initial_size(image_size.into(), maximum_size.into()).into()
}

#[uniffi::export]
pub fn pin_size_limits(initial_size: CaptureSize) -> PinSizeLimits {
    let limits = pin::size_limits(initial_size.into());
    PinSizeLimits {
        minimum: limits.minimum.into(),
        maximum: limits.maximum.into(),
    }
}

#[uniffi::export]
pub fn pin_scaled_frame(
    frame: CaptureRect,
    requested_scale: f64,
    anchor_in_window: CapturePoint,
    minimum_size: CaptureSize,
    maximum_size: CaptureSize,
) -> CaptureRect {
    pin::scaled_frame(
        frame.into(),
        requested_scale,
        anchor_in_window.into(),
        minimum_size.into(),
        maximum_size.into(),
    )
    .into()
}

#[uniffi::export]
pub fn pin_origin_keeping_window_visible(
    proposed_origin: CapturePoint,
    window_size: CaptureSize,
    visible_frame: CaptureRect,
    minimum_visible_length: f64,
) -> CapturePoint {
    pin::origin_keeping_window_visible(
        proposed_origin.into(),
        window_size.into(),
        visible_frame.into(),
        minimum_visible_length,
    )
    .into()
}

#[uniffi::export]
pub fn translation_alignment_pairs(source: String, target: String) -> Vec<TranslationSegmentPair> {
    alignment::pairs(&source, &target)
        .into_iter()
        .map(Into::into)
        .collect()
}

#[uniffi::export]
pub fn translation_alignment_pair_id(
    character_index: u32,
    in_source: bool,
    pairs: Vec<TranslationSegmentPair>,
) -> Option<u32> {
    let pairs: Vec<alignment::SegmentPair> = pairs.into_iter().map(Into::into).collect();
    alignment::pair_id(character_index, in_source, &pairs)
}
