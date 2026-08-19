//! Sentence-level alignment between source text and its translation.
//!
//! Offsets are UTF-16 code-unit based because the macOS UI addresses text with
//! `NSRange`. Every platform therefore agrees on the same indices.

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SegmentPair {
    pub id: u32,
    pub source_text: String,
    pub target_text: String,
    pub source_location: u32,
    pub source_length: u32,
    pub target_location: u32,
    pub target_length: u32,
}

pub fn pairs(source: &str, target: &str) -> Vec<SegmentPair> {
    let source_segments = segments(source);
    let target_segments = segments(target);
    let count = source_segments.len().max(target_segments.len());
    (0..count)
        .map(|index| {
            let source_segment = source_segments.get(index);
            let target_segment = target_segments.get(index);
            SegmentPair {
                id: index as u32,
                source_text: source_segment.map(|s| s.text.clone()).unwrap_or_default(),
                target_text: target_segment.map(|s| s.text.clone()).unwrap_or_default(),
                source_location: source_segment.map(|s| s.location).unwrap_or(0),
                source_length: source_segment.map(|s| s.length).unwrap_or(0),
                target_location: target_segment.map(|s| s.location).unwrap_or(0),
                target_length: target_segment.map(|s| s.length).unwrap_or(0),
            }
        })
        .collect()
}

pub fn pair_id(character_index: u32, in_source: bool, pairs: &[SegmentPair]) -> Option<u32> {
    pairs
        .iter()
        .find(|pair| {
            let (location, length) = if in_source {
                (pair.source_location, pair.source_length)
            } else {
                (pair.target_location, pair.target_length)
            };
            length > 0
                && character_index >= location
                && character_index < location.saturating_add(length)
        })
        .map(|pair| pair.id)
}

struct Segment {
    text: String,
    location: u32,
    length: u32,
}

fn segments(text: &str) -> Vec<Segment> {
    let units: Vec<u16> = text.encode_utf16().collect();
    if units.is_empty() {
        return Vec::new();
    }

    let mut result: Vec<Segment> = Vec::new();
    let mut start = 0usize;
    let mut index = 0usize;

    while index < units.len() {
        let unit = units[index];
        if is_surrogate(unit) {
            index += 1;
            continue;
        }
        if unit == u16::from(b'\n') || unit == u16::from(b'\r') {
            append_segment(&units, start, index, &mut result);
            index += 1;
            start = index;
            continue;
        }
        if is_segment_punctuation(unit) {
            let mut end = index + 1;
            while end < units.len()
                && !is_surrogate(units[end])
                && is_segment_punctuation(units[end])
            {
                end += 1;
            }
            append_segment(&units, start, end, &mut result);
            index = end;
            start = end;
            continue;
        }
        index += 1;
    }
    append_segment(&units, start, units.len(), &mut result);
    result
}

fn append_segment(units: &[u16], start: usize, end: usize, result: &mut Vec<Segment>) {
    if end <= start {
        return;
    }
    let mut lower = start;
    let mut upper = end;
    while lower < upper && is_foundation_whitespace(units[lower]) {
        lower += 1;
    }
    while upper > lower && is_foundation_whitespace(units[upper - 1]) {
        upper -= 1;
    }
    if upper <= lower {
        return;
    }
    result.push(Segment {
        text: String::from_utf16_lossy(&units[lower..upper]),
        location: lower as u32,
        length: (upper - lower) as u32,
    });
}

fn is_surrogate(unit: u16) -> bool {
    (0xD800..=0xDFFF).contains(&unit)
}

fn is_segment_punctuation(unit: u16) -> bool {
    matches!(
        unit,
        0x2E // .
            | 0x21 // !
            | 0x3F // ?
            | 0x3002 // 。
            | 0xFF01 // ！
            | 0xFF1F // ？
            | 0xFF1B // ；
            | 0x3B // ;
    )
}

/// Mirrors `CharacterSet.whitespacesAndNewlines`.
fn is_foundation_whitespace(unit: u16) -> bool {
    crate::text::is_foundation_whitespace_unit(unit)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sentences_split_on_terminal_punctuation() {
        let result = pairs("Hello world. How are you?", "你好世界。你好吗？");

        assert_eq!(result.len(), 2);
        assert_eq!(result[0].source_text, "Hello world.");
        assert_eq!(result[0].target_text, "你好世界。");
        assert_eq!(result[1].source_text, "How are you?");
    }

    #[test]
    fn runs_of_punctuation_stay_with_their_sentence() {
        let result = pairs("Wait?! Really.", "");

        assert_eq!(result.len(), 2);
        assert_eq!(result[0].source_text, "Wait?!");
        assert_eq!(result[1].source_text, "Really.");
    }

    #[test]
    fn newlines_break_segments_without_being_kept() {
        let result = pairs("first\nsecond", "");

        assert_eq!(result.len(), 2);
        assert_eq!(result[0].source_text, "first");
        assert_eq!(result[1].source_text, "second");
        assert_eq!(result[1].source_location, 6);
    }

    #[test]
    fn offsets_are_utf16_code_units() {
        let result = pairs("😀ab. cd.", "");

        assert_eq!(result[0].source_text, "😀ab.");
        assert_eq!(result[0].source_location, 0);
        assert_eq!(result[0].source_length, 5);
        assert_eq!(result[1].source_location, 6);
    }

    #[test]
    fn zero_width_space_is_trimmed_like_foundation_does() {
        let result = pairs("\u{200B}text.", "");

        assert_eq!(result[0].source_text, "text.");
        assert_eq!(result[0].source_location, 1);
    }

    #[test]
    fn uneven_segment_counts_pad_with_empty_text() {
        let result = pairs("one. two. three.", "一。");

        assert_eq!(result.len(), 3);
        assert_eq!(result[1].target_text, "");
        assert_eq!(result[1].target_length, 0);
    }

    #[test]
    fn empty_input_yields_no_pairs() {
        assert!(pairs("", "").is_empty());
        assert!(pairs("   \n  ", "").is_empty());
    }

    #[test]
    fn pair_lookup_uses_half_open_ranges() {
        let result = pairs("Hello world. How are you?", "");

        assert_eq!(pair_id(0, true, &result), Some(0));
        assert_eq!(pair_id(11, true, &result), Some(0));
        assert_eq!(pair_id(12, true, &result), None);
        assert_eq!(pair_id(13, true, &result), Some(1));
        assert_eq!(pair_id(999, true, &result), None);
    }
}
