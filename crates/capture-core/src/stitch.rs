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
            capture_interval: 0.18,
            maximum_frame_count: 240,
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
        self.previous_frame_axis_origin = 0;
        self.current_frame_offset = 0;
        self.predicted_offset = 0;
        true
    }

    pub fn append(
        &mut self,
        bytes: Vec<u8>,
        width: u32,
        height: u32,
    ) -> Result<AppendResult, StitchError> {
        self.validate_configuration()?;
        let frame = normalized_frame(bytes, width as usize, height as usize)?;
        if let Some(previous) = &self.previous_frame {
            if frame.width != previous.width || frame.height != previous.height {
                return Err(StitchError::FrameDimensionsChanged);
            }
        }

        self.validate_pixel_count(
            self.output_width.max(frame.width),
            self.output_height.max(frame.height),
        )?;
        self.validate_working_memory(
            self.output_bytes.len().max(frame.byte_count()),
            frame.byte_count(),
        )?;

        if self.previous_frame.is_none() {
            return self.accept_initial_frame(frame);
        }

        let previous = self.previous_frame.as_ref().expect("a previous frame");
        let offset = match estimated_offset(
            &self.configuration,
            self.direction,
            previous,
            &frame,
            self.predicted_offset,
        ) {
            Ok(offset) => offset,
            Err(error) => {
                // The rejected frame is dropped, so the next comparison spans a
                // longer interval than this one did. Keeping the prediction
                // would aim the search at a distance that is already stale and
                // bias it towards a too-small match; decay it towards zero so
                // the window is visited outward from a neutral guess instead.
                self.predicted_offset /= 2;
                return Err(error);
            }
        };
        self.previous_frame = Some(frame);
        if offset == 0 {
            return Ok(self.result(Disposition::Unchanged, false, false));
        }
        self.predicted_offset = offset;
        let frame = self.previous_frame.take().expect("the frame just stored");
        let outcome = self.extend_output(&frame, offset);
        self.previous_frame = Some(frame);
        outcome
    }

    fn accept_initial_frame(&mut self, frame: PixelFrame) -> Result<AppendResult, StitchError> {
        self.frame_count = 1;
        let accepted_width = frame.width.min(self.configuration.maximum_output_width);
        let accepted_height = frame.height.min(self.configuration.maximum_output_height);
        self.validate_pixel_count(accepted_width, accepted_height)?;
        self.output_bytes = cropped_bytes(&frame, accepted_width, accepted_height);
        self.output_width = accepted_width;
        self.output_height = accepted_height;
        self.output_axis_origin = 0;
        self.output_axis_end = if self.direction == Direction::Vertical {
            accepted_height as i64
        } else {
            accepted_width as i64
        };
        self.previous_frame_axis_origin = 0;
        self.current_frame_offset = 0;
        let width_limit_reached = accepted_width < frame.width
            || accepted_width == self.configuration.maximum_output_width;
        let height_limit_reached = accepted_height < frame.height
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
    ) -> Result<AppendResult, StitchError> {
        let frame_length = if self.direction == Direction::Vertical {
            frame.height as i64
        } else {
            frame.width as i64
        };
        let current_origin = self.previous_frame_axis_origin + signed_offset;
        let current_end = current_origin + frame_length;
        let requested_before = (self.output_axis_origin - current_origin).max(0) as usize;
        let requested_after = (current_end - self.output_axis_end).max(0) as usize;
        self.previous_frame_axis_origin = current_origin;

        if requested_before == 0 && requested_after == 0 {
            self.current_frame_offset = current_origin - self.output_axis_origin;
            return Ok(self.result(Disposition::Unchanged, false, false));
        }
        if self.frame_count >= self.configuration.maximum_frame_count {
            return Err(StitchError::FrameLimitExceeded);
        }
        self.frame_count += 1;

        match self.direction {
            Direction::Vertical => {
                let remaining = self
                    .configuration
                    .maximum_output_height
                    .saturating_sub(self.output_height);
                let rows_before = requested_before.min(remaining);
                let rows_after = requested_after.min(remaining - rows_before);
                let proposed_height = self.output_height + rows_before + rows_after;
                self.validate_pixel_count(self.output_width, proposed_height)?;
                self.validate_working_memory(
                    proposed_height
                        .checked_mul(self.output_width)
                        .and_then(|value| value.checked_mul(4))
                        .ok_or(StitchError::WorkingMemoryLimitExceeded)?,
                    frame.byte_count(),
                )?;
                if rows_before > 0 {
                    self.prepend_rows(frame, requested_before - rows_before, rows_before);
                    self.output_axis_origin -= rows_before as i64;
                }
                if rows_after > 0 {
                    self.append_rows(frame, frame.height - requested_after, rows_after);
                    self.output_axis_end += rows_after as i64;
                }
                self.output_height = proposed_height;
                self.did_extend_output =
                    self.did_extend_output || rows_before > 0 || rows_after > 0;
                self.current_frame_offset = current_origin - self.output_axis_origin;
                let height_limit_reached = rows_before < requested_before
                    || rows_after < requested_after
                    || self.output_height == self.configuration.maximum_output_height;
                Ok(self.result(
                    Disposition::Appended {
                        direction: Direction::Vertical,
                        offset: signed_offset,
                    },
                    false,
                    height_limit_reached,
                ))
            }
            Direction::Horizontal => {
                let remaining = self
                    .configuration
                    .maximum_output_width
                    .saturating_sub(self.output_width);
                let columns_before = requested_before.min(remaining);
                let columns_after = requested_after.min(remaining - columns_before);
                let proposed_width = self.output_width + columns_before + columns_after;
                self.validate_pixel_count(proposed_width, self.output_height)?;
                self.validate_working_memory(
                    proposed_width
                        .checked_mul(self.output_height)
                        .and_then(|value| value.checked_mul(4))
                        .ok_or(StitchError::WorkingMemoryLimitExceeded)?,
                    frame.byte_count(),
                )?;
                if columns_before > 0 {
                    self.prepend_columns(frame, requested_before - columns_before, columns_before);
                    self.output_axis_origin -= columns_before as i64;
                }
                if columns_after > 0 {
                    self.append_columns(frame, frame.width - requested_after, columns_after);
                    self.output_axis_end += columns_after as i64;
                }
                self.output_width = proposed_width;
                self.did_extend_output =
                    self.did_extend_output || columns_before > 0 || columns_after > 0;
                self.current_frame_offset = current_origin - self.output_axis_origin;
                let width_limit_reached = columns_before < requested_before
                    || columns_after < requested_after
                    || self.output_width == self.configuration.maximum_output_width;
                Ok(self.result(
                    Disposition::Appended {
                        direction: Direction::Horizontal,
                        offset: signed_offset,
                    },
                    width_limit_reached,
                    false,
                ))
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
        for row in first_row..first_row + count {
            let start = row * frame.width * 4;
            self.output_bytes
                .extend_from_slice(&frame.bytes[start..start + self.output_width * 4]);
        }
    }

    fn prepend_rows(&mut self, frame: &PixelFrame, first_row: usize, count: usize) {
        let mut prefix = Vec::with_capacity(count * self.output_width * 4);
        for row in first_row..first_row + count {
            let start = row * frame.width * 4;
            prefix.extend_from_slice(&frame.bytes[start..start + self.output_width * 4]);
        }
        prefix.extend_from_slice(&self.output_bytes);
        self.output_bytes = prefix;
    }

    fn append_columns(&mut self, frame: &PixelFrame, first_column: usize, count: usize) {
        let old_width = self.output_width;
        let mut combined = Vec::with_capacity((old_width + count) * self.output_height * 4);
        for row in 0..self.output_height {
            let existing_start = row * old_width * 4;
            combined.extend_from_slice(
                &self.output_bytes[existing_start..existing_start + old_width * 4],
            );
            let new_start = (row * frame.width + first_column) * 4;
            combined.extend_from_slice(&frame.bytes[new_start..new_start + count * 4]);
        }
        self.output_bytes = combined;
    }

    fn prepend_columns(&mut self, frame: &PixelFrame, first_column: usize, count: usize) {
        let old_width = self.output_width;
        let mut combined = Vec::with_capacity((old_width + count) * self.output_height * 4);
        for row in 0..self.output_height {
            let new_start = (row * frame.width + first_column) * 4;
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

fn cropped_bytes(frame: &PixelFrame, width: usize, height: usize) -> Vec<u8> {
    if width == frame.width && height == frame.height {
        return frame.bytes.clone();
    }
    let mut cropped = Vec::with_capacity(width * height * 4);
    for row in 0..height {
        let start = row * frame.width * 4;
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
) -> Result<i64, StitchError> {
    // A low whole-frame mismatch is not sufficient to mean "unchanged":
    // document and terminal captures are mostly uniform background, so even a
    // real scroll may alter less than the overlap threshold. Exact equality is
    // both cheap and unambiguous; small animations in a stationary frame will
    // simply fail overlap detection and be skipped by the platform session.
    if previous.bytes == current.bytes {
        return Ok(0);
    }

    let length = if direction == Direction::Vertical {
        previous.height
    } else {
        previous.width
    };
    let fraction_limit = (length as f64 * configuration.maximum_scroll_fraction).floor() as i64;
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
                mismatch_score(direction, previous, current, *offset, SCREENING_SAMPLES),
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
        let score = mismatch_score(direction, previous, current, offset, FULL_SAMPLES);
        let is_better = match best {
            Some((_, best_score)) => score < best_score - 0.000_001,
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
    if best_score > configuration.match_threshold {
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
    if best_score > 0.0 {
        let rival = scores
            .iter()
            .filter(|(offset, _)| (offset - best_offset).abs() > AMBIGUITY_GUARD)
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
const AMBIGUITY_GUARD: i64 = 8;
/// How much worse the nearest rival alignment must be before the winner counts
/// as unambiguous.
const AMBIGUITY_RATIO: f64 = 1.8;
/// Samples per axis when screening the whole search window.
const SCREENING_SAMPLES: usize = 24;
/// Samples per axis when scoring a shortlisted candidate.
const FULL_SAMPLES: usize = 96;
/// How many screened candidates are rescored at full density.
const SHORTLIST_LENGTH: usize = 24;

/// Every non-zero offset within the window, nearest to the prediction first.
/// Equal distances put the larger offset first so a zero prediction reproduces
/// the original `[+d, -d]` visiting order.
fn candidate_offsets(maximum_offset: i64, predicted_offset: i64) -> Vec<i64> {
    let prediction = predicted_offset.clamp(-maximum_offset, maximum_offset);
    let mut offsets: Vec<i64> = (-maximum_offset..=maximum_offset)
        .filter(|offset| *offset != 0)
        .collect();
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
) -> f64 {
    if direction == Direction::Vertical {
        return global_mismatch_score(direction, previous, current, offset, samples_per_axis);
    }
    let Some(sampling) = Sampling::new(direction, previous, offset, samples_per_axis) else {
        return 1.0;
    };
    let mut slice_scores = Vec::new();
    let mut column = sampling.horizontal_inset;
    let maximum_column = sampling.horizontal_inset + sampling.sampled_width;
    while column < maximum_column {
        let mut difference = 0u64;
        let mut channel_count = 0u64;
        let previous_column = column + offset.max(0) as usize;
        let current_column = column + (-offset).max(0) as usize;
        let mut row = sampling.vertical_inset;
        let maximum_row = sampling.vertical_inset + sampling.sampled_height;
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
) -> f64 {
    let Some(sampling) = Sampling::new(direction, previous, offset, samples_per_axis) else {
        return 1.0;
    };
    let mut difference = 0u64;
    let mut channel_count = 0u64;
    let mut row = sampling.vertical_inset;
    let maximum_row = sampling.vertical_inset + sampling.sampled_height;
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
        let mut column = sampling.horizontal_inset;
        let maximum_column = sampling.horizontal_inset + sampling.sampled_width;
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
    horizontal_inset: usize,
    vertical_inset: usize,
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
    ) -> Option<Self> {
        let distance = offset.unsigned_abs() as usize;
        let overlap_width = previous
            .width
            .checked_sub(if direction == Direction::Horizontal {
                distance
            } else {
                0
            })?;
        let overlap_height = previous
            .height
            .checked_sub(if direction == Direction::Vertical {
                distance
            } else {
                0
            })?;
        if overlap_width == 0 || overlap_height == 0 {
            return None;
        }
        let horizontal_inset = if previous.width >= 20 {
            previous.width / 20
        } else {
            0
        };
        let vertical_inset = if previous.height >= 20 {
            previous.height / 20
        } else {
            0
        };
        let sampled_width = overlap_width.saturating_sub(horizontal_inset * 2).max(1);
        let sampled_height = overlap_height.saturating_sub(vertical_inset * 2).max(1);
        Some(Self {
            horizontal_inset,
            vertical_inset,
            sampled_width,
            sampled_height,
            column_stride: (sampled_width / samples_per_axis.max(1)).max(1),
            row_stride: (sampled_height / samples_per_axis.max(1)).max(1),
        })
    }
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
            vec![1, -1, 2, -2, 3, -3],
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
