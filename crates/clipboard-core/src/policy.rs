use super::*;
use regex_lite::RegexBuilder;

fn expression(pattern: &str) -> Result<regex_lite::Regex, Error> {
    if pattern.is_empty() || pattern.len() > 512 {
        return Err(Error::InvalidPattern);
    }
    RegexBuilder::new(pattern)
        .size_limit(256 * 1024)
        .build()
        .map_err(|_| Error::InvalidPattern)
}

pub fn validate_ignored_patterns(patterns: &[String]) -> Result<(), Error> {
    if patterns.len() > 32 {
        return Err(Error::InvalidPattern);
    }
    for pattern in patterns {
        expression(pattern)?;
    }
    Ok(())
}

pub(crate) fn excluded_text(patterns: &[String], items: &[ClipboardItem]) -> Result<bool, Error> {
    validate_ignored_patterns(patterns)?;
    for pattern in patterns {
        let regex = expression(pattern)?;
        for item in items {
            for representation in &item.representations {
                if representation.format == "text/plain" {
                    let text = std::str::from_utf8(&representation.bytes)
                        .map_err(|_| Error::InvalidInput)?;
                    if regex.is_match(text) {
                        return Ok(true);
                    }
                }
            }
        }
    }
    Ok(false)
}

/// Command-letter keys reserved by editing, window management and history search are excluded.
pub fn validate_pin_shortcut(key: &str) -> Result<String, Error> {
    let key = key.trim().to_ascii_lowercase();
    if key.is_empty() || (key.len() == 1 && "bdegijklrtuy".contains(&key)) {
        Ok(key)
    } else {
        Err(Error::InvalidInput)
    }
}
