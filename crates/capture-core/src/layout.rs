//! Grouping OCR lines into paragraphs for in-place screen translation.

use crate::formatting::{
    self, TextFormattingMode, apply_pangu_spacing, is_sentence_terminator_end, merge_two_lines,
    remove_extraneous_spaces, starts_with_list_marker,
};
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
    // Handle both Top-Left (Y-down, Windows/standard screen) and Bottom-Left (Y-up, macOS Vision) coordinates.
    let vertical_gap = if below_box.mid_y() >= above_box.mid_y() {
        below_box.min_y() - above_box.max_y()
    } else {
        above_box.min_y() - below_box.max_y()
    };
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

#[derive(Clone, Debug)]
struct StandardizedLine<'a> {
    original: &'a TextLine,
    box_down: Rect,
}

fn standardize_lines<'a>(lines: &'a [TextLine]) -> Vec<StandardizedLine<'a>> {
    let non_empty: Vec<&'a TextLine> = lines
        .iter()
        .filter(|l| {
            !l.text.trim().is_empty() && l.bounding_box.width > 0.0 && l.bounding_box.height > 0.0
        })
        .collect();
    if non_empty.is_empty() {
        return Vec::new();
    }

    let mut y_up_votes = 0;
    let mut y_down_votes = 0;
    for i in 0..non_empty.len().saturating_sub(1) {
        let y_curr = non_empty[i].bounding_box.mid_y();
        let y_next = non_empty[i + 1].bounding_box.mid_y();
        let dy = y_next - y_curr;
        if dy.abs() > non_empty[i].bounding_box.height * 0.4 {
            if dy < 0.0 {
                y_up_votes += 1;
            } else {
                y_down_votes += 1;
            }
        }
    }
    let is_y_up = y_up_votes > y_down_votes;

    let max_y = non_empty
        .iter()
        .map(|l| l.bounding_box.max_y())
        .fold(0.0, f64::max);

    non_empty
        .into_iter()
        .map(|l| {
            let std_box = l.bounding_box.standardized();
            let box_down = if is_y_up {
                Rect::new(
                    std_box.x,
                    max_y - std_box.y - std_box.height,
                    std_box.width,
                    std_box.height,
                )
            } else {
                std_box
            };
            StandardizedLine {
                original: l,
                box_down,
            }
        })
        .collect()
}

fn partition_into_columns<'a>(lines: Vec<StandardizedLine<'a>>) -> Vec<Vec<StandardizedLine<'a>>> {
    if lines.len() < 4 {
        let mut col = lines;
        sort_column_lines(&mut col);
        return vec![col];
    }

    let min_x = lines
        .iter()
        .map(|l| l.box_down.min_x())
        .fold(f64::INFINITY, f64::min);
    let max_x = lines
        .iter()
        .map(|l| l.box_down.max_x())
        .fold(f64::NEG_INFINITY, f64::max);
    let total_width = max_x - min_x;
    let median_height = median(lines.iter().map(|l| l.box_down.height).collect());

    if total_width < median_height * 6.0 {
        let mut col = lines;
        sort_column_lines(&mut col);
        return vec![col];
    }

    let min_gutter_width = median_height * 1.5;
    let mut sorted_by_x = lines.clone();
    sorted_by_x.sort_by(|a, b| a.box_down.min_x().partial_cmp(&b.box_down.min_x()).unwrap());

    let mut best_split_x = None;
    let mut max_gutter = 0.0;

    for i in 0..sorted_by_x.len() - 1 {
        let left_max_x = sorted_by_x[0..=i]
            .iter()
            .map(|l| l.box_down.max_x())
            .fold(f64::NEG_INFINITY, f64::max);
        let right_min_x = sorted_by_x[i + 1..]
            .iter()
            .map(|l| l.box_down.min_x())
            .fold(f64::INFINITY, f64::min);
        let gutter = right_min_x - left_max_x;

        if gutter >= min_gutter_width && gutter > max_gutter {
            let left_count = i + 1;
            let right_count = sorted_by_x.len() - left_count;
            if left_count >= 2 && right_count >= 2 {
                max_gutter = gutter;
                best_split_x = Some(left_max_x + gutter * 0.5);
            }
        }
    }

    if let Some(split_x) = best_split_x {
        let (left, right): (Vec<_>, Vec<_>) = lines
            .into_iter()
            .partition(|l| l.box_down.mid_x() < split_x);
        let mut cols = Vec::new();
        if !left.is_empty() {
            cols.extend(partition_into_columns(left));
        }
        if !right.is_empty() {
            cols.extend(partition_into_columns(right));
        }
        cols
    } else {
        let mut col = lines;
        sort_column_lines(&mut col);
        vec![col]
    }
}

