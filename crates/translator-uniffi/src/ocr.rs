use ort::session::Session;
use ort::value::TensorRef;
use std::path::Path;
use std::sync::{Arc, Mutex};

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum OfflineOcrFailure {
    #[error("invalid OCR image")]
    InvalidImage,
    #[error("{message}")]
    Backend { message: String },
}

impl OfflineOcrFailure {
    fn backend(error: impl std::fmt::Display) -> Self {
        Self::Backend {
            message: error.to_string(),
        }
    }
}

#[derive(uniffi::Record)]
pub struct OfflineOcrLine {
    pub text: String,
    pub left: f64,
    pub top: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(uniffi::Object)]
pub struct OfflineOcrEngine {
    models: Mutex<Models>,
}

#[uniffi::export]
impl OfflineOcrEngine {
    #[uniffi::constructor]
    pub fn new(
        library_path: String,
        model_directory: String,
    ) -> Result<Arc<Self>, OfflineOcrFailure> {
        ort::init_from(library_path)
            .map_err(OfflineOcrFailure::backend)?
            .with_telemetry(false)
            .commit();
        let directory = Path::new(&model_directory);
        Ok(Arc::new(Self {
            models: Mutex::new(Models {
                detector: open_session(&directory.join("detect.onnx"))?,
                general: Recognizer::open(&directory.join("recognize.onnx"))?,
                korean: Recognizer::open(&directory.join("recognize-ko.onnx"))?,
            }),
        }))
    }

    pub fn recognize(
        &self,
        rgba: Vec<u8>,
        width: u32,
        height: u32,
    ) -> Result<Vec<OfflineOcrLine>, OfflineOcrFailure> {
        let (width, height) = (width as usize, height as usize);
        if width == 0 || height == 0 || width.max(height) > 2560 || rgba.len() != width * height * 4
        {
            return Err(OfflineOcrFailure::InvalidImage);
        }
        self.models
            .lock()
            .map_err(|_| OfflineOcrFailure::backend("OCR model session unavailable"))?
            .recognize(&rgba, width, height)
    }
}

fn open_session(path: &Path) -> Result<Session, OfflineOcrFailure> {
    Session::builder()
        .map_err(OfflineOcrFailure::backend)?
        .with_intra_threads(2)
        .map_err(OfflineOcrFailure::backend)?
        .with_intra_op_spinning(false)
        .map_err(OfflineOcrFailure::backend)?
        .with_inter_op_spinning(false)
        .map_err(OfflineOcrFailure::backend)?
        .commit_from_file(path)
        .map_err(OfflineOcrFailure::backend)
}

struct Models {
    detector: Session,
    general: Recognizer,
    korean: Recognizer,
}

#[derive(Clone, Copy)]
struct Region {
    left: usize,
    top: usize,
    width: usize,
    height: usize,
}

impl Models {
    fn recognize(
        &mut self,
        rgba: &[u8],
        width: usize,
        height: usize,
    ) -> Result<Vec<OfflineOcrLine>, OfflineOcrFailure> {
        let scale = (1536.0 / width.max(height) as f64).min(1.0);
        let target_width = image_multiple(width, scale);
        let target_height = image_multiple(height, scale);
        let frame = Region {
            left: 0,
            top: 0,
            width,
            height,
        };
        let tensor = image_tensor(
            rgba,
            width,
            frame,
            target_width,
            target_height,
            [0.485, 0.456, 0.406],
            [0.229, 0.224, 0.225],
        );
        let input = TensorRef::from_array_view(([1, 3, target_height, target_width], &*tensor))
            .map_err(OfflineOcrFailure::backend)?;
        let detections = self
            .detector
            .run(ort::inputs![input])
            .map_err(OfflineOcrFailure::backend)?;
        let (shape, mask) = detections[0]
            .try_extract_tensor::<f32>()
            .map_err(OfflineOcrFailure::backend)?;
        if **shape != [1, 1, target_height as i64, target_width as i64] {
            return Err(OfflineOcrFailure::backend("unexpected OCR detector output"));
        }
        let regions = detect_regions(mask, target_width, target_height, width, height);
        drop(detections);
        if regions.len() > 256 {
            return Ok(Vec::new());
        }

        let mut lines = Vec::new();
        for region in regions {
            let line_width = (48 * region.width).div_ceil(region.height).clamp(16, 1536);
            let input = image_tensor(rgba, width, region, line_width, 48, [0.5; 3], [0.5; 3]);
            let general = self.general.read(&input, line_width)?;
            let korean = self.korean.read(&input, line_width)?;
            let selected = if korean
                .text
                .chars()
                .any(|letter| ('\u{ac00}'..='\u{d7a3}').contains(&letter))
                && korean.confidence >= general.confidence * 0.95
            {
                korean
            } else {
                general
            };
            if selected.confidence >= 0.55 && !selected.text.trim().is_empty() {
                lines.push(OfflineOcrLine {
                    text: selected.text.trim().to_owned(),
                    left: region.left as f64 / width as f64,
                    top: region.top as f64 / height as f64,
                    width: region.width as f64 / width as f64,
                    height: region.height as f64 / height as f64,
                });
            }
        }
        Ok(lines)
    }
}

