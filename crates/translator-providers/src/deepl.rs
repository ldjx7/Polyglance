use reqwest::Url;
use serde::Deserialize;
use std::time::{Duration, Instant};
use translator_core::{LanguageCode, TranslationRequest, TranslationResult};

use crate::SharedHttpClient;
use crate::openai::{ProviderError, is_loopback_host, map_status_error};
use crate::shared_http_client;

const DEFAULT_FREE_ENDPOINT: &str = "https://api-free.deepl.com/v2/translate";
const DEFAULT_PRO_ENDPOINT: &str = "https://api.deepl.com/v2/translate";
const DEFAULT_TIMEOUT_SECONDS: u64 = 30;

#[derive(Clone, Debug)]
pub struct DeepLConfig {
    endpoint: Url,
    api_key: String,
}

impl DeepLConfig {
    pub fn new(endpoint: impl AsRef<str>, api_key: impl AsRef<str>) -> Result<Self, ProviderError> {
        let key = api_key.as_ref().trim();
        if key.is_empty() {
            return Err(ProviderError::InvalidConfig(
                "未配置 DeepL Auth Key，请在偏好设置中填写".to_string(),
            ));
        }

        let ep = endpoint.as_ref().trim();
        let default_url = if key.ends_with(":fx") {
            DEFAULT_FREE_ENDPOINT
        } else {
            DEFAULT_PRO_ENDPOINT
        };

        let target_url = if ep.is_empty() { default_url } else { ep };
        let parsed = Url::parse(target_url)
            .map_err(|e| ProviderError::InvalidConfig(format!("DeepL endpoint is invalid: {e}")))?;

        if parsed.scheme() != "https" && !is_loopback_host(&parsed) {
            return Err(ProviderError::InvalidConfig(
                "DeepL endpoint must use HTTPS or loopback".to_string(),
            ));
        }

        Ok(Self {
            endpoint: parsed,
            api_key: key.to_string(),
        })
    }
}

#[derive(Clone)]
pub struct DeepLProvider {
    client: SharedHttpClient,
    config: DeepLConfig,
}

fn map_language_for_deepl(code: &str) -> &str {
    match code {
        "zh-Hans" | "zh-Hans-CN" | "zh-CN" | "zh" => "ZH",
        "zh-Hant" | "zh-TW" | "zh-HK" => "ZH-HANT",
        "en" | "en-US" | "en-GB" => "EN",
        "ja" => "JA",
        "ko" => "KO",
        "fr" => "FR",
        "de" => "DE",
        "es" => "ES",
        "ru" => "RU",
        "it" => "IT",
        "pt" => "PT",
        other => other,
    }
}

#[derive(Deserialize)]
struct DeepLTranslationItem {
    detected_source_language: Option<String>,
    text: String,
}

#[derive(Deserialize)]
struct DeepLResponse {
    translations: Vec<DeepLTranslationItem>,
}

impl DeepLProvider {
    pub fn new(config: DeepLConfig) -> Result<Self, ProviderError> {
        let client = shared_http_client()?;
        Ok(Self { client, config })
    }

    pub async fn translate(
        &self,
        request: &TranslationRequest,
    ) -> Result<TranslationResult, ProviderError> {
        let started_at = Instant::now();
        let target_lang = map_language_for_deepl(request.target_language().as_str());

        let mut form = vec![
            ("text", request.text().to_string()),
            ("target_lang", target_lang.to_string()),
        ];

        if let Some(src) = request.source_language() {
            let src_str = map_language_for_deepl(src.as_str());
            if !src_str.is_empty() && src_str != "auto" {
                form.push(("source_lang", src_str.to_string()));
            }
        }

        let response = self
            .client
            .post(self.config.endpoint.clone())
            .header(
                "Authorization",
                format!("DeepL-Auth-Key {}", self.config.api_key),
            )
            .form(&form)
            .timeout(Duration::from_secs(DEFAULT_TIMEOUT_SECONDS))
            .send()
            .await
            .map_err(|e| ProviderError::Network(e.to_string()))?;

        let status = response.status();
        if !status.is_success() {
            return Err(match status.as_u16() {
                403 => {
                    ProviderError::Authentication("DeepL 认证失败，请检查 Auth Key 是否有效".into())
                }
                456 => ProviderError::RateLimited("DeepL 翻译额度已用尽 (Quota Exceeded)".into()),
                429 => ProviderError::RateLimited("DeepL 请求频次过高，请稍后再试".into()),
                _ => map_status_error(status, "DeepL"),
            });
        }

        let body = response
            .text()
            .await
            .map_err(|e| ProviderError::Network(e.to_string()))?;
        let parsed: DeepLResponse = serde_json::from_str(&body).map_err(|e| {
            ProviderError::InvalidResponse(format!("failed to parse DeepL response: {e}"))
        })?;

        let first = parsed
            .translations
            .into_iter()
            .next()
            .ok_or_else(|| ProviderError::InvalidResponse("DeepL 返回的译文列表为空".into()))?;

        let detected = first
            .detected_source_language
            .and_then(|l| LanguageCode::new(&l.to_lowercase()).ok());

        Ok(TranslationResult {
            text: first.text,
            detected_language: detected,
            provider: "deepl".to_string(),
            elapsed_ms: started_at.elapsed().as_millis() as u64,
        })
    }
}
