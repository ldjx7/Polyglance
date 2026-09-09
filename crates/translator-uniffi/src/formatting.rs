//! Swift-facing mirror of `capture_core::formatting`.

use capture_core::formatting;

/// The raw value is what the frontends persist, so it stays the wire format.
#[uniffi::export]
pub fn text_format(text: String, mode: u8) -> String {
    formatting::format(&text, formatting::TextFormattingMode::from_raw(mode))
}

#[uniffi::export]
pub fn text_smart_merge_lines(text: String) -> String {
    formatting::smart_merge_lines(&text)
}

#[uniffi::export]
pub fn text_apply_pangu_spacing(text: String) -> String {
    formatting::apply_pangu_spacing(&text)
}

#[uniffi::export]
pub fn text_remove_extraneous_spaces(text: String) -> String {
    formatting::remove_extraneous_spaces(&text)
}

/// Takes a scalar value because UniFFI has no `char` type; frontends pass the
/// first scalar of the grapheme cluster they are inspecting.
#[uniffi::export]
pub fn text_is_cjk_scalar(scalar: u32) -> bool {
    char::from_u32(scalar).is_some_and(formatting::is_cjk)
}