fn sort_column_lines(lines: &mut [StandardizedLine]) {
    lines.sort_by(|a, b| {
        let a_y = a.box_down.min_y();
        let b_y = b.box_down.min_y();
        let a_h = a.box_down.height;
        let b_h = b.box_down.height;
        let v_overlap = a.box_down.max_y().min(b.box_down.max_y()) - a_y.max(b_y);
        let min_h = a_h.min(b_h);
        if v_overlap > min_h * 0.4 {
            a.box_down.min_x().partial_cmp(&b.box_down.min_x()).unwrap()
        } else {
            a_y.partial_cmp(&b_y).unwrap()
        }
    });
}

fn median(mut values: Vec<f64>) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mid = values.len() / 2;
    if values.len() % 2 == 0 {
        (values[mid - 1] + values[mid]) / 2.0
    } else {
        values[mid]
    }
}

fn reflow_column(lines: &[StandardizedLine]) -> Vec<String> {
    if lines.is_empty() {
        return Vec::new();
    }
    if lines.len() == 1 {
        return vec![lines[0].original.text.trim().to_owned()];
    }

    let col_min_x = lines
        .iter()
        .map(|l| l.box_down.min_x())
        .fold(f64::INFINITY, f64::min);
    let col_max_x = lines
        .iter()
        .map(|l| l.box_down.max_x())
        .fold(f64::NEG_INFINITY, f64::max);
    let col_width = col_max_x - col_min_x;

    let median_height = median(lines.iter().map(|l| l.box_down.height).collect());

    let mut gaps = Vec::new();
    for i in 0..lines.len() - 1 {
        let gap = lines[i + 1].box_down.min_y() - lines[i].box_down.max_y();
        if gap > 0.0 {
            gaps.push(gap);
        }
    }
    let median_gap = if gaps.is_empty() {
        median_height * 0.3
    } else {
        median(gaps)
    };

    let mut paragraphs: Vec<String> = Vec::new();
    let mut current_para: Option<String> = None;

    for i in 0..lines.len() {
        let line_text = lines[i].original.text.trim();
        if line_text.is_empty() {
            continue;
        }

        if current_para.is_none() {
            current_para = Some(line_text.to_owned());
            continue;
        }

        let prev_line = &lines[i - 1];
        let curr_line = &lines[i];
        let prev_text = current_para.as_ref().unwrap();

        let v_gap = curr_line.box_down.min_y() - prev_line.box_down.max_y();
        let prev_right_shortfall = col_max_x - prev_line.box_down.max_x();
        let curr_left_indent = curr_line.box_down.min_x() - col_min_x;

        let prev_ends_clause = is_sentence_terminator_end(prev_text)
            || prev_text.ends_with(':')
            || prev_text.ends_with('：');

        let is_continuation_indent = !prev_ends_clause
            && !starts_with_list_marker(line_text)
            && curr_left_indent > median_height * 0.8
            && curr_left_indent < col_width * 0.4;

        let should_break = starts_with_list_marker(line_text)
            || prev_ends_clause
            || v_gap > (median_gap * 1.5).max(median_height * 0.7)
            || (col_width > median_height * 4.0
                && prev_right_shortfall > (col_width * 0.22).max(median_height * 1.8))
            || (!is_continuation_indent
                && curr_left_indent > median_height * 1.2
                && curr_left_indent < col_width * 0.4)
            || prev_line.box_down.height > median_height * 1.35
            || curr_line.box_down.height > median_height * 1.35;

        if should_break {
            paragraphs.push(current_para.take().unwrap());
            current_para = Some(line_text.to_owned());
        } else {
            let merged = merge_two_lines(prev_text, line_text);
            current_para = Some(merged);
        }
    }

    if let Some(p) = current_para {
        paragraphs.push(p);
    }

    paragraphs
}

