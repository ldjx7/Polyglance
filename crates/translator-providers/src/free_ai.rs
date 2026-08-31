//! The bundled free AI translation service.
//!
//! This is the project's own Cloudflare Worker, and it deliberately does *not*
//! speak the OpenAI protocol. A client sends the text plus two language codes
//! and nothing else; the Worker owns the model, the system prompt and the
//! upstream credential.
//!
//! Keeping the client ignorant of those three things is the point. It means a
//! reverse-engineered binary yields a URL that can only be used to translate
//! text: there is no credential to steal, no `model` field to escalate to a
//! paid model, and no `messages` array to turn the endpoint into a general
//! chatbot.

use reqwest::Url;
use serde_json::{Value, json};
use std::time::{Duration, Instant};
use translator_core::{TranslationRequest, TranslationResult};

use crate::SharedHttpClient;
use crate::openai::{ProviderError, map_status_error, parse_response_body};
use crate::shared_http_client;

pub const DEFAULT_FREE_AI_ENDPOINT: &str = "https://polyglance.ldjx7.dpdns.org/api/free-translate";

const DEFAULT_TIMEOUT_SECONDS: u64 = 45;

/// A resolved connection to the bundled service.
///
/// Unlike [`crate::openai::OpenAiCompatibleConfig`] there is no API key and no
/// model: the public Worker limits the request shape and picks the model itself.
/// It does not pretend that a desktop binary can authenticate anonymously;
/// abuse is bounded by server-side quotas and the upstream key's own ceiling.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FreeAiConfig {
    endpoint: Url,
}

impl FreeAiConfig {
    pub fn new(endpoint: impl AsRef<str>) -> Result<Self, ProviderError> {
        let endpoint = Url::parse(endpoint.as_ref().trim()).map_err(|error| {
            ProviderError::InvalidConfig(format!("free AI endpoint is invalid: {error}"))
        })?;
        if endpoint.scheme() != "https" {
            return Err(ProviderError::InvalidConfig(
                "free AI endpoint must use HTTPS".to_owned(),
            ));
        }

        Ok(Self { endpoint })
    }

    pub fn default_endpoint() -> Result<Self, ProviderError> {
        Self::new(DEFAULT_FREE_AI_ENDPOINT)
    }

    pub fn endpoint(&self) -> &Url {
        &self.endpoint
    }
}

#[derive(Clone)]
pub struct FreeAiProvider {
    client: SharedHttpClient,
    config: FreeAiConfig,
}

impl FreeAiProvider {
    pub fn new(config: FreeAiConfig) -> Result<Self, ProviderError> {
        let client = shared_http_client()?;
        Ok(Self { client, config })
    }

    pub async fn translate(
        &self,
        request: &TranslationRequest,
    ) -> Result<TranslationResult, ProviderError> {
        let started_at = Instant::now();
        let response = self
            .client
            .post(self.config.endpoint().clone())
            .timeout(Duration::from_secs(DEFAULT_TIMEOUT_SECONDS))
            .json(&request_body(request, false))
            .send()
            .await
            .map_err(|error| ProviderError::Network(error.to_string()))?;

        let status = response.status();
        let body = response
            .text()
            .await
            .map_err(|error| ProviderError::Network(error.to_string()))?;

        if !status.is_success() {
            return Err(map_status_error(status, &body));
        }

        let parsed = parse_response_body(&body)?;
        Ok(TranslationResult {
            text: parsed.text,
            detected_language: None,
            provider: "free-ai".to_owned(),
            elapsed_ms: started_at.elapsed().as_millis() as u64,
        })
    }
}

/// The entire request surface: content and languages, never a model or prompt.
pub fn request_body(request: &TranslationRequest, stream: bool) -> Value {
    let mut body = json!({
        "text": request.text(),
        "target": worker_language_code(request.target_language().as_str()),
        "stream": stream,
    });
    if let Some(source) = request.source_language() {
        body["source"] = json!(worker_language_code(source.as_str()));
    }
    body
}

/// Converts desktop language identifiers to the deliberately small language
/// vocabulary accepted by the bundled Worker.
///
/// Windows uses the BCP-47 script aliases (`zh-Hans`/`zh-Hant`) in its UI,
/// while the public endpoint accepts region aliases (`zh-cn`/`zh-tw`). Keep
/// this at the provider boundary so every native client and both streaming
/// paths send the same request shape.
pub(crate) fn worker_language_code(language: &str) -> String {
    let normalized = language.trim().to_ascii_lowercase();
    match normalized.as_str() {
        "zh" | "zh-cn" | "zh-hans" | "zh-hans-cn" => "zh-cn".to_owned(),
        "zh-tw" | "zh-hant" | "zh-hant-tw" => "zh-tw".to_owned(),
        _ => normalized,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> TranslationRequest {
        TranslationRequest::new("hello", Some("en"), "zh-CN").expect("a valid request")
    }

    #[test]
    fn the_body_carries_content_and_nothing_else() {
        let body = request_body(&request(), false);
        let object = body.as_object().expect("a JSON object");

        assert_eq!(body["text"], json!("hello"));
        assert_eq!(body["target"], json!("zh-cn"));
        assert_eq!(body["source"], json!("en"));
        assert_eq!(body["stream"], json!(false));
        assert!(
            !object.contains_key("model"),
            "the model belongs to the server"
        );
        assert!(
            !object.contains_key("messages"),
            "the prompt belongs to the server"
        );
        assert!(
            !object.contains_key("temperature"),
            "sampling belongs to the server"
        );
    }

    #[test]
    fn worker_language_aliases_are_normalized_before_sending() {
        let request =
            TranslationRequest::new("hello", Some("zh-Hant"), "zh-Hans").expect("a valid request");
        let body = request_body(&request, false);

        assert_eq!(body["target"], json!("zh-cn"));
        assert_eq!(body["source"], json!("zh-tw"));
    }

    #[test]
    fn the_source_language_is_omitted_when_it_must_be_detected() {
        let request = TranslationRequest::new("hello", None, "zh-CN").expect("a valid request");

        assert!(request_body(&request, false).get("source").is_none());
    }

    #[test]
    fn streaming_is_the_only_switchable_field() {
        assert_eq!(request_body(&request(), true)["stream"], json!(true));
    }

    #[test]
    fn the_default_endpoint_is_encrypted_and_project_owned() {
        let config = FreeAiConfig::default_endpoint().expect("a valid default");

        assert_eq!(config.endpoint().scheme(), "https");
        assert!(config.endpoint().as_str().ends_with("/api/free-translate"));
    }

    #[test]
    fn an_unencrypted_endpoint_is_refused() {
        assert!(FreeAiConfig::new("http://example.test/api/free-translate").is_err());
    }
}
