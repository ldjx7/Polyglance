//! OCR text post-processing shared by every Polyglance frontend.
//!
//! The macOS and Windows shells each carried a copy of this algorithm, written
//! against `NSRegularExpression` and `System.Text.RegularExpressions`. This
//! module replaces both, and reproduces those regular expressions' greedy,
//! non-overlapping, left-to-right matching rather than approximating it.

use crate::text::last_base_scalar;

/// How OCR output is reflowed before it reaches the clipboard or a translation
/// request. Frontends persist the discriminant, so these values are part of the
/// stored configuration format.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TextFormattingMode {
    SmartMerge = 0,
    PreserveBreaks = 1,
    RemoveSpaces = 2,
    Raw = 3,
}

impl TextFormattingMode {
    /// Unrecognised values fall back to [`TextFormattingMode::SmartMerge`], so a
    /// configuration written by a newer build cannot select a nonsense mode.
    pub fn from_raw(raw: u8) -> Self {
        match raw {
            1 => Self::PreserveBreaks,
            2 => Self::RemoveSpaces,
            3 => Self::Raw,
            _ => Self::SmartMerge,
        }
    }
}

pub fn format(text: &str, mode: TextFormattingMode) -> String {
    if text.is_empty() {
        return String::new();
    }
    let cleaned = clean_icon_artifacts(text);
    match mode {
        TextFormattingMode::SmartMerge => apply_pangu_spacing(&smart_merge_lines(&cleaned)),
        TextFormattingMode::PreserveBreaks => apply_pangu_spacing(&cleaned),
        TextFormattingMode::RemoveSpaces => remove_extraneous_spaces(&cleaned),
        TextFormattingMode::Raw => cleaned,
    }
}

/// Rejoins lines that OCR split at a visual line ending, while keeping the
/// breaks that carry meaning: blank lines, list items, and sentence ends.
pub fn smart_merge_lines(text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }

    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut output: Vec<String> = Vec::new();
    let mut pending: Option<String> = None;

    for raw_line in normalized.split('\n') {
        let line = raw_line.trim_matches(is_pattern_whitespace);
        if line.is_empty() {
            if let Some(previous) = pending.take() {
                output.push(previous);
                output.push(String::new());
            }
            continue;
        }

        pending = match pending.take() {
            None => Some(line.to_owned()),
            Some(previous) if preserves_line_break(&previous, line) => {
                output.push(previous);
                Some(line.to_owned())
            }
            Some(previous) => Some(merge_two_lines(&previous, line)),
        };
    }

    if let Some(previous) = pending {
        output.push(previous);
    }

    output
        .join("\n")
        .trim_matches(|character| character == '\n' || character == '\r')
        .to_owned()
}

/// Inserts the conventional space between CJK text and adjacent Latin letters
/// or digits.
pub fn apply_pangu_spacing(text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }

    let mut result = String::with_capacity(text.len());
    let mut previous: Option<char> = None;
    for character in text.chars() {
        if previous.is_some_and(|left| needs_pangu_space(left, character)) {
            result.push(' ');
        }
        result.push(character);
        previous = Some(character);
    }
    result
}

/// Drops the spaces some OCR engines emit between CJK characters and around
/// fullwidth punctuation. Runs to a fixed point because each pass consumes the
/// character that follows a match, which can leave a newly adjacent pair.
pub fn remove_extraneous_spaces(text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }

    let mut current = text.to_owned();
    loop {
        let mut next = collapse_space_between_cjk(&current);
        next = drop_space_after_cjk_punctuation(&next);
        next = drop_space_before_cjk_punctuation(&next);
        if next == current {
            return current;
        }
        current = next;
    }
}

/// CJK scripts plus the fullwidth and CJK punctuation blocks.
///
/// Deliberately wider than [`crate::text::is_cjk`]: that table was tuned for
/// joining paragraph lines and excludes fullwidth punctuation, so the two are
/// not interchangeable.
pub fn is_cjk(character: char) -> bool {
    is_cjk_script(character) || is_cjk_punctuation(character)
}

/// Han, kana, and hangul, without punctuation — the neighbours that earn a
/// pangu space.
fn is_cjk_script(character: char) -> bool {
    matches!(
        character as u32,
        0x3040..=0x30FF | 0x3400..=0x9FFF | 0xAC00..=0xD7AF | 0xF900..=0xFAFF
    )
}

fn is_cjk_punctuation(character: char) -> bool {
    matches!(character as u32, 0x3000..=0x303F | 0xFF01..=0xFFEE)
}

