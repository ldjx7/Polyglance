//! Text predicates shared across modules, matching Foundation's behaviour.

/// `CharacterSet.whitespacesAndNewlines`, which unlike the Unicode
/// `White_Space` property also contains U+200B.
pub fn is_foundation_whitespace_unit(unit: u16) -> bool {
    matches!(
        unit,
        0x0009..=0x000D
            | 0x0020
            | 0x0085
            | 0x00A0
            | 0x1680
            | 0x2000..=0x200B
            | 0x2028
            | 0x2029
            | 0x202F
            | 0x205F
            | 0x3000
    )
}

pub fn is_foundation_whitespace(character: char) -> bool {
    let value = character as u32;
    value <= 0xFFFF && is_foundation_whitespace_unit(value as u16)
}

pub fn trim_foundation_whitespace(text: &str) -> &str {
    text.trim_matches(is_foundation_whitespace)
}

pub fn is_cjk(character: char) -> bool {
    matches!(
        character as u32,
        0x2E80..=0x303F
            | 0x3040..=0x30FF
            | 0x3400..=0x4DBF
            | 0x4E00..=0x9FFF
            | 0xAC00..=0xD7AF
            | 0xF900..=0xFAFF
            | 0xFF00..=0xFF60
    )
}

/// Swift compares `Character` values, so the last grapheme cluster's *base*
/// scalar decides CJK-ness. Walking back over combining marks and variation
/// selectors reproduces that without a segmentation table.
pub fn last_base_scalar(text: &str) -> Option<char> {
    let mut candidate = None;
    for character in text.chars().rev() {
        candidate = Some(character);
        if !is_grapheme_extend(character) {
            break;
        }
    }
    candidate
}

fn is_grapheme_extend(character: char) -> bool {
    matches!(
        character as u32,
        0x0300..=0x036F
            | 0x1AB0..=0x1AFF
            | 0x1DC0..=0x1DFF
            | 0x200D
            | 0x20D0..=0x20FF
            | 0xFE00..=0xFE0F
            | 0xFE20..=0xFE2F
            | 0xE0100..=0xE01EF
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_width_space_counts_as_whitespace() {
        assert!(is_foundation_whitespace('\u{200B}'));
        assert!(is_foundation_whitespace(' '));
        assert!(is_foundation_whitespace('\n'));
        assert!(!is_foundation_whitespace('a'));
    }

    #[test]
    fn trimming_strips_foundation_whitespace_from_both_ends() {
        assert_eq!(trim_foundation_whitespace("\u{200B} hi \n"), "hi");
        assert_eq!(trim_foundation_whitespace("hi"), "hi");
        assert_eq!(trim_foundation_whitespace("  "), "");
    }

    #[test]
    fn cjk_ranges_cover_han_kana_and_fullwidth_forms() {
        assert!(is_cjk('漢'));
        assert!(is_cjk('あ'));
        assert!(is_cjk('한'));
        assert!(is_cjk('，'));
        assert!(!is_cjk('a'));
    }

    #[test]
    fn variation_selectors_do_not_hide_the_base_character() {
        assert_eq!(last_base_scalar("漢\u{FE00}"), Some('漢'));
        assert_eq!(last_base_scalar("e\u{0301}"), Some('e'));
        assert_eq!(last_base_scalar("ab"), Some('b'));
        assert_eq!(last_base_scalar(""), None);
    }
}
