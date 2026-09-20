//! Long-screenshot stitching: overlap detection and frame splicing.
//!
//! Frames arrive as tightly packed 8-bit RGBA, so the platform only owns image
//! decoding and encoding.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Vertical,
    Horizontal,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Limit {
    OutputWidth,
    OutputHeight,
    FrameCount,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Disposition {
    Initial,
    Appended { direction: Direction, offset: i64 },
    Unchanged,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AppendResult {
    pub disposition: Disposition,
    pub frame_count: u32,
    pub total_width: u32,
    pub total_height: u32,
    pub limit_reached: Option<Limit>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StitchError {
    InvalidConfiguration,
    InvalidFrame,
    FrameDimensionsChanged,
    NoReliableVerticalOverlap,
    PixelLimitExceeded,
    WorkingMemoryLimitExceeded,
    FrameLimitExceeded,
    NoFrames,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Configuration {
    pub capture_interval: f64,
    pub maximum_frame_count: u32,
    pub maximum_output_width: usize,
    pub maximum_output_height: usize,
    pub maximum_pixel_count: usize,
    pub maximum_working_bytes: usize,
    pub minimum_overlap_rows: usize,
    pub maximum_scroll_fraction: f64,
    pub match_threshold: f64,
}

impl Default for Configuration {
    fn default() -> Self {
        Self {
            capture_interval: 0.033,
            maximum_frame_count: 10_000,
            maximum_output_width: 32_768,
            maximum_output_height: 32_768,
            maximum_pixel_count: 80_000_000,
            maximum_working_bytes: 384 * 1_024 * 1_024,
            minimum_overlap_rows: 32,
            maximum_scroll_fraction: 0.8,
            match_threshold: 0.035,
        }
    }
}

struct PixelFrame {
    width: usize,
    height: usize,
    bytes: Vec<u8>,
}

impl PixelFrame {
    fn byte_count(&self) -> usize {
        self.bytes.len()
    }
}

/// Chrome at the edges of every frame whose pixels stay put while the page
/// moves. `leading` and `trailing` count lines across the scroll axis (rows
/// when scrolling vertically): a sticky header, a fixed footer, a toolbar.
/// They are left out of overlap scoring and never spliced into the output as
/// if they were page content. `cross_leading` and `cross_trailing` count lines
/// along the scroll axis (columns when scrolling vertically): a sidebar or a
/// scrollbar track. Those only distort scoring, so they are skipped there but
/// stay part of the picture.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct StaticBands {
    leading: usize,
    trailing: usize,
    cross_leading: usize,
    cross_trailing: usize,
}

impl StaticBands {
    fn merged(self, other: Self) -> Self {
        Self {
            leading: self.leading.max(other.leading),
            trailing: self.trailing.max(other.trailing),
            cross_leading: self.cross_leading.max(other.cross_leading),
            cross_trailing: self.cross_trailing.max(other.cross_trailing),
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CropInsets {
    pub top: usize,
    pub bottom: usize,
    pub left: usize,
    pub right: usize,
}

pub struct Stitcher {
    configuration: Configuration,
    direction: Direction,
    output_bytes: Vec<u8>,
    previous_frame: Option<PixelFrame>,
    did_extend_output: bool,
    output_axis_origin: i64,
    output_axis_end: i64,
    previous_frame_axis_origin: i64,
    frame_count: u32,
    output_width: usize,
    output_height: usize,
    current_frame_offset: i64,
    predicted_offset: i64,
    static_bands: StaticBands,
    crop_insets: CropInsets,
}

impl Stitcher {
    pub fn new(configuration: Configuration, direction: Direction) -> Self {
        Self {
            configuration,
            direction,
            output_bytes: Vec::new(),
            previous_frame: None,
            did_extend_output: false,
            output_axis_origin: 0,
            output_axis_end: 0,
            previous_frame_axis_origin: 0,
            frame_count: 0,
            output_width: 0,
            output_height: 0,
            current_frame_offset: 0,
            predicted_offset: 0,
            static_bands: StaticBands::default(),
            crop_insets: CropInsets::default(),
        }
    }

    pub fn frame_count(&self) -> u32 {
        self.frame_count
    }

    pub fn output_width(&self) -> u32 {
        self.output_width as u32
    }

    pub fn output_height(&self) -> u32 {
        self.output_height as u32
    }

    pub fn current_frame_offset(&self) -> i64 {
        self.current_frame_offset
    }

    pub fn direction(&self) -> Direction {
        self.direction
    }

    pub fn set_direction(&mut self, direction: Direction) -> bool {
        if self.did_extend_output {
            return false;
        }
        self.direction = direction;
        self.output_axis_origin = 0;
        self.output_axis_end = if direction == Direction::Vertical {
            self.output_height as i64
        } else {
            self.output_width as i64
        };
        self.previous_frame_axis_origin = if direction == Direction::Vertical {
            -(self.crop_insets.top as i64)
        } else {
            -(self.crop_insets.left as i64)
        };
        self.current_frame_offset = 0;
        self.predicted_offset = 0;
        self.static_bands = StaticBands::default();
        true
    }

    pub fn set_crop_insets(&mut self, top: usize, bottom: usize, left: usize, right: usize) -> bool {
        if self.did_extend_output {
            return false;
        }
        self.crop_insets = CropInsets { top, bottom, left, right };
        self.previous_frame_axis_origin = if self.direction == Direction::Vertical {
            -(top as i64)
        } else {
            -(left as i64)
        };
        true
    }

    pub fn crop_insets(&self) -> CropInsets {
        self.crop_insets
    }

    pub fn append(
        &mut self,
        bytes: Vec<u8>,
        width: u32,
        height: u32,
    ) -> Result<AppendResult, StitchError> {
        self.validate_configuration()?;
        let frame = normalized_frame(bytes, width as usize, height as usize)?;
        let Some(previous) = self.previous_frame.as_ref() else {
            return self.accept_initial_frame(frame);
        };
        if frame.width != previous.width || frame.height != previous.height {
            return Err(StitchError::FrameDimensionsChanged);
        }
        if previous.bytes == frame.bytes {
            self.previous_frame = Some(frame);
            return Ok(self.result(Disposition::Unchanged, false, false));
        }

        let configuration = self.configuration;
        let direction = self.direction;
        let learned = self.static_bands;
        let estimate = |bands: StaticBands| {
            estimated_offset(
                &configuration,
                direction,
                previous,
                &frame,
                self.predicted_offset,
                bands,
            )
        };
        let offset = match estimate(learned) {
            Ok(offset) => offset,
            Err(error) => {
                // Chrome that never moves can outweigh the page inside the
                // overlap score, so a failed match is retried with every line
                // that stayed put left out. Without a known offset this can
                // also catch content that merely repeats, which is harmless
                // for scoring and is never remembered.
                let widened =
                    learned.merged(detect_static_bands(previous, &frame, direction, None));
                let retry = if widened == learned {
                    Err(error)
                } else {
                    estimate(widened)
                };
                match retry {
                    Ok(offset) => offset,
                    Err(error) => {
                        // The rejected frame is dropped, so the next comparison
                        // spans a longer interval than this one did. Keeping the
                        // prediction would aim the search at a distance that is
                        // already stale and bias it towards a too-small match;
                        // decay it towards zero so the window is visited outward
                        // from a neutral guess instead.
                        self.predicted_offset /= 2;
                        return Err(error);
                    }
                }
            }
        };
        if offset == 0 {
            // Lines that stayed identical between two stationary captures say
            // nothing about chrome, so nothing is learned from this pair.
            self.previous_frame = Some(frame);
            return Ok(self.result(Disposition::Unchanged, false, false));
        }
        // The page moved, so whatever is still identical at the same position
        // and did not travel with the page is fixed chrome: remember it for
        // the frames that follow.
        let bands = learned.merged(detect_static_bands(
            previous,
            &frame,
            direction,
            Some(offset),
        ));
        self.static_bands = bands;
        self.predicted_offset = offset;
        let outcome = self.extend_output(&frame, offset, bands);
        self.previous_frame = Some(frame);
        outcome
    }

    fn effective_crop_insets(&self, frame: &PixelFrame) -> CropInsets {
        if frame.width > self.crop_insets.left + self.crop_insets.right
            && frame.height > self.crop_insets.top + self.crop_insets.bottom
        {
            self.crop_insets
        } else {
            CropInsets::default()
        }
    }

    fn accept_initial_frame(&mut self, frame: PixelFrame) -> Result<AppendResult, StitchError> {
        let insets = self.effective_crop_insets(&frame);
        let crop_width = frame
            .width
            .saturating_sub(insets.left + insets.right);
        let crop_height = frame
            .height
            .saturating_sub(insets.top + insets.bottom);
        if crop_width == 0 || crop_height == 0 {
            return Err(StitchError::InvalidFrame);
        }
        self.validate_working_memory(crop_width * crop_height * 4, frame.byte_count())?;
        let accepted_width = crop_width.min(self.configuration.maximum_output_width);
        let accepted_height = crop_height.min(self.configuration.maximum_output_height);
        self.validate_pixel_count(accepted_width, accepted_height)?;
        self.frame_count = 1;
        self.output_bytes = cropped_subframe(
            &frame,
            insets.left,
            insets.top,
            accepted_width,
            accepted_height,
        );
        self.output_width = accepted_width;
        self.output_height = accepted_height;
        self.output_axis_origin = 0;
        self.output_axis_end = if self.direction == Direction::Vertical {
            accepted_height as i64
        } else {
            accepted_width as i64
        };
        self.previous_frame_axis_origin = if self.direction == Direction::Vertical {
            -(insets.top as i64)
        } else {
            -(insets.left as i64)
        };
        self.current_frame_offset = 0;
        let width_limit_reached = accepted_width < crop_width
            || accepted_width == self.configuration.maximum_output_width;
        let height_limit_reached = accepted_height < crop_height
            || accepted_height == self.configuration.maximum_output_height;
        self.previous_frame = Some(frame);
        Ok(self.result(
            Disposition::Initial,
            width_limit_reached,
            height_limit_reached,
        ))
    }

    fn extend_output(
        &mut self,
        frame: &PixelFrame,
        signed_offset: i64,
        bands: StaticBands,
    ) -> Result<AppendResult, StitchError> {
        let vertical = self.direction == Direction::Vertical;
        let (frame_length, _cross_length) = if vertical {
            (frame.height, frame.width)
        } else {
            (frame.width, frame.height)
        };
        let insets = self.effective_crop_insets(frame);
        let (leading_crop, trailing_crop) = if vertical {
            (insets.top, insets.bottom)
        } else {
            (insets.left, insets.right)
        };
        let effective_leading = leading_crop.max(bands.leading);
        let effective_trailing = trailing_crop.max(bands.trailing);
        let visible_length = frame_length.saturating_sub(effective_leading + effective_trailing);
        let current_origin = self.previous_frame_axis_origin + signed_offset;
        let visible_start = current_origin + effective_leading as i64;
        let visible_end = current_origin + (frame_length.saturating_sub(effective_trailing)) as i64;
        let requested_before =
            ((self.output_axis_origin - visible_start).max(0) as usize).min(visible_length);
        let requested_after =
            ((visible_end - self.output_axis_end).max(0) as usize).min(visible_length);
        self.previous_frame_axis_origin = current_origin;

        if requested_before == 0 && requested_after == 0 {
            self.current_frame_offset = current_origin + leading_crop as i64 - self.output_axis_origin;
            return Ok(self.result(Disposition::Unchanged, false, false));
        }
        if self.frame_count >= self.configuration.maximum_frame_count {
            return Err(StitchError::FrameLimitExceeded);
        }

        let current_length = if vertical {
            self.output_height
        } else {
            self.output_width
        };
        let output_cross = if vertical {
            self.output_width
        } else {
            self.output_height
        };
        let remaining =
            self.remaining_axis_budget(output_cross, current_length, frame.byte_count());
        let lines_before = requested_before.min(remaining);
        let lines_after = requested_after.min(remaining - lines_before);
        let limit_reached = lines_before < requested_before
            || lines_after < requested_after
            || remaining == lines_before + lines_after;
        if lines_before + lines_after > 0 {
            self.frame_count += 1;
        }

        if lines_before > 0 {
            let first = effective_leading + requested_before - lines_before;
            if vertical {
                self.prepend_rows(frame, first, lines_before);
            } else {
                self.prepend_columns(frame, first, lines_before);
            }
            self.output_axis_origin -= lines_before as i64;
        }
        if lines_after > 0 {
            let first = frame_length - effective_trailing - requested_after;
            if vertical {
                self.append_rows(frame, first, lines_after);
            } else {
                self.append_columns(frame, first, lines_after);
            }
            self.output_axis_end += lines_after as i64;
        }
        if vertical {
            self.output_height = current_length + lines_before + lines_after;
        } else {
            self.output_width = current_length + lines_before + lines_after;
        }
        // Refresh the overlap from this frame only when static chrome in the
        // direction of scroll needs to be replaced by newly revealed content,
        // so transient hover highlights on existing rows are never written
        // over previously clean output rows.
        let needs_overwrite = (signed_offset > 0 && bands.trailing > 0)
            || (signed_offset < 0 && bands.leading > 0);
        if needs_overwrite {
            self.overwrite_overlap(frame, signed_offset, current_origin, bands);
        }
        self.did_extend_output = self.did_extend_output || lines_before > 0 || lines_after > 0;
        self.current_frame_offset = current_origin + leading_crop as i64 - self.output_axis_origin;
        Ok(self.result(
            Disposition::Appended {
                direction: self.direction,
                offset: signed_offset,
            },
            !vertical && limit_reached,
            vertical && limit_reached,
        ))
    }

    /// How many more lines the output may grow along the scroll axis before
    /// the size, pixel-count or working-memory budget is exhausted. Growth is
    /// clamped to this rather than refused, so a long capture ends with the
    /// content it has instead of an error.
    fn remaining_axis_budget(
        &self,
        cross_length: usize,
        current_length: usize,
        frame_bytes: usize,
    ) -> usize {
        let configuration = &self.configuration;
        let axis_cap = if self.direction == Direction::Vertical {
            configuration.maximum_output_height
        } else {
            configuration.maximum_output_width
        };
        let cross_length = cross_length.max(1);
        let by_axis = axis_cap.saturating_sub(current_length);
        let by_pixels =
            (configuration.maximum_pixel_count / cross_length).saturating_sub(current_length);
        let by_memory = (configuration
            .maximum_working_bytes
            .saturating_sub(frame_bytes.saturating_mul(2))
            / (cross_length * 4))
            .saturating_sub(current_length);
        by_axis.min(by_pixels).min(by_memory)
    }

    fn overwrite_overlap(
        &mut self,
        frame: &PixelFrame,
        signed_offset: i64,
        current_origin: i64,
        bands: StaticBands,
    ) {
        let vertical = self.direction == Direction::Vertical;
        let frame_length = if vertical { frame.height } else { frame.width };
        let insets = self.effective_crop_insets(frame);
        let (leading_crop, trailing_crop) = if vertical {
            (insets.top, insets.bottom)
        } else {
            (insets.left, insets.right)
        };
        let effective_leading = leading_crop.max(bands.leading);
        let effective_trailing = trailing_crop.max(bands.trailing);

        // Only overwrite the band region that was masked by chrome in the previous frame
        // and has now been revealed as real page content by scrolling.
        // Never overwrite intermediate content rows, preserving them free of transient hover highlights.
        let previous_origin = current_origin - signed_offset;
        let (patch_start, patch_end) = if signed_offset > 0 {
            if effective_trailing == 0 {
                return;
            }
            (
                previous_origin + (frame_length.saturating_sub(effective_trailing)) as i64,
                previous_origin + frame_length as i64,
            )
        } else if signed_offset < 0 {
            if effective_leading == 0 {
                return;
            }
            (previous_origin, previous_origin + effective_leading as i64)
        } else {
            return;
        };

        let visible_start = current_origin + effective_leading as i64;
        let visible_end = current_origin + (frame_length.saturating_sub(effective_trailing)) as i64;
        let start = patch_start.max(self.output_axis_origin).max(visible_start);
        let end = patch_end.min(self.output_axis_end).min(visible_end);
        if start >= end {
            return;
        }

        let count = (end - start) as usize;
        let frame_first = (start - current_origin) as usize;
        let output_first = (start - self.output_axis_origin) as usize;
        if vertical {
            let row_bytes = self.output_width * 4;
            for line in 0..count {
                let source = ((frame_first + line) * frame.width + insets.left) * 4;
                let target = (output_first + line) * row_bytes;
                self.output_bytes[target..target + row_bytes]
                    .copy_from_slice(&frame.bytes[source..source + row_bytes]);
            }
        } else {
            let span = count * 4;
            for row in 0..self.output_height {
                let frame_row = insets.top + row;
                let source = (frame_row * frame.width + frame_first) * 4;
                let target = (row * self.output_width + output_first) * 4;
                self.output_bytes[target..target + span]
                    .copy_from_slice(&frame.bytes[source..source + span]);
            }
        }
    }

    pub fn render(&self) -> Result<Vec<u8>, StitchError> {
        if self.output_width == 0 || self.output_height == 0 || self.output_bytes.is_empty() {
            return Err(StitchError::NoFrames);
        }
        Ok(self.output_bytes.clone())
    }

    pub fn render_preview(
        &self,
        maximum_pixel_width: usize,
        maximum_pixel_height: usize,
    ) -> Result<(Vec<u8>, u32, u32), StitchError> {
        if self.output_width == 0 || self.output_height == 0 || self.output_bytes.is_empty() {
            return Err(StitchError::NoFrames);
        }
        if maximum_pixel_width == 0 || maximum_pixel_height == 0 {
            return Err(StitchError::InvalidConfiguration);
        }
        let scale = 1.0_f64
            .min(maximum_pixel_width as f64 / self.output_width as f64)
            .min(maximum_pixel_height as f64 / self.output_height as f64);
        let preview_width = ((self.output_width as f64 * scale).round() as usize).max(1);
        let preview_height = ((self.output_height as f64 * scale).round() as usize).max(1);
        let mut preview_bytes = vec![0u8; preview_width * preview_height * 4];
        for target_y in 0..preview_height {
            let source_y =
                ((target_y * self.output_height) / preview_height).min(self.output_height - 1);
            for target_x in 0..preview_width {
                let source_x =
                    ((target_x * self.output_width) / preview_width).min(self.output_width - 1);
                let source_index = (source_y * self.output_width + source_x) * 4;
                let target_index = (target_y * preview_width + target_x) * 4;
                preview_bytes[target_index..target_index + 4]
                    .copy_from_slice(&self.output_bytes[source_index..source_index + 4]);
            }
        }
        Ok((preview_bytes, preview_width as u32, preview_height as u32))
    }

    fn result(
        &self,
        disposition: Disposition,
        width_limit_reached: bool,
        height_limit_reached: bool,
    ) -> AppendResult {
        let limit = if width_limit_reached {
            Some(Limit::OutputWidth)
        } else if height_limit_reached {
            Some(Limit::OutputHeight)
        } else if self.frame_count >= self.configuration.maximum_frame_count
            && disposition != Disposition::Unchanged
        {
            Some(Limit::FrameCount)
        } else {
            None
        };
        AppendResult {
            disposition,
            frame_count: self.frame_count,
            total_width: self.output_width as u32,
            total_height: self.output_height as u32,
            limit_reached: limit,
        }
    }

    fn validate_configuration(&self) -> Result<(), StitchError> {
        let configuration = &self.configuration;
        if configuration.capture_interval > 0.0
            && configuration.maximum_frame_count > 0
            && configuration.maximum_output_width > 0
            && configuration.maximum_output_height > 0
            && configuration.maximum_pixel_count > 0
            && configuration.maximum_working_bytes > 0
            && configuration.minimum_overlap_rows > 0
            && configuration.maximum_scroll_fraction > 0.0
            && configuration.maximum_scroll_fraction < 1.0
            && configuration.match_threshold >= 0.0
            && configuration.match_threshold < 1.0
        {
            Ok(())
        } else {
            Err(StitchError::InvalidConfiguration)
        }
    }

    fn validate_pixel_count(&self, width: usize, height: usize) -> Result<(), StitchError> {
        match width.checked_mul(height) {
            Some(pixel_count) if pixel_count <= self.configuration.maximum_pixel_count => Ok(()),
            _ => Err(StitchError::PixelLimitExceeded),
        }
    }

    fn validate_working_memory(
        &self,
        output_byte_count: usize,
        frame_byte_count: usize,
    ) -> Result<(), StitchError> {
        let estimated = frame_byte_count
            .checked_mul(2)
            .and_then(|two_frames| output_byte_count.checked_add(two_frames));
        match estimated {
            Some(bytes) if bytes <= self.configuration.maximum_working_bytes => Ok(()),
            _ => Err(StitchError::WorkingMemoryLimitExceeded),
        }
    }

    fn append_rows(&mut self, frame: &PixelFrame, first_row: usize, count: usize) {
        let insets = self.effective_crop_insets(frame);
        for row in first_row..first_row + count {
            let start = (row * frame.width + insets.left) * 4;
            self.output_bytes
                .extend_from_slice(&frame.bytes[start..start + self.output_width * 4]);
        }
    }

    fn prepend_rows(&mut self, frame: &PixelFrame, first_row: usize, count: usize) {
        let insets = self.effective_crop_insets(frame);
        let mut prefix = Vec::with_capacity(count * self.output_width * 4);
        for row in first_row..first_row + count {
            let start = (row * frame.width + insets.left) * 4;
            prefix.extend_from_slice(&frame.bytes[start..start + self.output_width * 4]);
        }
        self.output_bytes.splice(0..0, prefix);
    }

    fn append_columns(&mut self, frame: &PixelFrame, first_column: usize, count: usize) {
        let insets = self.effective_crop_insets(frame);
        let old_width = self.output_width;
        let mut combined = Vec::with_capacity((old_width + count) * self.output_height * 4);
        for row in 0..self.output_height {
            let frame_row = insets.top + row;
            let existing_start = row * old_width * 4;
            combined.extend_from_slice(
                &self.output_bytes[existing_start..existing_start + old_width * 4],
            );
            let new_start = (frame_row * frame.width + first_column) * 4;
            combined.extend_from_slice(&frame.bytes[new_start..new_start + count * 4]);
        }
        self.output_bytes = combined;
    }

    fn prepend_columns(&mut self, frame: &PixelFrame, first_column: usize, count: usize) {
        let insets = self.effective_crop_insets(frame);
        let old_width = self.output_width;
        let mut combined = Vec::with_capacity((old_width + count) * self.output_height * 4);
        for row in 0..self.output_height {
            let frame_row = insets.top + row;
            let new_start = (frame_row * frame.width + first_column) * 4;
            combined.extend_from_slice(&frame.bytes[new_start..new_start + count * 4]);
            let existing_start = row * old_width * 4;
            combined.extend_from_slice(
                &self.output_bytes[existing_start..existing_start + old_width * 4],
            );
        }
        self.output_bytes = combined;
    }
}

fn normalized_frame(
    bytes: Vec<u8>,
    width: usize,
    height: usize,
) -> Result<PixelFrame, StitchError> {
    if width == 0 || height == 0 {
        return Err(StitchError::InvalidFrame);
    }
    let byte_count = width
        .checked_mul(height)
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or(StitchError::InvalidFrame)?;
    if byte_count == 0 || bytes.len() < byte_count {
        return Err(StitchError::InvalidFrame);
    }
    let mut bytes = bytes;
    bytes.truncate(byte_count);
    Ok(PixelFrame {
        width,
        height,
        bytes,
    })
}


fn cropped_subframe(
    frame: &PixelFrame,
    left: usize,
    top: usize,
    width: usize,
    height: usize,
) -> Vec<u8> {
    if left == 0 && top == 0 && width == frame.width && height == frame.height {
        return frame.bytes.clone();
    }
    let mut cropped = Vec::with_capacity(width * height * 4);
    for row in top..top + height {
        let start = (row * frame.width + left) * 4;
        cropped.extend_from_slice(&frame.bytes[start..start + width * 4]);
    }
    cropped
}

/// Scrolling is continuous, so the previous offset predicts the next one and
/// candidates are visited outward from that prediction. The search always
/// examines the whole window: stopping at the first candidate that happens to
/// match would silently drop the rows between it and the true offset, and a
/// fast scroll makes that near-certain because the prediction then trails far
/// behind the real distance.
///
/// Ordering only decides ties: whichever candidate is nearest the prediction is
/// kept. With no history the prediction is zero, which reproduces the original
/// "smallest shift wins" behaviour.
fn estimated_offset(
    configuration: &Configuration,
    direction: Direction,
    previous: &PixelFrame,
    current: &PixelFrame,
    predicted_offset: i64,
    bands: StaticBands,
) -> Result<i64, StitchError> {
    // Zero is an ordinary candidate: a blinking caret, a fading scrollbar or
    // a hover effect leaves the page where it was, and that frame must be
    // classified as unchanged rather than rejected or matched one pixel off.
    // It competes on score like every other offset, so a sparse document that
    // really scrolled still wins at its true distance, where it matches
    // exactly, instead of being called unchanged merely because most of its
    // background pixels are still white.
    if previous.bytes == current.bytes {
        return Ok(0);
    }

    let axis_length = if direction == Direction::Vertical {
        previous.height
    } else {
        previous.width
    };
    let length = axis_length.saturating_sub(bands.leading + bands.trailing);
    let fraction_limit =
        (length as f64 * configuration.maximum_scroll_fraction).floor() as i64;
    let overlap_limit = length as i64 - configuration.minimum_overlap_rows as i64;
    let maximum_offset = fraction_limit.min(overlap_limit);
    if maximum_offset < 1 {
        return Err(StitchError::NoReliableVerticalOverlap);
    }

    // Every candidate is screened cheaply, then only the most promising ones
    // are scored in full. Screening the whole window is what keeps a fast
    // scroll from being matched at some nearer lookalike distance; scoring only
    // the shortlist in full is what keeps that exhaustive screen affordable at
    // the frame rate the session captures on.
    let candidates = candidate_offsets(maximum_offset, predicted_offset);
    let mut screened: Vec<(i64, f64)> = candidates
        .iter()
        .map(|offset| {
            (
                *offset,
                mismatch_score(
                    direction,
                    previous,
                    current,
                    *offset,
                    SCREENING_SAMPLES,
                    bands,
                ),
            )
        })
        .collect();
    // `candidates` is already ordered by distance from the prediction, and a
    // stable sort keeps that as the tie-break among equal scores.
    screened.sort_by(|left, right| left.1.partial_cmp(&right.1).expect("scores are never NaN"));

    let mut shortlist: Vec<i64> = screened
        .iter()
        .take(SHORTLIST_LENGTH)
        .map(|(offset, _)| *offset)
        .collect();

    // When actively scrolling in one direction (predicted_offset != 0), guarantee a minority
    // of top candidates in the opposite direction so reversing scroll direction is immediately detected
    if predicted_offset != 0 {
        let reverse_positive = predicted_offset < 0;
        let mut added = 0;
        for (offset, _) in screened.iter().filter(|(o, _)| (*o > 0) == reverse_positive) {
            if !shortlist.contains(offset) {
                shortlist.push(*offset);
                added += 1;
                if added >= 8 {
                    break;
                }
            }
        }
    }

    // Always include zero so stationary frames are scored at full fidelity,
    // placed at the front so equal scores naturally break ties in favor of stationary
    if let Some(pos) = shortlist.iter().position(|&x| x == 0) {
        shortlist.remove(pos);
    }
    shortlist.insert(0, 0);

    // The shortlist can be filled entirely by the winner's own basin, which
    // would leave the ambiguity check with nothing to compare against, so the
    // best alignment outside that basin is always scored too.
    let leader = screened[0].0;
    if let Some((rival, _)) = screened
        .iter()
        .find(|(offset, _)| (offset - leader).abs() > AMBIGUITY_GUARD)
    {
        if !shortlist.contains(rival) {
            shortlist.push(*rival);
        }
    }

    let mut scores: Vec<(i64, f64)> = Vec::with_capacity(shortlist.len());
    let mut best: Option<(i64, f64)> = None;
    for offset in shortlist {
        let score = mismatch_score(direction, previous, current, offset, FULL_SAMPLES, bands);
        let is_better = match best {
            Some((best_off, best_score)) => {
                if predicted_offset != 0 && offset == 0 && best_off != 0 && best_score <= configuration.match_threshold {
                    score < 0.000_1
                } else if predicted_offset != 0 && best_off == 0 && offset != 0 && score <= configuration.match_threshold {
                    true
                } else {
                    score < best_score - 0.000_001
                }
            }
            None => true,
        };
        if is_better {
            best = Some((offset, score));
        }
        scores.push((offset, score));
    }

    let Some((best_offset, best_score)) = best else {
        return Err(StitchError::NoReliableVerticalOverlap);
    };
    let threshold = configuration.match_threshold;
    if best_score > threshold {
        return Err(StitchError::NoReliableVerticalOverlap);
    }

    // A single low score is not proof of alignment. Repetitive content — list
    // rows, ruled backgrounds, text of even weight — scores almost as well at
    // the wrong distance, and accepting one of those splices the frame where it
    // does not belong, which is what surfaces as duplicated content after a
    // fast scroll. Require the winner to stand clear of every rival outside its
    // own basin; when nothing separates them, skip the frame instead of
    // guessing.
    //
    // An exact match is exempt: rivals that also match exactly mean the content
    // truly repeats, so every candidate splices seamlessly and the one nearest
    // the prediction is as good as any.
    //
    // A stationary frame (best_offset == 0) is also exempt: the user did not
    // scroll, and a hover effect, selection highlight, or blinking caret must
    // remain classified as unchanged rather than rejected because neighboring
    // rows look similar.
    if best_score > 0.0 && best_offset != 0 {
        let rival = scores
            .iter()
            .filter(|(offset, _)| {
                *offset != 0
                    && (*offset > 0) == (best_offset > 0)
                    && (offset - best_offset).abs() > AMBIGUITY_GUARD
            })
            .map(|(_, score)| *score)
            .fold(f64::INFINITY, f64::min);
        if rival.is_finite() && rival < best_score * AMBIGUITY_RATIO {
            return Err(StitchError::NoReliableVerticalOverlap);
        }
    }
    Ok(best_offset)
}

/// Offsets this close to the winner belong to the same match, not to a rival
/// alignment, so they never count as competition.
const AMBIGUITY_GUARD: i64 = 6;
/// How much worse the nearest rival alignment must be before the winner counts
/// as unambiguous.
const AMBIGUITY_RATIO: f64 = 1.6;
/// Samples per axis when screening the whole search window.
const SCREENING_SAMPLES: usize = 24;
/// Samples per axis when scoring a shortlisted candidate.
const FULL_SAMPLES: usize = 96;
/// How many screened candidates are rescored at full density.
const SHORTLIST_LENGTH: usize = 32;

/// Every offset within the window, zero included, nearest to the prediction
/// first. Equal distances put the larger offset first so a zero prediction
/// reproduces the original `[+d, -d]` visiting order.
fn candidate_offsets(maximum_offset: i64, predicted_offset: i64) -> Vec<i64> {
    let prediction = predicted_offset.clamp(-maximum_offset, maximum_offset);
    let mut offsets: Vec<i64> = (-maximum_offset..=maximum_offset).collect();
    offsets.sort_by_key(|offset| ((offset - prediction).abs(), -*offset));
    offsets
}

/// Vertical scrolling compares the whole overlap; horizontal scrolling scores
/// each column slice and takes a trimmed mean so a sticky sidebar cannot drag
/// the whole result.
fn mismatch_score(
    direction: Direction,
    previous: &PixelFrame,
    current: &PixelFrame,
    offset: i64,
    samples_per_axis: usize,
    bands: StaticBands,
) -> f64 {
    if direction == Direction::Vertical {
        return global_mismatch_score(
            direction,
            previous,
            current,
            offset,
            samples_per_axis,
            bands,
        );
    }
    let Some(sampling) = Sampling::new(direction, previous, offset, samples_per_axis, bands) else {
        return 1.0;
    };
    let mut slice_scores = Vec::new();
    let mut column = sampling.column_start;
    let maximum_column = sampling.column_start + sampling.sampled_width;
    while column < maximum_column {
        let mut difference = 0u64;
        let mut channel_count = 0u64;
        let previous_column = column + offset.max(0) as usize;
        let current_column = column + (-offset).max(0) as usize;
        let mut row = sampling.row_start;
        let maximum_row = sampling.row_start + sampling.sampled_height;
        while row < maximum_row {
            let previous_index = (row * previous.width + previous_column) * 4;
            let current_index = (row * current.width + current_column) * 4;
            difference += rgb_difference(
                &previous.bytes,
                previous_index,
                &current.bytes,
                current_index,
            );
            channel_count += 3;
            row += sampling.row_stride;
        }
        slice_scores.push(difference as f64 / (channel_count.max(1) * 255) as f64);
        column += sampling.column_stride;
    }
    robust_mean(&mut slice_scores)
}

fn global_mismatch_score(
    direction: Direction,
    previous: &PixelFrame,
    current: &PixelFrame,
    offset: i64,
    samples_per_axis: usize,
    bands: StaticBands,
) -> f64 {
    let Some(sampling) = Sampling::new(direction, previous, offset, samples_per_axis, bands) else {
        return 1.0;
    };
    let mut difference = 0u64;
    let mut channel_count = 0u64;
    let mut row = sampling.row_start;
    let maximum_row = sampling.row_start + sampling.sampled_height;
    while row < maximum_row {
        let previous_row = row
            + if direction == Direction::Vertical {
                offset.max(0) as usize
            } else {
                0
            };
        let current_row = row
            + if direction == Direction::Vertical {
                (-offset).max(0) as usize
            } else {
                0
            };
        let mut column = sampling.column_start;
        let maximum_column = sampling.column_start + sampling.sampled_width;
        while column < maximum_column {
            let previous_column = column
                + if direction == Direction::Horizontal {
                    offset.max(0) as usize
                } else {
                    0
                };
            let current_column = column
                + if direction == Direction::Horizontal {
                    (-offset).max(0) as usize
                } else {
                    0
                };
            let previous_index = (previous_row * previous.width + previous_column) * 4;
            let current_index = (current_row * current.width + current_column) * 4;
            difference += rgb_difference(
                &previous.bytes,
                previous_index,
                &current.bytes,
                current_index,
            );
            channel_count += 3;
            column += sampling.column_stride;
        }
        row += sampling.row_stride;
    }
    if channel_count == 0 {
        return 1.0;
    }
    difference as f64 / (channel_count * 255) as f64
}

struct Sampling {
    row_start: usize,
    column_start: usize,
    sampled_width: usize,
    sampled_height: usize,
    column_stride: usize,
    row_stride: usize,
}

impl Sampling {
    fn new(
        direction: Direction,
        previous: &PixelFrame,
        offset: i64,
        samples_per_axis: usize,
        bands: StaticBands,
    ) -> Option<Self> {
        let distance = offset.unsigned_abs() as usize;
        let vertical = direction == Direction::Vertical;
        let (axis_length, cross_length) = if vertical {
            (previous.height, previous.width)
        } else {
            (previous.width, previous.height)
        };
        let content_length = axis_length.checked_sub(bands.leading + bands.trailing)?;
        let content_cross = cross_length.checked_sub(bands.cross_leading + bands.cross_trailing)?;
        let overlap_length = content_length.checked_sub(distance)?;
        if overlap_length == 0 || content_cross == 0 {
            return None;
        }
        let axis_inset = if content_length >= 20 {
            content_length / 20
        } else {
            0
        };
        let cross_inset = if content_cross >= 20 {
            content_cross / 20
        } else {
            0
        };
        let sampled_axis = overlap_length.saturating_sub(axis_inset * 2).max(1);
        let sampled_cross = content_cross.saturating_sub(cross_inset * 2).max(1);
        let axis_start = bands.leading + axis_inset;
        let cross_start = bands.cross_leading + cross_inset;
        let (row_start, column_start, sampled_height, sampled_width) = if vertical {
            (axis_start, cross_start, sampled_axis, sampled_cross)
        } else {
            (cross_start, axis_start, sampled_cross, sampled_axis)
        };
        Some(Self {
            row_start,
            column_start,
            sampled_width,
            sampled_height,
            column_stride: (sampled_width / samples_per_axis.max(1)).max(1),
            row_stride: (sampled_height / samples_per_axis.max(1)).max(1),
        })
    }
}

/// Lines at each edge of the frame whose pixels did not move between two
/// captures. Only a band with some texture counts: a uniform margin matches
/// itself at any scroll distance and says nothing about chrome. Given the
/// scroll distance, a line that also matches the page shifted by that
/// distance is repeating content rather than chrome and is left alone. Bands
/// across the scroll axis are left out of the output, so they are capped at a
/// quarter of the frame to bound what a coincidental match can cost; bands
/// along it only narrow the scoring area and need no cap.
fn detect_static_bands(
    previous: &PixelFrame,
    current: &PixelFrame,
    direction: Direction,
    shift: Option<i64>,
) -> StaticBands {
    let vertical = direction == Direction::Vertical;
    let scan = |rows: bool, from_end: bool| {
        let length = if rows {
            previous.height
        } else {
            previous.width
        };
        let across_axis = rows == vertical;
        let cap = if across_axis {
            length / 4
        } else {
            length
        };
        let index_at = |count: usize| if from_end { length - 1 - count } else { count };
        let is_static = |index: usize| {
            line_pixels(previous, rows, index).eq(line_pixels(current, rows, index))
                && shift.is_none_or(|shift| {
                    !line_moved_with_page(previous, current, rows, across_axis, index, shift)
                        .unwrap_or(true)
                })
        };
        let mut count = 0;
        while count < cap && is_static(index_at(count)) {
            count += 1;
        }
        let textured = (0..count).any(|line| {
            let mut pixels = line_pixels(current, rows, index_at(line));
            let first = pixels.next().map(|pixel| &pixel[..3]);
            pixels.any(|pixel| Some(&pixel[..3]) != first)
        });
        if textured { count } else { 0 }
    };
    StaticBands {
        leading: scan(vertical, false),
        trailing: scan(vertical, true),
        cross_leading: scan(!vertical, false),
        cross_trailing: scan(!vertical, true),
    }
}

/// Whether the line at `index` reads as page content that travelled `shift`
/// pixels along the scroll axis between the two frames. `None` when the
/// shifted position falls outside both frames.
fn line_moved_with_page(
    previous: &PixelFrame,
    current: &PixelFrame,
    rows: bool,
    across_axis: bool,
    index: usize,
    shift: i64,
) -> Option<bool> {
    if across_axis {
        let length = if rows {
            previous.height
        } else {
            previous.width
        } as i64;
        let forward = index as i64 + shift;
        if (0..length).contains(&forward) {
            return Some(line_pixels(current, rows, index).eq(line_pixels(
                previous,
                rows,
                forward as usize,
            )));
        }
        let backward = index as i64 - shift;
        if (0..length).contains(&backward) {
            return Some(line_pixels(previous, rows, index).eq(line_pixels(
                current,
                rows,
                backward as usize,
            )));
        }
        return None;
    }
    let distance = shift.unsigned_abs() as usize;
    let current_line = line_pixels(current, rows, index);
    let previous_line = line_pixels(previous, rows, index);
    Some(if shift >= 0 {
        current_line.eq(previous_line.skip(distance))
    } else {
        current_line.skip(distance).eq(previous_line)
    })
}

/// The RGBA pixels of one row or one column.
fn line_pixels(frame: &PixelFrame, rows: bool, index: usize) -> impl Iterator<Item = &[u8]> {
    let (start, stride, count) = if rows {
        (index * frame.width * 4, 4, frame.width)
    } else {
        (index * 4, frame.width * 4, frame.height)
    };
    (0..count).map(move |pixel| &frame.bytes[start + pixel * stride..start + pixel * stride + 4])
}

fn rgb_difference(
    previous: &[u8],
    previous_index: usize,
    current: &[u8],
    current_index: usize,
) -> u64 {
    let red = previous[previous_index].abs_diff(current[current_index]) as u64;
    let green = previous[previous_index + 1].abs_diff(current[current_index + 1]) as u64;
    let blue = previous[previous_index + 2].abs_diff(current[current_index + 2]) as u64;
    red + green + blue
}

fn robust_mean(scores: &mut [f64]) -> f64 {
    if scores.is_empty() {
        return 1.0;
    }
    scores.sort_by(|left, right| left.partial_cmp(right).expect("scores are never NaN"));
    let retained_count = ((scores.len() as f64 * 0.65).ceil() as usize).max(1);
    scores.iter().take(retained_count).sum::<f64>() / retained_count as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid_frame(width: usize, height: usize, value: u8) -> Vec<u8> {
        vec![value; width * height * 4]
    }

    /// Rows carry a deterministic gradient so a vertical shift is detectable.
    fn gradient_frame(width: usize, height: usize, first_row_value: usize) -> Vec<u8> {
        let mut bytes = vec![0u8; width * height * 4];
        for row in 0..height {
            let value = ((first_row_value + row) % 251) as u8;
            for column in 0..width {
                let index = (row * width + column) * 4;
                bytes[index] = value;
                bytes[index + 1] = value.wrapping_mul(3);
                bytes[index + 2] = value.wrapping_add(17);
                bytes[index + 3] = 255;
            }
        }
        bytes
    }

    fn new_stitcher() -> Stitcher {
        Stitcher::new(Configuration::default(), Direction::Vertical)
    }

    /// Mostly-white editor/document content. Ink occupies less than the normal
    /// overlap error threshold, so a scrolled frame must not be classified as
    /// unchanged merely because most background pixels are still white.
    fn sparse_document_frame(width: usize, height: usize, first_document_row: usize) -> Vec<u8> {
        let mut bytes = vec![255u8; width * height * 4];
        for row in 0..height {
            let document_row = first_document_row + row;
            if document_row % 43 >= 2 {
                continue;
            }

            let line = document_row / 43;
            let start = (line * 17) % (width / 3);
            let end = (start + width / 3).min(width);
            for column in start..end {
                let index = (row * width + column) * 4;
                bytes[index] = (line.wrapping_mul(31) % 180) as u8;
                bytes[index + 1] = (line.wrapping_mul(47) % 180) as u8;
                bytes[index + 2] = (line.wrapping_mul(61) % 180) as u8;
            }
        }
        bytes
    }

    #[test]
    fn the_first_frame_seeds_the_output() {
        let mut stitcher = new_stitcher();
        let result = stitcher
            .append(gradient_frame(40, 200, 0), 40, 200)
            .unwrap();

        assert_eq!(result.disposition, Disposition::Initial);
        assert_eq!(result.frame_count, 1);
        assert_eq!(result.total_width, 40);
        assert_eq!(result.total_height, 200);
    }

    #[test]
    fn an_identical_frame_changes_nothing() {
        let mut stitcher = new_stitcher();
        stitcher
            .append(gradient_frame(40, 200, 0), 40, 200)
            .unwrap();
        let result = stitcher
            .append(gradient_frame(40, 200, 0), 40, 200)
            .unwrap();

        assert_eq!(result.disposition, Disposition::Unchanged);
        assert_eq!(result.total_height, 200);
    }

    #[test]
    fn scrolling_down_extends_the_output_by_the_scrolled_amount() {
        let mut stitcher = new_stitcher();
        stitcher
            .append(gradient_frame(40, 200, 0), 40, 200)
            .unwrap();
        let result = stitcher
            .append(gradient_frame(40, 200, 30), 40, 200)
            .unwrap();

        assert_eq!(
            result.disposition,
            Disposition::Appended {
                direction: Direction::Vertical,
                offset: 30
            }
        );
        assert_eq!(result.total_height, 230);
        assert_eq!(result.frame_count, 2);
    }

    #[test]
    fn sparse_document_scroll_is_not_mistaken_for_an_unchanged_frame() {
        let width = 300;
        let height = 300;
        let mut stitcher = new_stitcher();
        stitcher
            .append(
                sparse_document_frame(width, height, 0),
                width as u32,
                height as u32,
            )
            .unwrap();

        let result = stitcher
            .append(
                sparse_document_frame(width, height, 20),
                width as u32,
                height as u32,
            )
            .unwrap();

        assert_eq!(
            result.disposition,
            Disposition::Appended {
                direction: Direction::Vertical,
                offset: 20,
            }
        );
        assert_eq!(result.total_height, 320);
    }

    #[test]
    fn scrolling_up_prepends_rows() {
        let mut stitcher = new_stitcher();
        stitcher
            .append(gradient_frame(40, 200, 30), 40, 200)
            .unwrap();
        let result = stitcher
            .append(gradient_frame(40, 200, 0), 40, 200)
            .unwrap();

        assert_eq!(
            result.disposition,
            Disposition::Appended {
                direction: Direction::Vertical,
                offset: -30
            }
        );
        assert_eq!(result.total_height, 230);
    }

    #[test]
    fn changing_frame_dimensions_is_rejected() {
        let mut stitcher = new_stitcher();
        stitcher
            .append(gradient_frame(40, 200, 0), 40, 200)
            .unwrap();

        assert_eq!(
            stitcher.append(gradient_frame(40, 180, 0), 40, 180),
            Err(StitchError::FrameDimensionsChanged)
        );
    }

    #[test]
    fn a_frame_without_reliable_overlap_is_rejected() {
        let mut stitcher = new_stitcher();
        stitcher.append(solid_frame(40, 200, 10), 40, 200).unwrap();

        assert_eq!(
            stitcher.append(solid_frame(40, 200, 200), 40, 200),
            Err(StitchError::NoReliableVerticalOverlap)
        );
    }

    #[test]
    fn short_byte_buffers_are_rejected() {
        let mut stitcher = new_stitcher();

        assert_eq!(
            stitcher.append(vec![0u8; 10], 40, 200),
            Err(StitchError::InvalidFrame)
        );
        assert_eq!(
            stitcher.append(vec![], 0, 200),
            Err(StitchError::InvalidFrame)
        );
    }

    #[test]
    fn the_pixel_limit_is_enforced() {
        let configuration = Configuration {
            maximum_pixel_count: 100,
            ..Configuration::default()
        };
        let mut stitcher = Stitcher::new(configuration, Direction::Vertical);

        assert_eq!(
            stitcher.append(gradient_frame(40, 200, 0), 40, 200),
            Err(StitchError::PixelLimitExceeded)
        );
    }

    #[test]
    fn the_working_memory_limit_is_enforced() {
        let configuration = Configuration {
            maximum_working_bytes: 1_000,
            ..Configuration::default()
        };
        let mut stitcher = Stitcher::new(configuration, Direction::Vertical);

        assert_eq!(
            stitcher.append(gradient_frame(40, 200, 0), 40, 200),
            Err(StitchError::WorkingMemoryLimitExceeded)
        );
    }

    #[test]
    fn an_invalid_configuration_is_rejected_before_any_work() {
        let configuration = Configuration {
            maximum_scroll_fraction: 1.5,
            ..Configuration::default()
        };
        let mut stitcher = Stitcher::new(configuration, Direction::Vertical);

        assert_eq!(
            stitcher.append(gradient_frame(40, 200, 0), 40, 200),
            Err(StitchError::InvalidConfiguration)
        );
    }

    #[test]
    fn the_output_height_is_capped_and_reported() {
        let configuration = Configuration {
            maximum_output_height: 210,
            ..Configuration::default()
        };
        let mut stitcher = Stitcher::new(configuration, Direction::Vertical);
        stitcher
            .append(gradient_frame(40, 200, 0), 40, 200)
            .unwrap();
        let result = stitcher
            .append(gradient_frame(40, 200, 30), 40, 200)
            .unwrap();

        assert_eq!(result.total_height, 210);
        assert_eq!(result.limit_reached, Some(Limit::OutputHeight));
    }

    #[test]
    fn direction_can_only_change_before_the_output_grows() {
        let mut stitcher = new_stitcher();
        assert!(stitcher.set_direction(Direction::Horizontal));

        let mut stitcher = new_stitcher();
        stitcher
            .append(gradient_frame(40, 200, 0), 40, 200)
            .unwrap();
        stitcher
            .append(gradient_frame(40, 200, 30), 40, 200)
            .unwrap();

        assert!(!stitcher.set_direction(Direction::Horizontal));
    }

    #[test]
    fn rendering_without_frames_fails() {
        assert_eq!(new_stitcher().render(), Err(StitchError::NoFrames));
        assert_eq!(
            new_stitcher().render_preview(220, 1_600),
            Err(StitchError::NoFrames)
        );
    }

    #[test]
    fn rendering_returns_the_full_output_buffer() {
        let mut stitcher = new_stitcher();
        stitcher
            .append(gradient_frame(40, 200, 0), 40, 200)
            .unwrap();
        stitcher
            .append(gradient_frame(40, 200, 30), 40, 200)
            .unwrap();
        let bytes = stitcher.render().unwrap();

        assert_eq!(bytes.len(), 40 * 230 * 4);
    }

    #[test]
    fn the_preview_is_downscaled_within_the_requested_bounds() {
        let mut stitcher = new_stitcher();
        stitcher
            .append(gradient_frame(400, 2_000, 0), 400, 2_000)
            .unwrap();
        let (bytes, width, height) = stitcher.render_preview(220, 1_600).unwrap();

        assert!(width <= 220);
        assert!(height <= 1_600);
        assert_eq!(bytes.len(), width as usize * height as usize * 4);
    }

    #[test]
    fn stitched_rows_preserve_the_source_pixels() {
        let mut stitcher = new_stitcher();
        stitcher.append(gradient_frame(4, 200, 0), 4, 200).unwrap();
        stitcher.append(gradient_frame(4, 200, 30), 4, 200).unwrap();
        let bytes = stitcher.render().unwrap();
        let last_row_start = (229 * 4) * 4;

        assert_eq!(bytes[last_row_start], 229);
    }
}

#[cfg(test)]
mod placement_tests {
    use super::*;

    fn gradient(width: usize, height: usize, first_row_value: usize) -> Vec<u8> {
        let mut bytes = vec![0u8; width * height * 4];
        for row in 0..height {
            let value = ((first_row_value + row) % 251) as u8;
            for column in 0..width {
                let index = (row * width + column) * 4;
                bytes[index] = value;
                bytes[index + 1] = value.wrapping_mul(3);
                bytes[index + 2] = value.wrapping_add(17);
                bytes[index + 3] = 255;
            }
        }
        bytes
    }

    fn row_value(bytes: &[u8], width: usize, row: usize) -> u8 {
        bytes[row * width * 4]
    }

    #[test]
    fn scrolling_up_places_new_rows_above_the_existing_output() {
        let width = 4;
        let height = 200;
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        // First frame shows rows 30..229, then the user scrolls up to rows 0..199.
        stitcher
            .append(gradient(width, height, 30), width as u32, height as u32)
            .unwrap();
        let result = stitcher
            .append(gradient(width, height, 0), width as u32, height as u32)
            .unwrap();
        let bytes = stitcher.render().unwrap();

        assert_eq!(result.total_height, 230);
        assert_eq!(
            row_value(&bytes, width, 0),
            0,
            "top row must be the newly revealed content"
        );
        assert_eq!(row_value(&bytes, width, 29), 29);
        assert_eq!(
            row_value(&bytes, width, 30),
            30,
            "original content must start after the prepended rows"
        );
        assert_eq!(
            row_value(&bytes, width, 229),
            229,
            "bottom row must stay the original bottom"
        );
    }

    #[test]
    fn scrolling_down_places_new_rows_below_the_existing_output() {
        let width = 4;
        let height = 200;
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        stitcher
            .append(gradient(width, height, 0), width as u32, height as u32)
            .unwrap();
        stitcher
            .append(gradient(width, height, 30), width as u32, height as u32)
            .unwrap();
        let bytes = stitcher.render().unwrap();

        assert_eq!(row_value(&bytes, width, 0), 0);
        assert_eq!(row_value(&bytes, width, 229), 229);
    }

    /// Deterministic pseudo-random rows so no shifted window can match by chance.
    fn noise(width: usize, height: usize, first_row: usize) -> Vec<u8> {
        let mut bytes = vec![0u8; width * height * 4];
        for row in 0..height {
            let seed = (first_row + row) as u64;
            let hashed = seed
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            for column in 0..width {
                let index = (row * width + column) * 4;
                bytes[index] = (hashed >> 33) as u8;
                bytes[index + 1] = (hashed >> 41) as u8;
                bytes[index + 2] = (hashed >> 49) as u8;
                bytes[index + 3] = 255;
            }
        }
        bytes
    }

    #[test]
    fn a_fast_scroll_beyond_the_search_window_is_rejected() {
        let width = 4;
        let height = 200;
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        stitcher
            .append(noise(width, height, 0), width as u32, height as u32)
            .unwrap();
        // 170 rows of scroll leaves 30 rows of overlap, below minimum_overlap_rows = 32.
        let result = stitcher.append(noise(width, height, 170), width as u32, height as u32);

        assert_eq!(result, Err(StitchError::NoReliableVerticalOverlap));
    }

    /// A page whose only texture is a thin marker row every 40 pixels over a
    /// near-uniform background: many alignments look almost right, and a slight
    /// shift in background brightness keeps any of them from being exact.
    fn faint_rules(width: usize, height: usize, first_row: usize, background: u8) -> Vec<u8> {
        let mut bytes = vec![0u8; width * height * 4];
        for row in 0..height {
            let value: u8 = if (first_row + row) % 40 == 0 {
                210
            } else {
                background
            };
            for column in 0..width {
                let index = (row * width + column) * 4;
                bytes[index] = value;
                bytes[index + 1] = value;
                bytes[index + 2] = value;
                bytes[index + 3] = 255;
            }
        }
        bytes
    }

    #[test]
    fn an_alignment_with_an_equally_good_rival_is_skipped_rather_than_guessed() {
        let width = 4;
        let height = 200;
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        stitcher
            .append(
                faint_rules(width, height, 0, 255),
                width as u32,
                height as u32,
            )
            .unwrap();
        // 37 rows of scroll scores no better than 77, -3 and every other shift
        // that lands the marker rows back on each other.
        let result = stitcher.append(
            faint_rules(width, height, 37, 254),
            width as u32,
            height as u32,
        );

        assert_eq!(result, Err(StitchError::NoReliableVerticalOverlap));
    }

    #[test]
    fn a_large_scroll_is_not_matched_at_a_nearer_lookalike_offset() {
        let width = 4;
        let height = 200;
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        stitcher
            .append(noise(width, height, 0), width as u32, height as u32)
            .unwrap();
        // A short scroll teaches the search to predict +5, then the user flicks
        // the page. The true offset is far from that prediction, so a search
        // that stopped at the first plausible candidate would splice here.
        stitcher
            .append(noise(width, height, 5), width as u32, height as u32)
            .unwrap();
        let result = stitcher
            .append(noise(width, height, 130), width as u32, height as u32)
            .unwrap();

        assert_eq!(
            result.disposition,
            Disposition::Appended {
                direction: Direction::Vertical,
                offset: 125
            }
        );
    }

    /// A list-like page whose rows repeat every 10 pixels: shifting by any
    /// multiple of the period looks identical in both directions.
    fn periodic(width: usize, height: usize, first_row: usize) -> Vec<u8> {
        let mut bytes = vec![0u8; width * height * 4];
        for row in 0..height {
            let phase = (first_row + row) % 10;
            let value = (phase * 25) as u8;
            for column in 0..width {
                let index = (row * width + column) * 4;
                bytes[index] = value;
                bytes[index + 1] = value;
                bytes[index + 2] = value;
                bytes[index + 3] = 255;
            }
        }
        bytes
    }

    #[test]
    fn scrolling_up_on_periodic_content_must_not_be_read_as_scrolling_down() {
        let width = 4;
        let height = 200;
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        // Shown rows 33.., then the user scrolls up to rows 0.. (offset -33).
        stitcher
            .append(periodic(width, height, 33), width as u32, height as u32)
            .unwrap();
        let result = stitcher
            .append(periodic(width, height, 0), width as u32, height as u32)
            .unwrap();

        match result.disposition {
            Disposition::Appended { offset, .. } => assert!(
                offset < 0,
                "an upward scroll must yield a negative offset, got {offset}"
            ),
            other => panic!("expected an append, got {other:?}"),
        }
    }

    #[test]
    fn reversing_from_downward_scroll_to_upward_scroll_succeeds() {
        let width = 4;
        let height = 200;
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        stitcher
            .append(periodic(width, height, 60), width as u32, height as u32)
            .unwrap();
        stitcher
            .append(periodic(width, height, 90), width as u32, height as u32)
            .unwrap();
        // Now scroll up past the top of the session so it has to prepend rows
        let result = stitcher
            .append(periodic(width, height, 30), width as u32, height as u32);
        assert!(result.is_ok(), "result was {result:?}");
    }

    #[test]
    fn a_continued_upward_scroll_keeps_its_direction() {
        let width = 4;
        let height = 200;
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        stitcher
            .append(noise(width, height, 120), width as u32, height as u32)
            .unwrap();
        stitcher
            .append(noise(width, height, 80), width as u32, height as u32)
            .unwrap();
        let third = stitcher
            .append(noise(width, height, 40), width as u32, height as u32)
            .unwrap();

        assert_eq!(
            third.disposition,
            Disposition::Appended {
                direction: Direction::Vertical,
                offset: -40
            }
        );
        assert_eq!(third.total_height, 280);
    }

    #[test]
    fn the_prediction_never_blocks_a_reversal() {
        let width = 4;
        let height = 200;
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        stitcher
            .append(noise(width, height, 100), width as u32, height as u32)
            .unwrap();
        stitcher
            .append(noise(width, height, 150), width as u32, height as u32)
            .unwrap();
        // Now scroll back up past the starting point, so 40 rows are genuinely new.
        let reversed = stitcher
            .append(noise(width, height, 60), width as u32, height as u32)
            .unwrap();

        assert_eq!(
            reversed.disposition,
            Disposition::Appended {
                direction: Direction::Vertical,
                offset: -90
            }
        );
        assert_eq!(reversed.total_height, 290);
    }

    #[test]
    fn scrolling_back_over_captured_content_adds_nothing() {
        let width = 4;
        let height = 200;
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        stitcher
            .append(noise(width, height, 0), width as u32, height as u32)
            .unwrap();
        stitcher
            .append(noise(width, height, 50), width as u32, height as u32)
            .unwrap();
        let revisited = stitcher
            .append(noise(width, height, 20), width as u32, height as u32)
            .unwrap();

        assert_eq!(revisited.disposition, Disposition::Unchanged);
        assert_eq!(revisited.total_height, 250);
    }

    #[test]
    fn candidates_start_at_the_prediction_and_fan_outward() {
        assert_eq!(
            candidate_offsets(3, 0),
            vec![0, 1, -1, 2, -2, 3, -3],
            "no history must reproduce the original visiting order"
        );
        assert_eq!(candidate_offsets(3, 2)[0], 2);
        assert_eq!(candidate_offsets(3, -2)[0], -2);
        assert_eq!(
            candidate_offsets(3, 99)[0],
            3,
            "a prediction beyond the window clamps to it"
        );
    }

    /// Ruled content: strong marker rows every 10 pixels, each with its own
    /// brightness. A shift of 3 realigns the rules and therefore scores well,
    /// but only the true shift of 43 lines the brightnesses up exactly.
    fn ruled(width: usize, height: usize, first_row: usize) -> Vec<u8> {
        let mut bytes = vec![0u8; width * height * 4];
        for row in 0..height {
            let absolute = first_row + row;
            let value: u8 = if absolute % 10 == 0 {
                // Aperiodic within any capture, so only the true shift matches exactly.
                150 + ((absolute / 10) * 37 % 40) as u8
            } else {
                250
            };
            for column in 0..width {
                let index = (row * width + column) * 4;
                bytes[index] = value;
                bytes[index + 1] = value;
                bytes[index + 2] = value;
                bytes[index + 3] = 255;
            }
        }
        bytes
    }

    #[test]
    fn a_plausible_near_match_never_beats_the_exact_one() {
        let width = 4;
        let height = 200;
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        stitcher
            .append(ruled(width, height, 0), width as u32, height as u32)
            .unwrap();
        let result = stitcher
            .append(ruled(width, height, 43), width as u32, height as u32)
            .unwrap();

        assert_eq!(
            result.disposition,
            Disposition::Appended {
                direction: Direction::Vertical,
                offset: 43
            },
            "stopping at a merely plausible offset drops the rows in between"
        );
        assert_eq!(result.total_height, 243);
    }

    #[test]
    fn a_moderate_scroll_is_matched_on_noisy_content() {
        let width = 4;
        let height = 200;
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        stitcher
            .append(noise(width, height, 0), width as u32, height as u32)
            .unwrap();
        let down = stitcher
            .append(noise(width, height, 60), width as u32, height as u32)
            .unwrap();

        assert_eq!(
            down.disposition,
            Disposition::Appended {
                direction: Direction::Vertical,
                offset: 60
            }
        );

        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        stitcher
            .append(noise(width, height, 60), width as u32, height as u32)
            .unwrap();
        let up = stitcher
            .append(noise(width, height, 0), width as u32, height as u32)
            .unwrap();

        assert_eq!(
            up.disposition,
            Disposition::Appended {
                direction: Direction::Vertical,
                offset: -60
            }
        );
    }
}

#[cfg(test)]
mod resilience_tests {
    use super::*;

    const WIDTH: usize = 40;
    const HEIGHT: usize = 200;

    fn mix(mut x: u64) -> u64 {
        x ^= x >> 33;
        x = x.wrapping_mul(0xff51_afd7_ed55_8ccd);
        x ^= x >> 33;
        x = x.wrapping_mul(0xc4ce_b9fe_1a85_ec53);
        x ^ (x >> 33)
    }

    /// Pseudo-random texture that varies along both axes.
    fn page(first_row: usize) -> Vec<u8> {
        let mut bytes = vec![255u8; WIDTH * HEIGHT * 4];
        for row in 0..HEIGHT {
            for column in 0..WIDTH {
                let hashed = mix((((first_row + row) as u64) << 32) | column as u64);
                let index = (row * WIDTH + column) * 4;
                bytes[index] = hashed as u8;
                bytes[index + 1] = (hashed >> 8) as u8;
                bytes[index + 2] = (hashed >> 16) as u8;
            }
        }
        bytes
    }

    fn page_row(first_row: usize) -> Vec<u8> {
        page(first_row)[..WIDTH * 4].to_vec()
    }

    fn output_row(bytes: &[u8], row: usize) -> &[u8] {
        &bytes[row * WIDTH * 4..(row + 1) * WIDTH * 4]
    }

    /// Chrome that stays put while the page scrolls: textured so it is not
    /// mistaken for empty margin.
    fn paint_static_band(bytes: &mut [u8], rows: std::ops::Range<usize>) {
        for row in rows {
            for column in 0..WIDTH {
                let hashed = mix(0xabcd_0000 + ((row as u64) << 16) + column as u64);
                let index = (row * WIDTH + column) * 4;
                bytes[index] = hashed as u8;
                bytes[index + 1] = (hashed >> 8) as u8;
                bytes[index + 2] = (hashed >> 16) as u8;
            }
        }
    }

    fn with_header(first_row: usize) -> Vec<u8> {
        let mut bytes = page(first_row);
        paint_static_band(&mut bytes, 0..30);
        bytes
    }

    fn with_footer(first_row: usize) -> Vec<u8> {
        let mut bytes = page(first_row);
        paint_static_band(&mut bytes, 170..200);
        bytes
    }

    fn append(stitcher: &mut Stitcher, bytes: Vec<u8>) -> Result<AppendResult, StitchError> {
        stitcher.append(bytes, WIDTH as u32, HEIGHT as u32)
    }

    fn appended(offset: i64) -> Disposition {
        Disposition::Appended {
            direction: Direction::Vertical,
            offset,
        }
    }

    #[test]
    fn a_stationary_frame_with_a_small_change_is_unchanged() {
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        let mut with_caret = page(0);
        for row in 100..124 {
            for column in 13..15 {
                let index = (row * WIDTH + column) * 4;
                with_caret[index..index + 3].fill(0);
            }
        }
        append(&mut stitcher, with_caret).unwrap();

        let result = append(&mut stitcher, page(0)).unwrap();

        assert_eq!(result.disposition, Disposition::Unchanged);
        assert_eq!(result.total_height, HEIGHT as u32);
    }

    #[test]
    fn a_change_inside_the_unsampled_margin_is_unchanged() {
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        append(&mut stitcher, page(0)).unwrap();
        let mut scrollbar = page(0);
        for row in 50..100 {
            let index = (row * WIDTH + WIDTH - 1) * 4;
            scrollbar[index..index + 3].fill(128);
        }

        let result = append(&mut stitcher, scrollbar).unwrap();

        assert_eq!(result.disposition, Disposition::Unchanged);
    }

    #[test]
    fn a_hover_highlight_in_a_repeating_list_is_classified_as_unchanged() {
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        let base = list_page(0);
        append(&mut stitcher, base.clone()).unwrap();

        // Simulate hovering a row in a list where rows repeat every 10px:
        // row 10..18 gets a light blue background
        let mut with_hover = base;
        for row in 10..18 {
            for column in 0..WIDTH {
                let index = (row * WIDTH + column) * 4;
                with_hover[index] = 204;
                with_hover[index + 1] = 232;
                with_hover[index + 2] = 255;
            }
        }

        let result = append(&mut stitcher, with_hover).unwrap();
        assert_eq!(result.disposition, Disposition::Unchanged);
        assert_eq!(stitcher.output_height(), HEIGHT as u32);
    }

    #[test]
    fn slow_upward_scroll_is_not_rejected_by_zero_offset_rival() {
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        append(&mut stitcher, page(100)).unwrap();
        // First scroll down slightly
        append(&mut stitcher, page(120)).unwrap();
        // Now scroll up past the top (to 90) - offset from frame 1 (120) is -30, offset from frame 0 is -10
        let result = append(&mut stitcher, page(90)).unwrap();
        assert_eq!(result.disposition, appended(-30));
    }

    #[test]
    fn hover_in_overlap_is_not_stamped_onto_existing_stitched_rows_when_scrolling_down() {
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        append(&mut stitcher, with_header(0)).unwrap();

        // Frame 1 scrolls down by 30px, but row 60 in the current viewport gets a hover highlight
        let mut frame1 = with_header(30);
        for column in 0..WIDTH {
            let index = (60 * WIDTH + column) * 4;
            frame1[index] = 204;
            frame1[index + 1] = 232;
            frame1[index + 2] = 255;
        }

        let result = append(&mut stitcher, frame1).unwrap();
        assert_eq!(result.disposition, appended(30));
        let bytes = stitcher.render().unwrap();
        // The existing canvas row 60 (which corresponds to page row 60) must remain clean
        assert_eq!(output_row(&bytes, 60), page_row(60));
    }

    #[test]
    fn the_pixel_limit_caps_the_output_instead_of_failing() {
        let configuration = Configuration {
            maximum_pixel_count: WIDTH * 210,
            ..Configuration::default()
        };
        let mut stitcher = Stitcher::new(configuration, Direction::Vertical);
        append(&mut stitcher, page(0)).unwrap();

        let capped = append(&mut stitcher, page(30)).unwrap();
        assert_eq!(capped.total_height, 210);
        assert_eq!(capped.limit_reached, Some(Limit::OutputHeight));

        let beyond = append(&mut stitcher, page(60)).unwrap();
        assert_eq!(beyond.total_height, 210);
        assert_eq!(beyond.limit_reached, Some(Limit::OutputHeight));
    }

    #[test]
    fn the_working_memory_limit_caps_the_output_instead_of_failing() {
        let frame_bytes = WIDTH * HEIGHT * 4;
        let configuration = Configuration {
            maximum_working_bytes: frame_bytes * 2 + WIDTH * 210 * 4,
            ..Configuration::default()
        };
        let mut stitcher = Stitcher::new(configuration, Direction::Vertical);
        append(&mut stitcher, page(0)).unwrap();

        let capped = append(&mut stitcher, page(30)).unwrap();
        assert_eq!(capped.total_height, 210);
        assert_eq!(capped.limit_reached, Some(Limit::OutputHeight));

        let beyond = append(&mut stitcher, page(60)).unwrap();
        assert_eq!(beyond.total_height, 210);
    }

    #[test]
    fn a_tall_sticky_header_no_longer_blocks_matching() {
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        append(&mut stitcher, with_header(0)).unwrap();

        let result = append(&mut stitcher, with_header(50)).unwrap();
        let bytes = stitcher.render().unwrap();

        assert_eq!(result.disposition, appended(50));
        assert_eq!(result.total_height, 250);
        assert_eq!(output_row(&bytes, 0), output_row(&with_header(0), 0));
        assert_eq!(output_row(&bytes, 35), page_row(35));
        assert_eq!(output_row(&bytes, 210), page_row(210));
    }

    #[test]
    fn a_sticky_footer_is_excluded_from_the_stitched_rows() {
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        append(&mut stitcher, with_footer(0)).unwrap();

        let result = append(&mut stitcher, with_footer(50)).unwrap();
        let bytes = stitcher.render().unwrap();

        assert_eq!(result.disposition, appended(50));
        assert_eq!(result.total_height, 220);
        assert_eq!(output_row(&bytes, 0), page_row(0));
        assert_eq!(output_row(&bytes, 185), page_row(185));
        assert_eq!(output_row(&bytes, 219), page_row(219));
    }

    #[test]
    fn a_sticky_header_is_replaced_by_content_when_scrolling_up() {
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        append(&mut stitcher, with_header(100)).unwrap();

        let result = append(&mut stitcher, with_header(50)).unwrap();
        let bytes = stitcher.render().unwrap();

        assert_eq!(result.disposition, appended(-50));
        assert_eq!(result.total_height, 220);
        assert_eq!(output_row(&bytes, 0), page_row(80));
        assert_eq!(output_row(&bytes, 20), page_row(100));
        assert_eq!(output_row(&bytes, 219), page_row(299));
    }

    /// Chrome beside the page: a sidebar that stays put while the content
    /// beside it scrolls.
    fn with_sidebar(first_row: usize) -> Vec<u8> {
        let mut bytes = page(first_row);
        for row in 0..HEIGHT {
            for column in 0..10 {
                let hashed = mix(0x5ba7_0000 + ((row as u64) << 16) + column as u64);
                let index = (row * WIDTH + column) * 4;
                bytes[index] = hashed as u8;
                bytes[index + 1] = (hashed >> 8) as u8;
                bytes[index + 2] = (hashed >> 16) as u8;
            }
        }
        bytes
    }

    #[test]
    fn a_static_sidebar_does_not_hide_a_scroll() {
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        append(&mut stitcher, with_sidebar(0)).unwrap();

        let result = append(&mut stitcher, with_sidebar(50)).unwrap();

        assert_eq!(result.disposition, appended(50));
        assert_eq!(result.total_height, 250);
    }

    /// A list whose first 80 page rows repeat every 10 rows (each row textured
    /// across its width) above unique content.
    fn list_page(first_row: usize) -> Vec<u8> {
        let mut bytes = vec![255u8; WIDTH * HEIGHT * 4];
        for row in 0..HEIGHT {
            let page_row = first_row + row;
            let key = if page_row < 80 {
                page_row % 10
            } else {
                page_row
            };
            for column in 0..WIDTH {
                let hashed = mix(((key as u64) << 32) | column as u64);
                let index = (row * WIDTH + column) * 4;
                bytes[index] = hashed as u8;
                bytes[index + 1] = (hashed >> 8) as u8;
                bytes[index + 2] = (hashed >> 16) as u8;
            }
        }
        bytes
    }

    #[test]
    fn rows_that_repeat_at_the_scroll_distance_are_not_mistaken_for_chrome() {
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        append(&mut stitcher, list_page(40)).unwrap();
        // Scrolling by a multiple of the period leaves the repeating rows
        // identical at the same index, which must not be read as a header.
        append(&mut stitcher, list_page(60)).unwrap();

        let result = append(&mut stitcher, list_page(0)).unwrap();
        let bytes = stitcher.render().unwrap();

        assert_eq!(result.disposition, appended(-60));
        assert_eq!(result.total_height, 260);
        assert_eq!(output_row(&bytes, 0), &list_page(0)[..WIDTH * 4]);
        assert_eq!(output_row(&bytes, 100), &list_page(100)[..WIDTH * 4]);
    }

    #[test]
    fn the_default_configuration_does_not_cap_a_session_by_frame_count() {
        assert!(Configuration::default().maximum_frame_count >= 10_000);
    }

    #[test]
    fn small_frames_can_scroll_large_fractions_of_their_height() {
        let h = 80;
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        let frame0 = page(0)[..WIDTH * h * 4].to_vec();
        stitcher.append(frame0, WIDTH as u32, h as u32).unwrap();
        for i in 1..=4 {
            let frame = page(i * 45)[..WIDTH * h * 4].to_vec();
            let result = stitcher.append(frame, WIDTH as u32, h as u32).unwrap();
            assert_eq!(result.disposition, appended(45));
            assert_eq!(result.total_height, 80 + (i * 45) as u32);
        }
        assert_eq!(stitcher.output_height(), 80 + 4 * 45);
    }

    #[test]
    fn tracking_with_crop_insets_splices_only_the_cropped_selection() {
        let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
        stitcher.set_crop_insets(60, 60, 0, 0);

        let initial = append(&mut stitcher, page(0)).unwrap();
        assert_eq!(initial.total_height, 80);
        assert_eq!(stitcher.output_height(), 80);

        let second = append(&mut stitcher, page(70)).unwrap();
        assert_eq!(second.disposition, appended(70));
        assert_eq!(second.total_height, 150);
        assert_eq!(stitcher.output_height(), 150);

        let bytes = stitcher.render().unwrap();
        assert_eq!(bytes.len(), WIDTH * 150 * 4);
        assert_eq!(output_row(&bytes, 0), page_row(60));
        assert_eq!(output_row(&bytes, 79), page_row(139));
        assert_eq!(output_row(&bytes, 80), page_row(140));
        assert_eq!(output_row(&bytes, 149), page_row(209));
    }
}
