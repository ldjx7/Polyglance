//! Cross-platform translation domain logic.

use serde::{Deserialize, Serialize};
use std::fmt;
use thiserror::Error;

pub const MAX_INPUT_CHARACTERS: usize = 20_000;

#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub struct LanguageCode(String);

impl LanguageCode {
    pub fn new(value: &str) -> Result<Self, TranslationError> {
        let value = value.trim();
        if value.is_empty() {
            return Err(TranslationError::InvalidLanguageCode);
        }

        let mut normalized_parts = Vec::new();
        for (index, part) in value.split('-').enumerate() {
            if part.is_empty()
                || !part
                    .chars()
                    .all(|character| character.is_ascii_alphanumeric())
            {
                return Err(TranslationError::InvalidLanguageCode);
            }

            let normalized = if index == 0 {
                part.to_ascii_lowercase()
            } else if part.len() == 2 {
                part.to_ascii_uppercase()
            } else if part.len() == 4 {
                let mut characters = part.chars();
                let first = characters.next().expect("a non-empty language component");
                format!(
                    "{}{}",
                    first.to_ascii_uppercase(),
                    characters.as_str().to_ascii_lowercase()
                )
            } else {
                part.to_ascii_lowercase()
            };
            normalized_parts.push(normalized);
        }

        Ok(Self(normalized_parts.join("-")))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for LanguageCode {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct TranslationRequest {
    text: String,
    source_language: Option<LanguageCode>,
    target_language: LanguageCode,
}

impl TranslationRequest {
    pub fn new(
        text: impl Into<String>,
        source_language: Option<&str>,
        target_language: &str,
    ) -> Result<Self, TranslationError> {
        let text = text.into().trim().to_owned();
        if text.is_empty() {
            return Err(TranslationError::EmptyText);
        }

        let character_count = text.chars().count();
        if character_count > MAX_INPUT_CHARACTERS {
            return Err(TranslationError::TextTooLong {
                max_characters: MAX_INPUT_CHARACTERS,
            });
        }

        let source_language = source_language.map(LanguageCode::new).transpose()?;
        let target_language = LanguageCode::new(target_language)?;

        Ok(Self {
            text,
            source_language,
            target_language,
        })
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn source_language(&self) -> Option<&LanguageCode> {
        self.source_language.as_ref()
    }

    pub fn target_language(&self) -> &LanguageCode {
        &self.target_language
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct TranslationResult {
    pub text: String,
    pub detected_language: Option<LanguageCode>,
    pub provider: String,
    pub elapsed_ms: u64,
}

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum TranslationError {
    #[error("text must not be empty")]
    EmptyText,
    #[error("text exceeds the {max_characters} character limit")]
    TextTooLong { max_characters: usize },
    #[error("language code is invalid")]
    InvalidLanguageCode,
}
