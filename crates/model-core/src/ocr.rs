//! PP-OCRv4 CPU inference using user-installed ONNX models.

use crate::initialize_runtime;
use ort::session::Session;
use ort::value::TensorRef;
use std::collections::VecDeque;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct BoxRect {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
}

pub struct OnnxOcr {
    detector: Session,
    recognizer: Session,
    keys: Vec<String>,
}

impl OnnxOcr {
    pub fn open(runtime_path: &Path, model_root: &Path) -> Result<Self, String> {
        initialize_runtime(runtime_path)?;
        let folder = model_root.join("ocr");
        let det = find_file(&folder, &["det.onnx", "ch_PP-OCRv4_det_infer.onnx"])
            .or_else(|| find_file(model_root, &["det.onnx", "ch_PP-OCRv4_det_infer.onnx"]))
            .ok_or("PP-OCR detector model is not installed")?;
        let rec = find_file(&folder, &["rec.onnx", "ch_PP-OCRv4_rec_infer.onnx"])
            .or_else(|| find_file(model_root, &["rec.onnx", "ch_PP-OCRv4_rec_infer.onnx"]))
            .ok_or("PP-OCR recognizer model is not installed")?;
        let keys_path = find_file(&folder, &["keys.txt", "ppocr_keys_v1.txt"])
            .or_else(|| find_file(model_root, &["keys.txt", "ppocr_keys_v1.txt"]))
            .ok_or("PP-OCR key file is not installed")?;
        let detector = Session::builder()
            .map_err(|error| error.to_string())?
            .commit_from_file(det)
            .map_err(|error| error.to_string())?;
        let recognizer = Session::builder()
            .map_err(|error| error.to_string())?
            .commit_from_file(rec)
            .map_err(|error| error.to_string())?;
        let mut keys = Vec::new();
        keys.push(String::new());
        keys.extend(
            fs::read_to_string(keys_path)
                .map_err(|error| error.to_string())?
                .lines()
                .map(|line| line.trim_end_matches('\r').to_string()),
        );
        keys.push(" ".into());
        Ok(Self {
            detector,
            recognizer,
            keys,
        })
    }

    pub fn recognize_rgba(
        &mut self,
        rgba: &[u8],
        width: usize,
        height: usize,
    ) -> Result<String, String> {
        if width == 0
            || height == 0
            || width
                .checked_mul(height)
                .and_then(|pixels| pixels.checked_mul(4))
                != Some(rgba.len())
        {
            return Err("invalid RGBA image dimensions".into());
        }
        if width.saturating_mul(height) > 100_000_000 {
            return Err("image exceeds the 100-megapixel limit".into());
        }
        let boxes = self.detect_boxes(rgba, width, height)?;
        let mut lines = Vec::new();
        for region in boxes {
            let text = self.recognize_box(rgba, width, height, region)?;
            if !text.trim().is_empty() {
                lines.push(text);
            }
        }
        Ok(lines.join("\n"))
    }

    fn detect_boxes(
        &mut self,
        rgba: &[u8],
        width: usize,
        height: usize,
    ) -> Result<Vec<BoxRect>, String> {
        let max_side = width.max(height);
        let scale = if max_side > 960 {
            960.0 / max_side as f64
        } else {
            1.0
        };
        let target_w = (((width as f64 * scale) as usize / 32) * 32).max(32);
        let target_h = (((height as f64 * scale) as usize / 32) * 32).max(32);
        let plane = target_w * target_h;
        let mut tensor = vec![0.0f32; plane * 3];
        for ty in 0..target_h {
            let sy = (ty * height / target_h).min(height - 1);
            for tx in 0..target_w {
                let sx = (tx * width / target_w).min(width - 1);
                let pixel = (sy * width + sx) * 4;
                let index = ty * target_w + tx;
                tensor[index] = (rgba[pixel] as f32 / 255.0 - 0.485) / 0.229;
                tensor[plane + index] = (rgba[pixel + 1] as f32 / 255.0 - 0.456) / 0.224;
                tensor[2 * plane + index] = (rgba[pixel + 2] as f32 / 255.0 - 0.406) / 0.225;
            }
        }
        let input = TensorRef::from_array_view(([1usize, 3, target_h, target_w], &*tensor))
            .map_err(|error| error.to_string())?;
        let outputs = self
            .detector
            .run(ort::inputs![input])
            .map_err(|error| error.to_string())?;
        let (shape, mask) = outputs[0]
            .try_extract_tensor::<f32>()
            .map_err(|error| error.to_string())?;
        if shape.len() != 4 || shape[0] != 1 || shape[1] != 1 || shape[2] <= 0 || shape[3] <= 0 {
            return Err(format!("unexpected detector output shape: {shape:?}"));
        }
        let mask_h = shape[2] as usize;
        let mask_w = shape[3] as usize;
        if mask_h.checked_mul(mask_w) != Some(mask.len()) {
            return Err("detector output buffer size mismatch".into());
        }
        Ok(detect_components(mask, mask_w, mask_h, width, height))
    }

