//! Streaming (SSE) helpers for OpenAI-compatible chat completions.
//!
//! Only parsing, request shaping, and emission throttling live here; each
//! platform keeps its own HTTP transport.

use serde_json::{Value, json};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StreamEvent {
    Delta(String),
    Done,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StreamParseError {
    InvalidResponse,
    Provider(String),
}

/// Returns `None` for lines that carry no payload (comments, keep-alives).
pub fn stream_event(line: &str) -> Result<Option<StreamEvent>, StreamParseError> {
    let Some(payload) = line.strip_prefix("data:") else {
        return Ok(None);
    };
    let payload = payload.trim_matches(|character: char| character == ' ' || character == '\t');
    if payload.is_empty() {
        return Ok(None);
    }
    if payload == "[DONE]" {
        return Ok(Some(StreamEvent::Done));
    }

    let object: Value =
        serde_json::from_str(payload).map_err(|_| StreamParseError::InvalidResponse)?;
    if !object.is_object() {
        return Err(StreamParseError::InvalidResponse);
    }
    if let Some(message) = object
        .get("error")
        .and_then(|error| error.get("message"))
        .and_then(Value::as_str)
    {
        return Err(StreamParseError::Provider(message.to_owned()));
    }
    let content = object
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|choices| choices.first())
        .and_then(|choice| choice.get("delta"))
        .and_then(|delta| delta.get("content"))
        .and_then(Value::as_str);
    match content {
        Some(content) if !content.is_empty() => Ok(Some(StreamEvent::Delta(content.to_owned()))),
        _ => Ok(None),
    }
}

pub fn chat_completions_url(endpoint: &str) -> String {
    let trimmed = endpoint.trim_end_matches('/');
    if trimmed.ends_with("/chat/completions") {
        return trimmed.to_owned();
    }
    format!("{trimmed}/chat/completions")
}

/// The bundled free service is not OpenAI-shaped, so its path is appended
/// rather than `/chat/completions`.
pub fn free_translate_url(endpoint: &str) -> String {
    let trimmed = endpoint.trim_end_matches('/');
    if trimmed.ends_with("/api/free-translate") {
        return trimmed.to_owned();
    }
    if trimmed.ends_with("/api") {
        return format!("{trimmed}/free-translate");
    }
    format!("{trimmed}/api/free-translate")
}

/// Content and languages only.
///
/// No model, no sampling controls and no prompt: the Worker owns all three,
/// and accepting them from a client is what would make the endpoint abusable.
pub fn free_translate_request_body(
    text: &str,
    source_language: Option<&str>,
    target_language: &str,
) -> String {
    let mut body = json!({
        "text": text,
        "target": crate::free_ai::worker_language_code(target_language),
        "stream": true,
    });
    if let Some(source) = source_language {
        body["source"] = json!(crate::free_ai::worker_language_code(source));
    }
    body.to_string()
}

pub fn streaming_request_body(
    model: &str,
    text: &str,
    source_language: Option<&str>,
    target_language: &str,
    deny_data_collection: bool,
) -> String {
    let source_instruction = source_language
        .map(|language| format!(" from {language}"))
        .unwrap_or_else(|| " after detecting its language".to_owned());
    let system_prompt = format!(
        "Translate the user's text{source_instruction} to {target_language}. Return only the translated text, without explanations or quotation marks. Preserve paragraph and sentence boundaries where natural."
    );
    let mut body = json!({
        "model": model,
        "temperature": 0,
        "stream": true,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": text}
        ]
    });
    if deny_data_collection {
        body["provider"] = json!({"data_collection": "deny"});
    }
    body.to_string()
}

/// Collapses bursts of deltas so the UI repaints at a bounded rate.
#[derive(Clone, Copy, Debug)]
pub struct EmissionPolicy {
    minimum_interval_nanoseconds: i64,
    last_emission_nanoseconds: Option<i64>,
}

impl EmissionPolicy {
    pub fn new(minimum_interval_nanoseconds: i64) -> Self {
        Self {
            minimum_interval_nanoseconds: minimum_interval_nanoseconds.max(0),
            last_emission_nanoseconds: None,
        }
    }