fn image_multiple(side: usize, scale: f64) -> usize {
    (((side as f64 * scale / 32.0).round() as usize).max(1)) * 32
}

fn image_tensor(
    rgba: &[u8],
    image_width: usize,
    region: Region,
    target_width: usize,
    target_height: usize,
    mean: [f32; 3],
    deviation: [f32; 3],
) -> Vec<f32> {
    let plane = target_width * target_height;
    let mut values = vec![0.0; plane * 3];
    for row in 0..target_height {
        let source_row = region.top + ((2 * row + 1) * region.height / (2 * target_height));
        for column in 0..target_width {
            let source_column =
                region.left + ((2 * column + 1) * region.width / (2 * target_width));
            let pixel = (source_row * image_width + source_column) * 4;
            let offset = row * target_width + column;
            for channel in 0..3 {
                values[plane * channel + offset] = (f32::from(rgba[pixel + 2 - channel]) / 255.0
                    - mean[channel])
                    / deviation[channel];
            }
        }
    }
    values
}

fn detect_regions(
    mask: &[f32],
    mask_width: usize,
    mask_height: usize,
    width: usize,
    height: usize,
) -> Vec<Region> {
    let mut visited = vec![false; mask.len()];
    let mut stack = Vec::new();
    let mut regions = Vec::new();
    for (start, value) in mask.iter().enumerate() {
        if *value <= 0.3 || visited[start] {
            continue;
        }
        visited[start] = true;
        stack.push(start);
        let (mut left, mut right) = (start % mask_width, start % mask_width);
        let (mut top, mut bottom) = (start / mask_width, start / mask_width);
        let (mut sum, mut count) = (0.0, 0);
        while let Some(index) = stack.pop() {
            let (column, row) = (index % mask_width, index / mask_width);
            left = left.min(column);
            right = right.max(column);
            top = top.min(row);
            bottom = bottom.max(row);
            sum += mask[index];
            count += 1;
            for next_row in row.saturating_sub(1)..=(row + 1).min(mask_height - 1) {
                for next_column in column.saturating_sub(1)..=(column + 1).min(mask_width - 1) {
                    let neighbor = next_row * mask_width + next_column;
                    if !visited[neighbor] && mask[neighbor] > 0.3 {
                        visited[neighbor] = true;
                        stack.push(neighbor);
                    }
                }
            }
        }
        let (box_width, box_height) = (right - left + 1, bottom - top + 1);
        if box_width < 3 || box_height < 3 || sum / (count as f32) < 0.5 {
            continue;
        }
        let padding = (box_width.min(box_height) / 2).max(1);
        let left = left.saturating_sub(padding) * width / mask_width;
        let top = top.saturating_sub(padding) * height / mask_height;
        let right = ((right + 1 + padding).min(mask_width) * width).div_ceil(mask_width);
        let bottom = ((bottom + 1 + padding).min(mask_height) * height).div_ceil(mask_height);
        if right > left && bottom > top {
            regions.push(Region {
                left,
                top,
                width: right - left,
                height: bottom - top,
            });
        }
    }
    regions
}

struct Recognizer {
    session: Session,
    alphabet: Vec<String>,
}

struct Recognition {
    text: String,
    confidence: f32,
}

impl Recognizer {
    fn open(path: &Path) -> Result<Self, OfflineOcrFailure> {
        let session = open_session(path)?;
        let characters = session
            .metadata()
            .map_err(OfflineOcrFailure::backend)?
            .custom("character")
            .ok_or_else(|| OfflineOcrFailure::backend("missing OCR alphabet"))?;
        let mut alphabet = vec![String::new()];
        alphabet.extend(characters.lines().map(str::to_owned));
        alphabet.push(" ".to_owned());
        Ok(Self { session, alphabet })
    }

    fn read(&mut self, tensor: &[f32], width: usize) -> Result<Recognition, OfflineOcrFailure> {
        let input = TensorRef::from_array_view(([1, 3, 48, width], tensor))
            .map_err(OfflineOcrFailure::backend)?;
        let predictions = self
            .session
            .run(ort::inputs![input])
            .map_err(OfflineOcrFailure::backend)?;
        let (shape, scores) = predictions[0]
            .try_extract_tensor::<f32>()
            .map_err(OfflineOcrFailure::backend)?;
        let classes = self.alphabet.len();
        if shape.len() != 3 || shape[0] != 1 || shape[2] != classes as i64 {
            return Err(OfflineOcrFailure::backend(
                "unexpected OCR recognizer output",
            ));
        }
        let mut text = String::new();
        let (mut total, mut count, mut previous) = (0.0, 0, 0);
        for step in scores.chunks_exact(classes) {
            let (index, confidence) =
                step.iter()
                    .copied()
                    .enumerate()
                    .fold(
                        (0, step[0]),
                        |best, value| if value.1 > best.1 { value } else { best },
                    );
            if index != 0 && index != previous {
                text.push_str(&self.alphabet[index]);
                total += confidence;
                count += 1;
            }
            previous = index;
        }
        Ok(Recognition {
            text,
            confidence: total / count.max(1) as f32,
        })
    }
}