/// `\s` as both `NSRegularExpression` and .NET define it: the ASCII control
/// whitespace plus every Unicode separator.
fn is_pattern_whitespace(character: char) -> bool {
    matches!(
        character as u32,
        0x0009..=0x000D
            | 0x0020
            | 0x0085
            | 0x00A0
            | 0x1680
            | 0x2000..=0x200A
            | 0x2028
            | 0x2029
            | 0x202F
            | 0x205F
            | 0x3000
    )
}

fn needs_pangu_space(left: char, right: char) -> bool {
    (is_cjk_script(left) && right.is_ascii_alphanumeric())
        || ((left.is_ascii_alphanumeric() || left == '%') && is_cjk_script(right))
}

pub(crate) fn is_sentence_terminator_end(text: &str) -> bool {
    let mut tail = text.trim_end().chars().rev();
    let Some(last) = tail.next() else {
        return false;
    };
    if is_sentence_terminator(last) {
        return true;
    }
    if matches!(last, '”' | '’' | '"' | '\'' | ')' | '）' | ']' | '】')
        && tail.next().is_some_and(is_sentence_terminator)
    {
        return true;
    }
    false
}

pub(crate) fn preserves_line_break(previous: &str, next: &str) -> bool {
    if starts_with_list_marker(next) {
        return true;
    }

    if is_sentence_terminator_end(previous) {
        return true;
    }

    let trimmed = previous.trim_end();
    trimmed.ends_with(':') || trimmed.ends_with('：')
}

pub(crate) fn starts_with_list_marker(text: &str) -> bool {
    let rest = text.trim_start_matches(is_pattern_whitespace);
    let mut characters = rest.chars();
    match characters.next() {
        Some('•' | '·' | '●' | '○' | '◆' | '◇' | '■' | '□' | '▪' | '▫' | '❖' | '➢' | '➤') => {
            true
        }
        Some('-' | '*' | '+') => characters
            .next()
            .is_some_and(|c| is_pattern_whitespace(c) || c == ' '),
        Some(first) if first.is_ascii_digit() => {
            let mut after_digits = rest
                .chars()
                .skip_while(|character| character.is_ascii_digit());
            match after_digits.next() {
                Some('.' | ')' | '、' | '：' | ':') => true,
                _ => false,
            }
        }
        Some('(' | '（') => {
            let after_open = characters.as_str();
            if let Some(close_idx) = after_open.find(|c| c == ')' || c == '）') {
                close_idx <= 4
            } else {
                false
            }
        }
        _ => false,
    }
}

pub fn clean_icon_artifacts(text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }

    let chars: Vec<char> = text.chars().collect();
    let mut result = String::with_capacity(text.len());
    let mut i = 0;

    while i < chars.len() {
        let is_prefix = if i == 0 {
            true
        } else {
            let prev = chars[i - 1];
            matches!(
                prev,
                ':' | '：' | '•' | '·' | '-' | '*' | '|' | '(' | '（' | '[' | '【' | '\n' | '\r'
            ) || (is_pattern_whitespace(prev)
                && i >= 2
                && matches!(chars[i - 2], ':' | '：' | '•' | '·' | '\n' | '\r'))
        };

        if is_prefix {
            let mut s = i;
            while s < chars.len() && is_pattern_whitespace(chars[s]) {
                s += 1;
            }

            if s < chars.len()
                && (chars[s].is_ascii_alphabetic() || matches!(chars[s], '@' | '~' | '^' | '#'))
            {
                let next_s = s + 1;
                if next_s < chars.len() && is_pattern_whitespace(chars[next_s]) {
                    let mut after_space = next_s;
                    while after_space < chars.len() && is_pattern_whitespace(chars[after_space]) {
                        after_space += 1;
                    }
                    if after_space < chars.len() {
                        let target_char = chars[after_space];
                        let is_pascal_or_file = target_char.is_ascii_uppercase() || {
                            let mut w_end = after_space;
                            while w_end < chars.len()
                                && !is_pattern_whitespace(chars[w_end])
                                && chars[w_end] != '，'
                                && chars[w_end] != '。'
                                && chars[w_end] != ')'
                                && chars[w_end] != '）'
                            {
                                w_end += 1;
                            }
                            let word: String = chars[after_space..w_end].iter().collect();
                            word.contains('.')
                        };

                        if is_pascal_or_file {
                            for idx in i..s {
                                result.push(chars[idx]);
                            }
                            i = after_space;
                            continue;
                        }
                    }
                }
            }
        }

        result.push(chars[i]);
        i += 1;
    }

    result
}

pub(crate) fn is_sentence_terminator(character: char) -> bool {
    matches!(
        character,
        '。' | '！' | '？' | '；' | '…' | '.' | '!' | '?' | ';'
    )
}

