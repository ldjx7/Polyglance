use reqwest::Url;
use serde::Serialize;
use serde_json::Value;
use std::time::{Duration, Instant};
use translator_core::{LanguageCode, TranslationRequest, TranslationResult};

use crate::SharedHttpClient;
use crate::openai::{ProviderError, is_loopback_host, map_status_error};
use crate::shared_http_client;

const DEFAULT_ENDPOINT: &str =
    "https://translate.googleapis.com/translate_a/single?client=gtx&dt=t";
const DEFAULT_TIMEOUT_SECONDS: u64 = 30;

#[derive(Clone, Debug)]
pub struct GoogleConfig {
    endpoint: Url,
}

impl GoogleConfig {
    pub fn new() -> Result<Self, ProviderError> {
        Self::with_endpoint(DEFAULT_ENDPOINT)
    }

    pub fn with_endpoint(endpoint: impl AsRef<str>) -> Result<Self, ProviderError> {
        let endpoint = validate_endpoint(endpoint.as_ref())?;
        Ok(Self { endpoint })
    }
}

#[derive(Clone)]
pub struct GoogleProvider {
    client: SharedHttpClient,
    config: GoogleConfig,
}

impl GoogleProvider {
    pub fn new(config: GoogleConfig) -> Result<Self, ProviderError> {
        let client = shared_http_client()?;
        Ok(Self { client, config })
    }

    pub async fn translate(
        &self,
        request: &TranslationRequest,
    ) -> Result<TranslationResult, ProviderError> {
        let body = GoogleTranslationRequest {
            sl: request
                .source_language()
                .map(LanguageCode::as_str)
                .unwrap_or("auto"),
            tl: request.target_language().as_str(),
            q: request.text(),
        };
        let started_at = Instant::now();
        let response = self
            .client
            .post(self.config.endpoint.clone())
            .timeout(Duration::from_secs(DEFAULT_TIMEOUT_SECONDS))
            .form(&body)
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
            detected_language: parsed
                .detected_language
                .as_deref()
                .and_then(|language| LanguageCode::new(language).ok()),
            provider: "google".to_owned(),
            elapsed_ms: started_at.elapsed().as_millis() as u64,
        })
    }
}

#[derive(Debug, Eq, PartialEq)]
pub struct ParsedTranslation {
    pub text: String,
    pub detected_language: Option<String>,
}

pub fn parse_response_body(body: &str) -> Result<ParsedTranslation, ProviderError> {
    let response: Value = serde_json::from_str(body)
        .map_err(|error| ProviderError::InvalidResponse(error.to_string()))?;
    let segments = response
        .get(0)
        .and_then(Value::as_array)
        .ok_or_else(missing_translation)?;
    let joined = segments
        .iter()
        .filter_map(|segment| segment.get(0).and_then(Value::as_str))
        .collect::<String>();
    let text = html_escape::decode_html_entities(&joined).trim().to_owned();
    if text.is_empty() {
        return Err(missing_translation());
    }
    Ok(ParsedTranslation {
        text,
        detected_language: response
            .get(2)
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
    })
}

fn missing_translation() -> ProviderError {
    ProviderError::InvalidResponse("response does not contain translated text".to_owned())
}

fn validate_endpoint(raw_endpoint: &str) -> Result<Url, ProviderError> {
    let endpoint = Url::parse(raw_endpoint.trim())
        .map_err(|error| ProviderError::InvalidConfig(format!("endpoint is invalid: {error}")))?;
    if endpoint.scheme() != "https" && !(endpoint.scheme() == "http" && is_loopback_host(&endpoint))
    {
        return Err(ProviderError::InvalidConfig(
            "endpoint must use HTTPS unless it targets a loopback service".to_owned(),
        ));
    }
    Ok(endpoint)
}

#[derive(Serialize)]
struct GoogleTranslationRequest<'a> {
    sl: &'a str,
    tl: &'a str,
    q: &'a str,
}