pub fn layout_format(lines: &[TextLine], mode: TextFormattingMode) -> String {
    if lines.is_empty() {
        return String::new();
    }

    let std_lines = standardize_lines(lines);
    if std_lines.is_empty() {
        let raw = lines
            .iter()
            .map(|l| l.text.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        return formatting::format(&raw, mode);
    }

    let columns = partition_into_columns(std_lines);

    match mode {
        TextFormattingMode::SmartMerge => {
            let mut col_paras = Vec::new();
            for col in columns {
                let paras = reflow_column(&col);
                col_paras.extend(paras);
            }
            let text = col_paras.join("\n\n");
            let cleaned = formatting::clean_icon_artifacts(&text);
            apply_pangu_spacing(&cleaned)
        }
        TextFormattingMode::PreserveBreaks => {
            let mut ordered_lines = Vec::new();
            for col in columns {
                for l in col {
                    ordered_lines.push(l.original.text.trim().to_owned());
                }
            }
            let text = ordered_lines.join("\n");
            let cleaned = formatting::clean_icon_artifacts(&text);
            apply_pangu_spacing(&cleaned)
        }
        TextFormattingMode::RemoveSpaces => {
            let mut col_paras = Vec::new();
            for col in columns {
                let paras = reflow_column(&col);
                col_paras.extend(paras);
            }
            let text = col_paras.join("\n\n");
            let cleaned = formatting::clean_icon_artifacts(&text);
            remove_extraneous_spaces(&cleaned)
        }
        TextFormattingMode::Raw => {
            let mut ordered_lines = Vec::new();
            for col in columns {
                for l in col {
                    ordered_lines.push(l.original.text.as_str());
                }
            }
            ordered_lines.join("\n")
        }
    }
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
    fn screen_coordinates_y_down_merge_paragraphs() {
        let result = paragraphs(&[
            line("First line", 10.0, 100.0, 200.0, 20.0),
            line("second line", 10.0, 125.0, 200.0, 20.0),
        ]);

        assert_eq!(result.len(), 1);
        assert_eq!(result[0].text, "First line second line");
        assert_eq!(result[0].line_count, 2);
        assert_eq!(result[0].bounding_box.x, 10.0);
        assert_eq!(result[0].bounding_box.y, 100.0);
        assert_eq!(result[0].bounding_box.width, 200.0);
        assert_eq!(result[0].bounding_box.height, 45.0);
    }

    #[test]
    fn layout_format_merges_lines_within_paragraph_and_preserves_short_line_ends() {
        // Line 1 and Line 2 form a paragraph (both wide, right edge near 300)
        // Line 3 ends short (right edge at 180, gap to 300 is 120 > 22% of 300)
        // Line 4 starts a new paragraph
        let lines = vec![
            line("这是段落的第一行内容，很长很长，", 10.0, 10.0, 280.0, 18.0),
            line(
                "这是段落的第二行内容，也很长很长，",
                10.0,
                32.0,
                285.0,
                18.0,
            ),
            line("这是末尾短行。", 10.0, 54.0, 120.0, 18.0),
            line(
                "这是新的一段开头内容，也很长很长。",
                10.0,
                76.0,
                280.0,
                18.0,
            ),
        ];

        let formatted = layout_format(&lines, TextFormattingMode::SmartMerge);
        assert_eq!(
            formatted,
            "这是段落的第一行内容，很长很长，这是段落的第二行内容，也很长很长，这是末尾短行。\n\n这是新的一段开头内容，也很长很长。"
        );
    }

    #[test]
    fn layout_format_splits_columns_in_reading_order() {
        // Two columns: Left column from x=10..180, Right column from x=240..420
        // Even if right column line 1 is physically at y=10, left column must come before right column!
        let lines = vec![
            line("Left col line 1", 10.0, 10.0, 160.0, 18.0),
            line("Right col line 1", 240.0, 10.0, 160.0, 18.0),
            line("Left col line 2", 10.0, 32.0, 160.0, 18.0),
            line("Right col line 2", 240.0, 32.0, 160.0, 18.0),
        ];

        let formatted = layout_format(&lines, TextFormattingMode::SmartMerge);
        assert_eq!(
            formatted,
            "Left col line 1 Left col line 2\n\nRight col line 1 Right col line 2"
        );
    }

    #[test]
    fn layout_format_rejoins_hyphenated_english() {
        let lines = vec![
            line("This is an inter-", 10.0, 10.0, 250.0, 18.0),
            line("action design pattern.", 10.0, 32.0, 250.0, 18.0),
        ];

        let formatted = layout_format(&lines, TextFormattingMode::SmartMerge);
        assert_eq!(formatted, "This is an interaction design pattern.");
    }
}