    pub fn should_emit(&mut self, elapsed_nanoseconds: i64, is_final: bool) -> bool {
        if is_final {
            return true;
        }
        match self.last_emission_nanoseconds {
            None => {
                self.last_emission_nanoseconds = Some(elapsed_nanoseconds);
                true
            }
            Some(last) => {
                if elapsed_nanoseconds - last >= self.minimum_interval_nanoseconds {
                    self.last_emission_nanoseconds = Some(elapsed_nanoseconds);
                    true
                } else {
                    false
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_data_lines_are_ignored() {
        assert_eq!(stream_event(": keep-alive"), Ok(None));
        assert_eq!(stream_event(""), Ok(None));
        assert_eq!(stream_event("data:"), Ok(None));
        assert_eq!(stream_event("data:   "), Ok(None));
    }

    #[test]
    fn the_done_sentinel_ends_the_stream() {
        assert_eq!(stream_event("data: [DONE]"), Ok(Some(StreamEvent::Done)));
    }

    #[test]
    fn content_deltas_are_extracted() {
        let line = r#"data: {"choices":[{"delta":{"content":"你好"}}]}"#;

        assert_eq!(
            stream_event(line),
            Ok(Some(StreamEvent::Delta("你好".to_owned())))
        );
    }

    #[test]
    fn empty_or_absent_deltas_yield_nothing() {
        assert_eq!(
            stream_event(r#"data: {"choices":[{"delta":{"content":""}}]}"#),
            Ok(None)
        );
        assert_eq!(
            stream_event(r#"data: {"choices":[{"delta":{}}]}"#),
            Ok(None)
        );
        assert_eq!(stream_event(r#"data: {"choices":[]}"#), Ok(None));
    }

    #[test]
    fn provider_errors_surface_their_message() {
        let line = r#"data: {"error":{"message":"rate limited"}}"#;

        assert_eq!(
            stream_event(line),
            Err(StreamParseError::Provider("rate limited".to_owned()))
        );
    }

    #[test]
    fn malformed_json_is_reported_as_invalid() {
        assert_eq!(
            stream_event("data: {not json"),
            Err(StreamParseError::InvalidResponse)
        );
    }

    #[test]
    fn the_completions_path_is_appended_only_once() {
        assert_eq!(
            chat_completions_url("https://api.openai.com/v1"),
            "https://api.openai.com/v1/chat/completions"
        );
        assert_eq!(
            chat_completions_url("https://api.openai.com/v1/"),
            "https://api.openai.com/v1/chat/completions"
        );
        assert_eq!(
            chat_completions_url("https://api.openai.com/v1/chat/completions"),
            "https://api.openai.com/v1/chat/completions"
        );
    }

    #[test]
    fn the_free_translate_path_is_appended_only_once() {
        assert_eq!(
            free_translate_url("https://polyglance.example"),
            "https://polyglance.example/api/free-translate"
        );
        assert_eq!(
            free_translate_url("https://polyglance.example/"),
            "https://polyglance.example/api/free-translate"
        );
        assert_eq!(
            free_translate_url("https://polyglance.example/api"),
            "https://polyglance.example/api/free-translate"
        );
        assert_eq!(
            free_translate_url("https://polyglance.example/api/free-translate"),
            "https://polyglance.example/api/free-translate"
        );
    }

    #[test]
    fn the_free_translate_body_omits_the_model_and_the_prompt() {
        let body = free_translate_request_body("hi", Some("en"), "zh-CN");
        let value: Value = serde_json::from_str(&body).unwrap();

        assert_eq!(value["text"], json!("hi"));
        assert_eq!(value["target"], json!("zh-cn"));
        assert_eq!(value["source"], json!("en"));
        assert_eq!(value["stream"], json!(true));
        assert!(value.get("model").is_none());
        assert!(value.get("messages").is_none());
        assert!(value.get("temperature").is_none());
    }

    #[test]
    fn the_free_translate_body_normalizes_chinese_language_aliases() {
        let body = free_translate_request_body("你好", Some("zh-Hant"), "zh-Hans");
        let value: Value = serde_json::from_str(&body).unwrap();

        assert_eq!(value["target"], json!("zh-cn"));
        assert_eq!(value["source"], json!("zh-tw"));
    }

    #[test]
    fn the_free_translate_body_leaves_the_source_to_the_server_when_unknown() {
        let value: Value =
            serde_json::from_str(&free_translate_request_body("hi", None, "ja")).unwrap();

        assert!(value.get("source").is_none());
    }

    #[test]
    fn the_request_body_enables_streaming_and_pins_the_temperature() {
        let body = streaming_request_body("gpt-4.1-mini", "hi", None, "zh-CN", false);
        let value: Value = serde_json::from_str(&body).unwrap();

        assert_eq!(value["stream"], json!(true));
        assert_eq!(value["temperature"], json!(0));
        assert_eq!(value["model"], json!("gpt-4.1-mini"));
        assert_eq!(value["messages"][1]["content"], json!("hi"));
        assert!(value.get("provider").is_none());
    }

    #[test]
    fn the_source_language_changes_the_instruction() {
        let detected = streaming_request_body("m", "hi", None, "zh-CN", false);
        let explicit = streaming_request_body("m", "hi", Some("en"), "zh-CN", false);

        assert!(detected.contains("after detecting its language"));
        assert!(explicit.contains("from en"));
    }

    #[test]
    fn data_collection_can_be_denied() {
        let body = streaming_request_body("m", "hi", None, "zh-CN", true);
        let value: Value = serde_json::from_str(&body).unwrap();

        assert_eq!(value["provider"]["data_collection"], json!("deny"));
    }

    #[test]
    fn the_first_delta_always_emits_and_bursts_are_collapsed() {
        let mut policy = EmissionPolicy::new(40_000_000);

        assert!(policy.should_emit(0, false));
        assert!(!policy.should_emit(10_000_000, false));
        assert!(policy.should_emit(40_000_000, false));
        assert!(!policy.should_emit(50_000_000, false));
    }

    #[test]
    fn the_final_delta_always_emits() {
        let mut policy = EmissionPolicy::new(40_000_000);
        policy.should_emit(0, false);

        assert!(policy.should_emit(1, true));
    }

    #[test]
    fn a_negative_interval_is_treated_as_zero() {
        let mut policy = EmissionPolicy::new(-5);

        assert!(policy.should_emit(0, false));
        assert!(policy.should_emit(0, false));
    }
}
