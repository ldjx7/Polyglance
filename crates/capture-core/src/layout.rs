//! Grouping OCR lines into paragraphs for in-place screen translation.

use crate::rect::Rect;
use crate::text::{is_cjk, last_base_scalar, trim_foundation_whitespace};

#[derive(Clone, Debug, PartialEq)]
pub struct TextLine {
    pub text: String,
    pub bounding_box: Rect,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Paragraph {
    pub text: String,
    pub bounding_box: Rect,
    pub line_count: u32,
}

pub fn paragraphs(lines: &[TextLine]) -> Vec<Paragraph> {
    let mut groups: Vec<Vec<&TextLine>> = Vec::new();
    for line in lines.iter().filter(|line| !line.text.is_empty()) {
        let extends_current = groups
            .last()
            .and_then(|group| group.last())
            .is_some_and(|previous| belongs_to_same_paragraph(previous, line));
        if extends_current {
            groups
                .last_mut()
                .expect("a current group exists")
                .push(line);
        } else {
            groups.push(vec![line]);
        }
    }
    groups
        .into_iter()
        .map(|group| Paragraph {
            text: joined_text(&group),
            bounding_box: union_box(&group),
            line_count: group.len() as u32,
        })
        .collect()
}

fn belongs_to_same_paragraph(above: &TextLine, below: &TextLine) -> bool {
    let above_box = above.bounding_box.standardized();
    let below_box = below.bounding_box.standardized();
    let reference_height = above_box.height.min(below_box.height);
    if reference_height <= 0.0 {
        return false;
    }
    let vertical_gap = above_box.min_y() - below_box.max_y();
    if vertical_gap > reference_height * 0.85 || vertical_gap < -reference_height * 0.4 {
        return false;
    }
    let horizontal_overlap =
        above_box.max_x().min(below_box.max_x()) - above_box.min_x().max(below_box.min_x());
    if horizontal_overlap < -reference_height * 1.5 {
        return false;
    }
    let height_ratio =
        above_box.height.max(below_box.height) / reference_height.max(f64::MIN_POSITIVE);
    height_ratio <= 1.9
}

fn joined_text(lines: &[&TextLine]) -> String {
    let mut result = String::new();
    for line in lines {
        let text = trim_foundation_whitespace(&line.text);
        if text.is_empty() {
            continue;
        }
        if result.is_empty() {
            result.push_str(text);
            continue;
        }
        let joins_without_space = match (last_base_scalar(&result), text.chars().next()) {
            (Some(previous), Some(next)) => is_cjk(previous) || is_cjk(next),
            _ => false,
        };
        if !joins_without_space {
            result.push(' ');
        }
        result.push_str(text);
    }
    result
}

fn union_box(lines: &[&TextLine]) -> Rect {
    let mut box_union = lines[0].bounding_box.standardized();
    for line in lines.iter().skip(1) {
        box_union = box_union.union(line.bounding_box.standardized());
    }
    box_union
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(text: &str, x: f64, y: f64, width: f64, height: f64) -> TextLine {
        TextLine {
            text: text.to_string(),
            bounding_box: Rect::new(x, y, width, height),
        }
    }

    #[test]
    fn adjacent_lines_of_similar_height_form_one_paragraph() {
        let result = paragraphs(&[
            line("Hello", 0.1, 0.80, 0.4, 0.04),
            line("world", 0.1, 0.75, 0.4, 0.04),
        ]);

        assert_eq!(result.len(), 1);
        assert_eq!(result[0].text, "Hello world");
        assert_eq!(result[0].line_count, 2);
    }

    #[test]
    fn a_large_vertical_gap_starts_a_new_paragraph() {
        let result = paragraphs(&[
            line("Hello", 0.1, 0.80, 0.4, 0.04),
            line("world", 0.1, 0.50, 0.4, 0.04),
        ]);

        assert_eq!(result.len(), 2);
    }

    #[test]
    fn a_very_different_font_size_starts_a_new_paragraph() {
        let result = paragraphs(&[
            line("Title", 0.1, 0.80, 0.4, 0.10),
            line("body", 0.1, 0.77, 0.4, 0.03),
        ]);

        assert_eq!(result.len(), 2);
    }

    #[test]
    fn cjk_lines_join_without_a_space() {
        let result = paragraphs(&[
            line("你好", 0.1, 0.80, 0.4, 0.04),
            line("世界", 0.1, 0.75, 0.4, 0.04),
        ]);

        assert_eq!(result[0].text, "你好世界");
    }

    #[test]
    fn a_trailing_variation_selector_still_reads_as_cjk() {
        let result = paragraphs(&[
            line("漢\u{FE00}", 0.1, 0.80, 0.4, 0.04),
            line("字", 0.1, 0.75, 0.4, 0.04),
        ]);

        assert_eq!(result[0].text, "漢\u{FE00}字");
    }

    #[test]
    fn line_text_is_trimmed_before_joining() {
        let result = paragraphs(&[
            line("  Hello  ", 0.1, 0.80, 0.4, 0.04),
            line("\u{200B}world", 0.1, 0.75, 0.4, 0.04),
        ]);

        assert_eq!(result[0].text, "Hello world");
    }

    #[test]
    fn the_bounding_box_covers_every_line() {
        let result = paragraphs(&[
            line("Hello", 0.1, 0.80, 0.2, 0.04),
            line("world", 0.3, 0.75, 0.3, 0.04),
        ]);
        let box_union = result[0].bounding_box;

        for (actual, expected) in [
            (box_union.x, 0.1),
            (box_union.y, 0.75),
            (box_union.width, 0.5),
            (box_union.height, 0.09),
        ] {
            assert!(
                (actual - expected).abs() < 1e-9,
                "expected {expected}, got {actual}"
            );
        }
    }

    #[test]
    fn empty_lines_are_skipped_entirely() {
        let result = paragraphs(&[
            line("", 0.1, 0.80, 0.4, 0.04),
            line("kept", 0.1, 0.75, 0.4, 0.04),
        ]);

        assert_eq!(result.len(), 1);
        assert_eq!(result[0].text, "kept");
    }

    #[test]
    fn no_lines_produce_no_paragraphs() {
        assert!(paragraphs(&[]).is_empty());
    }

    #[test]
    fn zero_height_lines_never_merge() {
        let result = paragraphs(&[
            line("a", 0.1, 0.80, 0.4, 0.0),
            line("b", 0.1, 0.80, 0.4, 0.0),
        ]);

        assert_eq!(result.len(), 2);
    }
}
