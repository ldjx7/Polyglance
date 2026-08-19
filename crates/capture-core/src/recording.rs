//! Recording encode policy: profile table, output sizing, and bitrate.

use crate::rect::Size;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordingFormat {
    Mp4,
    Gif,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordingQuality {
    Compact,
    Standard,
    High,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EncodingProfile {
    pub frame_rate: u32,
    pub max_dimension: u32,
    pub bits_per_pixel_per_frame: f64,
    pub minimum_video_bitrate: u32,
    pub maximum_video_bitrate: u32,
    pub maximum_duration: Option<f64>,
    pub maximum_frame_count: Option<u32>,
}

impl EncodingProfile {
    pub fn output_size(&self, source_size: Size) -> Size {
        if !source_size.width.is_finite()
            || !source_size.height.is_finite()
            || source_size.width <= 0.0
            || source_size.height <= 0.0
        {
            return Size::ZERO;
        }
        let longest_side = source_size.width.max(source_size.height);
        let scale = 1.0_f64.min(f64::from(self.max_dimension) / longest_side);
        Size::new(
            even_dimension(source_size.width * scale),
            even_dimension(source_size.height * scale),
        )
    }

    pub fn video_bitrate(&self, output_size: Size, override_frame_rate: Option<u32>) -> u32 {
        if self.bits_per_pixel_per_frame <= 0.0
            || self.minimum_video_bitrate == 0
            || self.maximum_video_bitrate < self.minimum_video_bitrate
        {
            return 0;
        }
        let fps = override_frame_rate.unwrap_or(self.frame_rate).max(1);
        let estimate = (output_size.width
            * output_size.height
            * f64::from(fps)
            * self.bits_per_pixel_per_frame)
            .round();
        let estimate = if estimate <= 0.0 {
            0
        } else if estimate >= f64::from(u32::MAX) {
            u32::MAX
        } else {
            estimate as u32
        };
        estimate
            .max(self.minimum_video_bitrate)
            .min(self.maximum_video_bitrate)
    }
}

pub fn profile(quality: RecordingQuality, format: RecordingFormat) -> EncodingProfile {
    match (quality, format) {
        (RecordingQuality::Compact, RecordingFormat::Mp4) => EncodingProfile {
            frame_rate: 24,
            max_dimension: 1_920,
            bits_per_pixel_per_frame: 0.07,
            minimum_video_bitrate: 1_000_000,
            maximum_video_bitrate: 12_000_000,
            maximum_duration: None,
            maximum_frame_count: None,
        },
        (RecordingQuality::Standard, RecordingFormat::Mp4) => EncodingProfile {
            frame_rate: 30,
            max_dimension: 2_560,
            bits_per_pixel_per_frame: 0.10,
            minimum_video_bitrate: 2_000_000,
            maximum_video_bitrate: 24_000_000,
            maximum_duration: None,
            maximum_frame_count: None,
        },
        (RecordingQuality::High, RecordingFormat::Mp4) => EncodingProfile {
            frame_rate: 60,
            max_dimension: 3_840,
            bits_per_pixel_per_frame: 0.13,
            minimum_video_bitrate: 4_000_000,
            maximum_video_bitrate: 50_000_000,
            maximum_duration: None,
            maximum_frame_count: None,
        },
        (RecordingQuality::Compact, RecordingFormat::Gif) => EncodingProfile {
            frame_rate: 8,
            max_dimension: 960,
            bits_per_pixel_per_frame: 0.0,
            minimum_video_bitrate: 0,
            maximum_video_bitrate: 0,
            maximum_duration: Some(90.0),
            maximum_frame_count: Some(720),
        },
        (RecordingQuality::Standard, RecordingFormat::Gif) => EncodingProfile {
            frame_rate: 12,
            max_dimension: 1_280,
            bits_per_pixel_per_frame: 0.0,
            minimum_video_bitrate: 0,
            maximum_video_bitrate: 0,
            maximum_duration: Some(60.0),
            maximum_frame_count: Some(720),
        },
        (RecordingQuality::High, RecordingFormat::Gif) => EncodingProfile {
            frame_rate: 15,
            max_dimension: 1_600,
            bits_per_pixel_per_frame: 0.0,
            minimum_video_bitrate: 0,
            maximum_video_bitrate: 0,
            maximum_duration: Some(45.0),
            maximum_frame_count: Some(675),
        },
    }
}

pub fn frame_rate_choices(format: RecordingFormat) -> Vec<u32> {
    match format {
        RecordingFormat::Mp4 => vec![5, 16, 24, 30, 60],
        RecordingFormat::Gif => vec![5, 16],
    }
}

/// Picks the closest supported rate, preferring the higher one on a tie.
pub fn normalized_frame_rate(requested: u32, format: RecordingFormat) -> u32 {
    let supported = frame_rate_choices(format);
    supported
        .into_iter()
        .reduce(|left, right| {
            let left_distance = left.abs_diff(requested);
            let right_distance = right.abs_diff(requested);
            if left_distance == right_distance {
                if left > right { left } else { right }
            } else if left_distance < right_distance {
                left
            } else {
                right
            }
        })
        .unwrap_or(30)
}

fn even_dimension(value: f64) -> f64 {
    let rounded = (value.round() as i64).max(2);
    (rounded - rounded % 2) as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn output_size_is_capped_and_always_even() {
        let profile = profile(RecordingQuality::Standard, RecordingFormat::Mp4);
        let size = profile.output_size(Size::new(5120.0, 2880.0));

        assert_eq!(size, Size::new(2560.0, 1440.0));
        assert_eq!(size.width % 2.0, 0.0);
        assert_eq!(size.height % 2.0, 0.0);
    }

    #[test]
    fn output_size_never_upscales() {
        let profile = profile(RecordingQuality::High, RecordingFormat::Mp4);

        assert_eq!(
            profile.output_size(Size::new(640.0, 480.0)),
            Size::new(640.0, 480.0)
        );
    }

    #[test]
    fn odd_sizes_round_down_to_even() {
        let profile = profile(RecordingQuality::Standard, RecordingFormat::Mp4);

        assert_eq!(
            profile.output_size(Size::new(101.0, 51.0)),
            Size::new(100.0, 50.0)
        );
    }

    #[test]
    fn degenerate_sizes_collapse_to_zero() {
        let profile = profile(RecordingQuality::Standard, RecordingFormat::Mp4);

        assert_eq!(profile.output_size(Size::ZERO), Size::ZERO);
        assert_eq!(profile.output_size(Size::new(f64::NAN, 10.0)), Size::ZERO);
    }

    #[test]
    fn bitrate_stays_inside_the_profile_bounds() {
        let profile = profile(RecordingQuality::Standard, RecordingFormat::Mp4);

        assert_eq!(profile.video_bitrate(Size::new(64.0, 64.0), None), 2_000_000);
        assert_eq!(
            profile.video_bitrate(Size::new(7680.0, 4320.0), None),
            24_000_000
        );
    }

    #[test]
    fn gif_profiles_report_no_bitrate() {
        let profile = profile(RecordingQuality::Standard, RecordingFormat::Gif);

        assert_eq!(profile.video_bitrate(Size::new(1280.0, 720.0), None), 0);
        assert_eq!(profile.maximum_duration, Some(60.0));
        assert_eq!(profile.maximum_frame_count, Some(720));
    }

    #[test]
    fn overriding_the_frame_rate_changes_the_estimate() {
        let profile = profile(RecordingQuality::Standard, RecordingFormat::Mp4);
        let low = profile.video_bitrate(Size::new(1280.0, 720.0), Some(5));
        let high = profile.video_bitrate(Size::new(1280.0, 720.0), Some(60));

        assert!(low < high);
    }

    #[test]
    fn gif_only_offers_the_rates_it_can_encode() {
        assert_eq!(frame_rate_choices(RecordingFormat::Gif), vec![5, 16]);
        assert_eq!(
            frame_rate_choices(RecordingFormat::Mp4),
            vec![5, 16, 24, 30, 60]
        );
    }

    #[test]
    fn unsupported_rates_snap_to_the_nearest_choice() {
        assert_eq!(normalized_frame_rate(30, RecordingFormat::Gif), 16);
        assert_eq!(normalized_frame_rate(6, RecordingFormat::Gif), 5);
        assert_eq!(normalized_frame_rate(30, RecordingFormat::Mp4), 30);
        assert_eq!(normalized_frame_rate(1000, RecordingFormat::Mp4), 60);
    }

    #[test]
    fn ties_prefer_the_higher_rate() {
        assert_eq!(normalized_frame_rate(27, RecordingFormat::Mp4), 30);
        assert_eq!(normalized_frame_rate(45, RecordingFormat::Mp4), 60);
        assert_eq!(normalized_frame_rate(10, RecordingFormat::Gif), 5);
    }
}
