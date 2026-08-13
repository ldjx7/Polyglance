use translator_core::{LanguageCode, TranslationError, TranslationRequest};

#[test]
fn trims_text_and_language_codes() {
    let request = TranslationRequest::new("  Hello, world.  ", Some(" EN "), " zh-CN ")
        .expect("valid request");

    assert_eq!(request.text(), "Hello, world.");
    assert_eq!(
        request.source_language(),
        Some(&LanguageCode::new("en").unwrap())
    );
    assert_eq!(
        request.target_language(),
        &LanguageCode::new("zh-CN").unwrap()
    );
}

#[test]
fn rejects_blank_text() {
    let error = TranslationRequest::new(" \n\t ", None, "zh-CN").unwrap_err();

    assert_eq!(error, TranslationError::EmptyText);
}

#[test]
fn rejects_blank_target_language() {
    let error = TranslationRequest::new("hello", None, "  ").unwrap_err();

    assert_eq!(error, TranslationError::InvalidLanguageCode);
}

#[test]
fn rejects_text_above_the_limit() {
    let oversized = "a".repeat(20_001);
    let error = TranslationRequest::new(oversized, None, "zh-CN").unwrap_err();

    assert_eq!(
        error,
        TranslationError::TextTooLong {
            max_characters: 20_000
        }
    );
}