pub(crate) fn merge_two_lines(previous: &str, next: &str) -> String {
    let prev_trimmed = previous.trim_end();
    let next_trimmed = next.trim_start();

    // Check hyphenation: e.g. "connec-" and "tion"
    if prev_trimmed.ends_with('-') || prev_trimmed.ends_with('‐') {
        let base = &prev_trimmed[..prev_trimmed.len() - 1];
        if let (Some(left), Some(right)) = (base.chars().last(), next_trimmed.chars().next()) {
            if left.is_ascii_alphabetic() && right.is_ascii_lowercase() {
                return format!("{base}{next_trimmed}");
            }
        }
    }

    match (last_base_scalar(prev_trimmed), next_trimmed.chars().next()) {
        (Some(left), Some(right)) if is_cjk(left) && is_cjk(right) => {
            format!("{prev_trimmed}{next_trimmed}")
        }
        (Some(_), Some(_)) => format!("{prev_trimmed} {next_trimmed}"),
        _ => format!("{prev_trimmed}{next_trimmed}"),
    }
}

/// `(cjk)\s+(cjk)` → `$1$2`.
fn collapse_space_between_cjk(text: &str) -> String {
    let characters: Vec<char> = text.chars().collect();
    let mut result = String::with_capacity(text.len());
    let mut index = 0;

    while index < characters.len() {
        let current = characters[index];
        if is_cjk(current) {
            let end = whitespace_run_end(&characters, index + 1);
            // Longest first, mirroring a greedy `\s+` that can still backtrack:
            // U+3000 is both whitespace and CJK, so a shorter run may also be
            // followed by a CJK character.
            let matched = (index + 2..=end)
                .rev()
                .find(|&position| position < characters.len() && is_cjk(characters[position]));
            if let Some(position) = matched {
                result.push(current);
                result.push(characters[position]);
                index = position + 1;
                continue;
            }
        }
        result.push(current);
        index += 1;
    }
    result
}

/// `(cjkPunctuation)\s+` → `$1`.
fn drop_space_after_cjk_punctuation(text: &str) -> String {
    let characters: Vec<char> = text.chars().collect();
    let mut result = String::with_capacity(text.len());
    let mut index = 0;

    while index < characters.len() {
        let current = characters[index];
        result.push(current);
        index += 1;
        if is_cjk_punctuation(current) {
            index = whitespace_run_end(&characters, index);
        }
    }
    result
}

/// `\s+(cjkPunctuation)` → `$1`.
fn drop_space_before_cjk_punctuation(text: &str) -> String {
    let characters: Vec<char> = text.chars().collect();
    let mut result = String::with_capacity(text.len());
    let mut index = 0;

    while index < characters.len() {
        if is_pattern_whitespace(characters[index]) {
            let end = whitespace_run_end(&characters, index + 1);
            let matched = (index + 1..=end).rev().find(|&position| {
                position < characters.len() && is_cjk_punctuation(characters[position])
            });
            if let Some(position) = matched {
                result.push(characters[position]);
                index = position + 1;
                continue;
            }
        }
        result.push(characters[index]);
        index += 1;
    }
    result
}

