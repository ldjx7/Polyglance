use reqwest::Url;
use serde::Deserialize;
use std::time::{Duration, Instant};
use translator_core::{LanguageCode, TranslationRequest, TranslationResult};

use crate::SharedHttpClient;
use crate::openai::{ProviderError, is_loopback_host, map_status_error};
use crate::shared_http_client;

const DEFAULT_ENDPOINT: &str = "https://edge.microsoft.com/translate/translatetext";
const DEFAULT_TIMEOUT_SECONDS: u64 = 30;

#[derive(Clone, Debug)]
pub struct MicrosoftConfig {
    endpoint: Url,
}

impl MicrosoftConfig {
    pub fn new() -> Result<Self, ProviderError> {
        Self::with_endpoint(DEFAULT_ENDPOINT)
    }

    pub fn with_endpoint(endpoint: impl AsRef<str>) -> Result<Self, ProviderError> {
        let endpoint = validate_endpoint(endpoint.as_ref())?;
        Ok(Self { endpoint })
    }
}

#[derive(Clone)]
pub struct MicrosoftProvider {
    client: SharedHttpClient,
    config: MicrosoftConfig,
}

impl MicrosoftProvider {
    pub fn new(config: MicrosoftConfig) -> Result<Self, ProviderError> {
        let client = shared_http_client()?;
        Ok(Self { client, config })
    }

    pub async fn translate(
        &self,
        request: &TranslationRequest,
    ) -> Result<TranslationResult, ProviderError> {
        let mut url = self.config.endpoint.clone();
        url.query_pairs_mut()
            .append_pair(
                "to",
                &microsoft_language(request.target_language().as_str()),
            )
            .append_pair("isEnterpriseClient", "false");
        if let Some(source) = request.source_language() {
            url.query_pairs_mut()
                .append_pair("from", &microsoft_language(source.as_str()));
        }
        let request_builder = self
            .client
            .post(url)
            .timeout(Duration::from_secs(DEFAULT_TIMEOUT_SECONDS))
            .header("Accept", "*/*")
            .json(&[request.text()]);

        let started_at = Instant::now();
        let response = request_builder
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
            provider: "microsoft".to_owned(),
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
    let responses: Vec<MicrosoftTranslationResponse> = serde_json::from_str(body)
        .map_err(|error| ProviderError::InvalidResponse(error.to_string()))?;
    let response = responses.into_iter().next().ok_or_else(|| {
        ProviderError::InvalidResponse("response does not contain translated text".to_owned())
    })?;
    let text = response
        .translations
        .into_iter()
        .next()
        .map(|translation| translation.text.trim().to_owned())
        .filter(|text| !text.is_empty())
        .ok_or_else(|| {
            ProviderError::InvalidResponse("response does not contain translated text".to_owned())
        })?;
    Ok(ParsedTranslation {
        text,
        detected_language: response.detected_language.map(|language| language.language),
    })
}

fn microsoft_language(language: &str) -> String {
    match language {
        "zh-CN" => "zh-Hans".to_owned(),
        "zh-TW" => "zh-Hant".to_owned(),
        _ => language.to_owned(),
    }
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

#[derive(Deserialize)]
struct MicrosoftTranslationResponse {
    #[serde(rename = "detectedLanguage")]
    detected_language: Option<MicrosoftDetectedLanguage>,
    translations: Vec<MicrosoftTranslation>,
}

#[derive(Deserialize)]
struct MicrosoftDetectedLanguage {
    language: String,
}

#[derive(Deserialize)]
struct MicrosoftTranslation {
    text: String,
}
