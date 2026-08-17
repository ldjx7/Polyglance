use reqwest::{StatusCode, Url};
use serde::Deserialize;
use serde_json::{Value, json};
use std::net::IpAddr;
use std::time::{Duration, Instant};
use translator_core::{TranslationRequest, TranslationResult};

use crate::SharedHttpClient;
use crate::shared_http_client;

const DEFAULT_TIMEOUT_SECONDS: u64 = 45;

#[derive(Clone, Debug)]
pub struct OpenAiCompatibleConfig {
    endpoint: Url,
    api_key: String,
    model: String,
    deny_data_collection: bool,
}

impl OpenAiCompatibleConfig {
    pub fn new(
        endpoint: impl AsRef<str>,
        api_key: impl Into<String>,
        model: impl Into<String>,
    ) -> Result<Self, ProviderError> {
        let api_key = api_key.into().trim().to_owned();
        if api_key.is_empty() {
            return Err(ProviderError::InvalidConfig(
                "API key must not be empty".to_owned(),
            ));
        }

        let model = model.into().trim().to_owned();
        if model.is_empty() {
            return Err(ProviderError::InvalidConfig(
                "model must not be empty".to_owned(),
            ));
        }

        let mut endpoint = Url::parse(endpoint.as_ref().trim()).map_err(|error| {
            ProviderError::InvalidConfig(format!("endpoint is invalid: {error}"))
        })?;
        let is_loopback_http = endpoint.scheme() == "http" && is_loopback_host(&endpoint);
        if endpoint.scheme() != "https" && !is_loopback_http {
            return Err(ProviderError::InvalidConfig(
                "endpoint must use HTTPS unless it targets a loopback service".to_owned(),
            ));
        }

        let normalized_path = endpoint.path().trim_end_matches('/').to_owned();
        endpoint.set_path(&normalized_path);

        Ok(Self {
            endpoint,
            api_key,
            model,
            deny_data_collection: false,
        })
    }

    pub fn denying_data_collection(mut self) -> Self {
        self.deny_data_collection = true;
        self
    }

    fn chat_completions_url(&self) -> Result<Url, ProviderError> {
        if self.endpoint.path().ends_with("/chat/completions") {
            return Ok(self.endpoint.clone());
        }

        let path = format!(
            "{}/chat/completions",
            self.endpoint.path().trim_end_matches('/')
        );
        let mut url = self.endpoint.clone();
        url.set_path(&path);
        Ok(url)
    }
}

pub(crate) fn is_loopback_host(url: &Url) -> bool {
    let Some(host) = url.host_str() else {
        return false;
    };
    host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<IpAddr>()
            .is_ok_and(|address| address.is_loopback())
}

#[derive(Clone)]
pub struct OpenAiCompatibleProvider {
    client: SharedHttpClient,
    config: OpenAiCompatibleConfig,
}

impl OpenAiCompatibleProvider {
    pub fn new(config: OpenAiCompatibleConfig) -> Result<Self, ProviderError> {
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
            .post(self.config.chat_completions_url()?)
            .timeout(Duration::from_secs(DEFAULT_TIMEOUT_SECONDS))
            .bearer_auth(&self.config.api_key)
            .json(&build_request_body(&self.config, request))
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
            provider: "openai-compatible".to_owned(),
            elapsed_ms: started_at.elapsed().as_millis() as u64,
        })
    }
}

pub fn build_request_body(config: &OpenAiCompatibleConfig, request: &TranslationRequest) -> Value {
    let source_instruction = request
        .source_language()
        .map(|language| format!(" from {language}"))
        .unwrap_or_else(|| " after detecting its language".to_owned());
    let system_prompt = format!(
        "Translate the user's text{source_instruction} to {}. Return only the translated text, without explanations or quotation marks.",
        request.target_language()
    );

    let mut body = json!({
        "model": config.model,
        "temperature": 0,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": request.text()}
        ]
    });
    if config.deny_data_collection {
        body["provider"] = json!({"data_collection": "deny"});
    }
    body
}

#[derive(Debug, Eq, PartialEq)]
pub struct ParsedTranslation {
    pub text: String,
}

pub fn parse_response_body(body: &str) -> Result<ParsedTranslation, ProviderError> {
    let response: ChatCompletionResponse = serde_json::from_str(body)
        .map_err(|error| ProviderError::InvalidResponse(error.to_string()))?;
    let text = response
        .choices
        .into_iter()
        .next()
        .map(|choice| choice.message.content.trim().to_owned())
        .filter(|content| !content.is_empty())
        .ok_or_else(|| {
            ProviderError::InvalidResponse("response does not contain translated text".to_owned())
        })?;

    Ok(ParsedTranslation { text })
}

pub(crate) fn map_status_error(status: StatusCode, body: &str) -> ProviderError {
    let message = extract_api_error(body).unwrap_or_else(|| status.to_string());
    match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => ProviderError::Authentication(message),
        StatusCode::TOO_MANY_REQUESTS => ProviderError::RateLimited(message),
        _ => ProviderError::Server {
            status: status.as_u16(),
            message,
        },
    }
}

fn extract_api_error(body: &str) -> Option<String> {
    let value: Value = serde_json::from_str(body).ok()?;
    value["error"]["message"].as_str().map(ToOwned::to_owned)
}

#[derive(Debug, Deserialize)]
struct ChatCompletionResponse {
    choices: Vec<Choice>,
}

#[derive(Debug, Deserialize)]
struct Choice {
    message: Message,
}

#[derive(Debug, Deserialize)]
struct Message {
    content: String,
}

#[derive(Debug, thiserror::Error)]
pub enum ProviderError {
    #[error("invalid translation request: {0}")]
    InvalidRequest(String),
    #[error("invalid provider configuration: {0}")]
    InvalidConfig(String),
    #[error("network request failed: {0}")]
    Network(String),
    #[error("authentication failed: {0}")]
    Authentication(String),
    #[error("provider rate limit reached: {0}")]
    RateLimited(String),
    #[error("provider returned HTTP {status}: {message}")]
    Server { status: u16, message: String },
    #[error("provider response is invalid: {0}")]
    InvalidResponse(String),
}
