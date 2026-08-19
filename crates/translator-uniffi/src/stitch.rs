//! Swift-facing mirror of `capture_core::stitch`.
//!
//! The stitcher owns pixel state across calls, so it is exposed as an object
//! guarded by a mutex rather than as free functions.

use std::sync::Mutex;

use capture_core::stitch;

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum StitchDirection {
    Vertical,
    Horizontal,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum StitchLimit {
    OutputWidth,
    OutputHeight,
    FrameCount,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum StitchDisposition {
    Initial,
    Appended {
        direction: StitchDirection,
        offset: i64,
    },
    Unchanged,
}

#[derive(Clone, Copy, Debug, uniffi::Record)]
pub struct StitchAppendResult {
    pub disposition: StitchDisposition,
    pub frame_count: u32,
    pub total_width: u32,
    pub total_height: u32,
    pub limit_reached: Option<StitchLimit>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct StitchPreview {
    pub bytes: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Copy, Debug, uniffi::Record)]
pub struct StitchConfiguration {
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

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum StitchFailure {
    #[error("invalid configuration")]
    InvalidConfiguration,
    #[error("invalid frame")]
    InvalidFrame,
    #[error("frame dimensions changed")]
    FrameDimensionsChanged,
    #[error("no reliable overlap")]
    NoReliableVerticalOverlap,
    #[error("pixel limit exceeded")]
    PixelLimitExceeded,
    #[error("working memory limit exceeded")]
    WorkingMemoryLimitExceeded,
    #[error("frame limit exceeded")]
    FrameLimitExceeded,
    #[error("no frames")]
    NoFrames,
}

impl From<stitch::StitchError> for StitchFailure {
    fn from(value: stitch::StitchError) -> Self {
        match value {
            stitch::StitchError::InvalidConfiguration => Self::InvalidConfiguration,
            stitch::StitchError::InvalidFrame => Self::InvalidFrame,
            stitch::StitchError::FrameDimensionsChanged => Self::FrameDimensionsChanged,
            stitch::StitchError::NoReliableVerticalOverlap => Self::NoReliableVerticalOverlap,
            stitch::StitchError::PixelLimitExceeded => Self::PixelLimitExceeded,
            stitch::StitchError::WorkingMemoryLimitExceeded => Self::WorkingMemoryLimitExceeded,
            stitch::StitchError::FrameLimitExceeded => Self::FrameLimitExceeded,
            stitch::StitchError::NoFrames => Self::NoFrames,
        }
    }
}

impl From<StitchDirection> for stitch::Direction {
    fn from(value: StitchDirection) -> Self {
        match value {
            StitchDirection::Vertical => Self::Vertical,
            StitchDirection::Horizontal => Self::Horizontal,
        }
    }
}

impl From<stitch::Direction> for StitchDirection {
    fn from(value: stitch::Direction) -> Self {
        match value {
            stitch::Direction::Vertical => Self::Vertical,
            stitch::Direction::Horizontal => Self::Horizontal,
        }
    }
}

impl From<stitch::Limit> for StitchLimit {
    fn from(value: stitch::Limit) -> Self {
        match value {
            stitch::Limit::OutputWidth => Self::OutputWidth,
            stitch::Limit::OutputHeight => Self::OutputHeight,
            stitch::Limit::FrameCount => Self::FrameCount,
        }
    }
}

impl From<stitch::AppendResult> for StitchAppendResult {
    fn from(value: stitch::AppendResult) -> Self {
        Self {
            disposition: match value.disposition {
                stitch::Disposition::Initial => StitchDisposition::Initial,
                stitch::Disposition::Unchanged => StitchDisposition::Unchanged,
                stitch::Disposition::Appended { direction, offset } => {
                    StitchDisposition::Appended {
                        direction: direction.into(),
                        offset,
                    }
                }
            },
            frame_count: value.frame_count,
            total_width: value.total_width,
            total_height: value.total_height,
            limit_reached: value.limit_reached.map(Into::into),
        }
    }
}

impl From<StitchConfiguration> for stitch::Configuration {
    fn from(value: StitchConfiguration) -> Self {
        Self {
            capture_interval: value.capture_interval,
            maximum_frame_count: value.maximum_frame_count,
            maximum_output_width: value.maximum_output_width as usize,
            maximum_output_height: value.maximum_output_height as usize,
            maximum_pixel_count: value.maximum_pixel_count as usize,
            maximum_working_bytes: value.maximum_working_bytes as usize,
            minimum_overlap_rows: value.minimum_overlap_rows as usize,
            maximum_scroll_fraction: value.maximum_scroll_fraction,
            match_threshold: value.match_threshold,
        }
    }
}

#[derive(uniffi::Object)]
pub struct LongScreenshotStitcher {
    inner: Mutex<stitch::Stitcher>,
}

#[uniffi::export]
impl LongScreenshotStitcher {
    #[uniffi::constructor]
    pub fn new(configuration: StitchConfiguration, direction: StitchDirection) -> Self {
        Self {
            inner: Mutex::new(stitch::Stitcher::new(
                configuration.into(),
                direction.into(),
            )),
        }
    }

    pub fn append(
        &self,
        bytes: Vec<u8>,
        width: u32,
        height: u32,
    ) -> Result<StitchAppendResult, StitchFailure> {
        self.locked()
            .append(bytes, width, height)
            .map(Into::into)
            .map_err(Into::into)
    }

    pub fn render(&self) -> Result<Vec<u8>, StitchFailure> {
        self.locked().render().map_err(Into::into)
    }

    pub fn render_preview(
        &self,
        maximum_pixel_width: u32,
        maximum_pixel_height: u32,
    ) -> Result<StitchPreview, StitchFailure> {
        self.locked()
            .render_preview(maximum_pixel_width as usize, maximum_pixel_height as usize)
            .map(|(bytes, width, height)| StitchPreview {
                bytes,
                width,
                height,
            })
            .map_err(Into::into)
    }

    pub fn set_direction(&self, direction: StitchDirection) -> bool {
        self.locked().set_direction(direction.into())
    }

    pub fn direction(&self) -> StitchDirection {
        self.locked().direction().into()
    }

    pub fn frame_count(&self) -> u32 {
        self.locked().frame_count()
    }

    pub fn output_width(&self) -> u32 {
        self.locked().output_width()
    }

    pub fn output_height(&self) -> u32 {
        self.locked().output_height()
    }

    pub fn current_frame_offset(&self) -> i64 {
        self.locked().current_frame_offset()
    }
}

impl LongScreenshotStitcher {
    fn locked(&self) -> std::sync::MutexGuard<'_, stitch::Stitcher> {
        self.inner.lock().unwrap_or_else(|error| error.into_inner())
    }
}