    fn recognize_box(
        &mut self,
        rgba: &[u8],
        width: usize,
        height: usize,
        region: BoxRect,
    ) -> Result<String, String> {
        let bx = region.x.min(width - 1);
        let by = region.y.min(height - 1);
        let bw = region.width.min(width - bx);
        let bh = region.height.min(height - by);
        if bw < 2 || bh < 2 {
            return Ok(String::new());
        }
        let rec_h = 48usize;
        let rec_w = ((48.0 * bw as f64 / bh as f64) as usize).clamp(16, 2048);
        let plane = rec_h * rec_w;
        let mut tensor = vec![0.0f32; plane * 3];
        for ty in 0..rec_h {
            let sy = by + (ty * bh / rec_h).min(bh - 1);
            for tx in 0..rec_w {
                let sx = bx + (tx * bw / rec_w).min(bw - 1);
                let pixel = (sy * width + sx) * 4;
                let index = ty * rec_w + tx;
                tensor[index] = (rgba[pixel] as f32 / 255.0 - 0.5) / 0.5;
                tensor[plane + index] = (rgba[pixel + 1] as f32 / 255.0 - 0.5) / 0.5;
                tensor[2 * plane + index] = (rgba[pixel + 2] as f32 / 255.0 - 0.5) / 0.5;
            }
        }
        let input = TensorRef::from_array_view(([1usize, 3, rec_h, rec_w], &*tensor))
            .map_err(|error| error.to_string())?;
        let outputs = self
            .recognizer
            .run(ort::inputs![input])
            .map_err(|error| error.to_string())?;
        let (shape, scores) = outputs[0]
            .try_extract_tensor::<f32>()
            .map_err(|error| error.to_string())?;
        if shape.len() != 3 || shape[0] != 1 || shape[1] <= 0 || shape[2] <= 0 {
            return Err(format!("unexpected recognizer output shape: {shape:?}"));
        }
        Ok(ctc_decode(
            scores,
            shape[1] as usize,
            shape[2] as usize,
            &self.keys,
        ))
    }
}

fn find_file(folder: &Path, names: &[&str]) -> Option<PathBuf> {
    names
        .iter()
        .map(|name| folder.join(name))
        .find(|path| path.is_file())
}

fn detect_components(
    mask: &[f32],
    mask_w: usize,
    mask_h: usize,
    image_w: usize,
    image_h: usize,
) -> Vec<BoxRect> {
    let mut visited = vec![false; mask.len()];
    let mut boxes = Vec::new();
    for y in 0..mask_h {
        for x in 0..mask_w {
            let start = y * mask_w + x;
            if visited[start] || mask[start] <= 0.3 {
                continue;
            }
            let mut queue = VecDeque::new();
            queue.push_back((x, y));
            visited[start] = true;
            let (mut min_x, mut max_x, mut min_y, mut max_y) = (x, x, y, y);
            let (mut sum, mut count) = (0.0f32, 0usize);
            while let Some((cx, cy)) = queue.pop_front() {
                min_x = min_x.min(cx);
                max_x = max_x.max(cx);
                min_y = min_y.min(cy);
                max_y = max_y.max(cy);
                sum += mask[cy * mask_w + cx];
                count += 1;
                let neighbors = [
                    (cx.wrapping_sub(1), cy),
                    (cx + 1, cy),
                    (cx, cy.wrapping_sub(1)),
                    (cx, cy + 1),
                ];
                for (nx, ny) in neighbors {
                    if nx >= mask_w || ny >= mask_h {
                        continue;
                    }
                    let index = ny * mask_w + nx;
                    if !visited[index] && mask[index] > 0.3 {
                        visited[index] = true;
                        queue.push_back((nx, ny));
                    }
                }
            }
            let bw = max_x - min_x + 1;
            let bh = max_y - min_y + 1;
            if bw < 3 || bh < 3 || sum / (count as f32) < 0.5 {
                continue;
            }
            let unclip = (bh as f64 * 0.4).min(4.0);
            let sx = image_w as f64 / mask_w as f64;
            let sy = image_h as f64 / mask_h as f64;
            let left = ((min_x as f64 - unclip) * sx).max(0.0) as usize;
            let top = ((min_y as f64 - unclip) * sy).max(0.0) as usize;
            let right = (((max_x + 1) as f64 + unclip) * sx).min(image_w as f64) as usize;
            let bottom = (((max_y + 1) as f64 + unclip) * sy).min(image_h as f64) as usize;
            if right > left && bottom > top {
                boxes.push(BoxRect {
                    x: left,
                    y: top,
                    width: right - left,
                    height: bottom - top,
                });
            }
        }
    }
    boxes.sort_by_key(|region| (region.y / 24, region.x));
    boxes
}

fn ctc_decode(scores: &[f32], steps: usize, classes: usize, keys: &[String]) -> String {
    if classes == 0 || steps.checked_mul(classes) != Some(scores.len()) {
        return String::new();
    }
    let mut result = String::new();
    let mut last = usize::MAX;
    for row in scores.chunks_exact(classes) {
        let best = row.iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1));
        if let Some((index, _)) = best {
            if index != 0 && index != last {
                if let Some(key) = keys.get(index) {
                    result.push_str(key);
                }
            }
            last = index;
        }
    }
    result.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connected_components_ignore_low_confidence_noise() {
        let mut mask = vec![0.0; 10 * 10];
        for y in 1..4 {
            for x in 2..6 {
                mask[y * 10 + x] = 0.9;
            }
        }
        for y in 6..9 {
            for x in 6..9 {
                mask[y * 10 + x] = 0.4;
            }
        }
        let boxes = detect_components(&mask, 10, 10, 100, 100);
        assert_eq!(boxes.len(), 1);
        assert!(boxes[0].width > 30);
    }

    #[test]
    fn ctc_decode_collapses_repeats_and_blanks() {
        let keys = vec!["".into(), "你".into(), "好".into()];
        let scores = [0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0];
        assert_eq!(ctc_decode(&scores, 4, 3, &keys), "你好");
    }
}