fn whitespace_run_end(characters: &[char], from: usize) -> usize {
    let mut end = from;
    while end < characters.len() && is_pattern_whitespace(characters[end]) {
        end += 1;
    }
    end
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cjk_line_break_merges_without_a_space() {
        assert_eq!(
            smart_merge_lines("这是一个由于换行产生的\n句子被切断了。"),
            "这是一个由于换行产生的句子被切断了。"
        );
    }

    #[test]
    fn a_latin_line_break_merges_with_a_space() {
        assert_eq!(
            smart_merge_lines("This is a sentence that was\nbroken across lines."),
            "This is a sentence that was broken across lines."
        );
    }

    #[test]
    fn blank_lines_and_sentence_ends_keep_their_breaks() {
        assert_eq!(
            smart_merge_lines("第一段第一行。\n\n第二段第一行。\n第二段第二行。"),
            "第一段第一行。\n\n第二段第一行。\n第二段第二行。"
        );
    }

    #[test]
    fn list_items_keep_their_breaks() {
        assert_eq!(
            smart_merge_lines("说明如下：\n- 第一项内容\n- 第二项内容"),
            "说明如下：\n- 第一项内容\n- 第二项内容"
        );
        assert_eq!(
            smart_merge_lines("步骤\n1. 打开设置\n2) 选择语言"),
            "步骤\n1. 打开设置\n2) 选择语言"
        );
    }

    #[test]
    fn a_quoted_sentence_end_keeps_its_break() {
        assert_eq!(
            smart_merge_lines("他说“我知道了。”\n然后离开了。"),
            "他说“我知道了。”\n然后离开了。"
        );
    }

    #[test]
    fn crlf_input_is_normalized_before_merging() {
        assert_eq!(
            smart_merge_lines("这是一个由于换行产生的\r\n句子被切断了。"),
            "这是一个由于换行产生的句子被切断了。"
        );
    }

    #[test]
    fn a_trailing_variation_selector_still_reads_as_cjk() {
        assert_eq!(smart_merge_lines("漢\u{FE00}\n字"), "漢\u{FE00}字");
    }

    #[test]
    fn pangu_spacing_separates_cjk_from_latin_and_digits() {
        assert_eq!(
            apply_pangu_spacing("使用Polyglance进行OCR识别，准确率达到99.9%以上。"),
            "使用 Polyglance 进行 OCR 识别，准确率达到 99.9% 以上。"
        );
    }

    #[test]
    fn pangu_spacing_leaves_fullwidth_punctuation_alone() {
        assert_eq!(apply_pangu_spacing("识别，准确"), "识别，准确");
    }

    #[test]
    fn extraneous_spaces_between_cjk_are_removed() {
        assert_eq!(
            remove_extraneous_spaces("你 好 世 界 ， 这 是 一 段 测 试 。 Hello World!"),
            "你好世界，这是一段测试。Hello World!"
        );
    }

    #[test]
    fn removing_extraneous_spaces_keeps_latin_word_gaps() {
        assert_eq!(
            remove_extraneous_spaces("Hello World and 你 好"),
            "Hello World and 你好"
        );
    }

    #[test]
    fn smart_merge_mode_also_applies_pangu_spacing() {
        assert_eq!(
            format(
                "这是第一行具有OCR\n识别能力的文本。",
                TextFormattingMode::SmartMerge
            ),
            "这是第一行具有 OCR 识别能力的文本。"
        );
    }

    #[test]
    fn preserve_breaks_mode_only_applies_pangu_spacing() {
        assert_eq!(
            format("具有OCR\n识别能力", TextFormattingMode::PreserveBreaks),
            "具有 OCR\n识别能力"
        );
    }

    #[test]
    fn raw_mode_returns_the_input_untouched() {
        assert_eq!(
            format("具有OCR\n识别 能力", TextFormattingMode::Raw),
            "具有OCR\n识别 能力"
        );
    }

    #[test]
    fn every_mode_maps_empty_input_to_empty_output() {
        for raw in 0..=4 {
            assert_eq!(format("", TextFormattingMode::from_raw(raw)), "");
        }
    }

    #[test]
    fn an_unknown_raw_mode_falls_back_to_smart_merge() {
        assert_eq!(
            TextFormattingMode::from_raw(0),
            TextFormattingMode::SmartMerge
        );
        assert_eq!(TextFormattingMode::from_raw(3), TextFormattingMode::Raw);
        assert_eq!(
            TextFormattingMode::from_raw(9),
            TextFormattingMode::SmartMerge
        );
    }

    #[test]
    fn the_cjk_table_covers_fullwidth_punctuation_unlike_the_layout_table() {
        assert!(is_cjk('漢'));
        assert!(is_cjk('あ'));
        assert!(is_cjk('한'));
        assert!(is_cjk('，'));
        assert!(!is_cjk('a'));
        assert!(!is_cjk_script('，'));
    }

    #[test]
    fn hyphenation_is_rejoined() {
        assert_eq!(
            smart_merge_lines("inter-\naction between sys-\ntems"),
            "interaction between systems"
        );
    }

    #[test]
    fn cleans_inline_icon_artifacts() {
        assert_eq!(
            clean_icon_artifacts("•根因：S OCRWorkspacePanel.swift 在加载约束时早于"),
            "•根因：OCRWorkspacePanel.swift 在加载约束时早于"
        );
        assert_eq!(
            clean_icon_artifacts("S OCRWorkspacePanel.swift"),
            "OCRWorkspacePanel.swift"
        );
        assert_eq!(
            clean_icon_artifacts("• S OCRWorkspacePanel.swift"),
            "• OCRWorkspacePanel.swift"
        );
    }

    #[test]
    fn bullet_markers_keep_their_breaks() {
        assert_eq!(
            smart_merge_lines(
                "• 根因：OCRWorkspacePanel.swift 在加载约束时\n• 修复：将 loadingOverlay"
            ),
            "• 根因：OCRWorkspacePanel.swift 在加载约束时\n• 修复：将 loadingOverlay"
        );
    }
}
