//! Swift-facing mirror of `translator_providers::streaming`.

use std::sync::Mutex;

use translator_providers::streaming;

#[derive(Clone, Debug, uniffi::Enum)]
pub enum StreamEventKind {
    None,
    Delta { text: String },
    Done,
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum StreamParseFailure {
    #[error("invalid response")]
    InvalidResponse,
    #[error("{message}")]
    Provider { message: String },
}

#[uniffi::export]
pub fn stream_event(line: String) -> Result<StreamEventKind, StreamParseFailure> {
    match streaming::stream_event(&line) {
        Ok(None) => Ok(StreamEventKind::None),
        Ok(Some(streaming::StreamEvent::Delta(text))) => Ok(StreamEventKind::Delta { text }),
        Ok(Some(streaming::StreamEvent::Done)) => Ok(StreamEventKind::Done),
        Err(streaming::StreamParseError::InvalidResponse) => {
            Err(StreamParseFailure::InvalidResponse)
        }
        Err(streaming::StreamParseError::Provider(message)) => {
            Err(StreamParseFailure::Provider { message })
        }
    }
}

#[uniffi::export]
pub fn stream_chat_completions_url(endpoint: String) -> String {
    streaming::chat_completions_url(&endpoint)
}

#[uniffi::export]
pub fn stream_request_body(
    model: String,
    text: String,
    source_language: Option<String>,
    target_language: String,
    deny_data_collection: bool,
) -> String {
    streaming::streaming_request_body(
        &model,
        &text,
        source_language.as_deref(),
        &target_language,
        deny_data_collection,
    )
}

#[derive(uniffi::Object)]
pub struct StreamEmissionPolicy {
    inner: Mutex<streaming::EmissionPolicy>,
}

#[uniffi::export]
impl StreamEmissionPolicy {
    #[uniffi::constructor]
    pub fn new(minimum_interval_nanoseconds: i64) -> Self {
        Self {
            inner: Mutex::new(streaming::EmissionPolicy::new(minimum_interval_nanoseconds)),
        }
    }

    pub fn should_emit(&self, elapsed_nanoseconds: i64, is_final: bool) -> bool {
        self.inner
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .should_emit(elapsed_nanoseconds, is_final)
    }
}
