use reqwest::Url;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use translator_core::{TranslationRequest, TranslationResult};

use crate::SharedHttpClient;
use crate::openai::{ProviderError, is_loopback_host, map_status_error};
use crate::shared_http_client;

const DEFAULT_ENDPOINT: &str = "https://openapi.youdao.com/api";
const DEFAULT_TIMEOUT_SECONDS: u64 = 30;

#[derive(Clone, Debug)]
pub struct YoudaoConfig {
    endpoint: Url,
    app_key: String,
    app_secret: String,
}

impl YoudaoConfig {
    pub fn new(
        endpoint: impl AsRef<str>,
        credentials: impl AsRef<str>,
    ) -> Result<Self, ProviderError> {
        let creds = credentials.as_ref().trim();
        let (app_key, app_secret) = match creds.split_once(':') {
            Some((k, s)) => (k.trim().to_string(), s.trim().to_string()),
            None => {
                return Err(ProviderError::InvalidConfig(
                    "有道翻译凭证格式需为 AppKey:密钥，请在偏好设置中填写完整".to_string(),
                ));
            }
        };

        if app_key.is_empty() || app_secret.is_empty() {
            return Err(ProviderError::InvalidConfig(
                "有道翻译 AppKey 或密钥为空，请在偏好设置中填写完整".to_string(),
            ));
        }

        let ep = endpoint.as_ref().trim();
        let target_url = if ep.is_empty() { DEFAULT_ENDPOINT } else { ep };
        let parsed = Url::parse(target_url).map_err(|e| {
            ProviderError::InvalidConfig(format!("有道翻译接口地址无效: {e}"))
        })?;

        if parsed.scheme() != "https" && !is_loopback_host(&parsed) {
            return Err(ProviderError::InvalidConfig(
                "有道翻译接口必须使用 HTTPS 或本地回环地址".to_string(),
            ));
        }

        Ok(Self {
            endpoint: parsed,
            app_key,
            app_secret,
        })
    }
}

#[derive(Clone)]
pub struct YoudaoProvider {
    client: SharedHttpClient,
    config: YoudaoConfig,
}

fn map_language_for_youdao(code: &str) -> &str {
    match code {
        "zh-Hans" | "zh-Hans-CN" | "zh-CN" | "zh" => "zh-CHS",
        "zh-Hant" | "zh-TW" | "zh-HK" => "zh-CHT",
        "en" | "en-US" | "en-GB" => "en",
        "ja" => "ja",
        "ko" => "ko",
        "fr" => "fr",
        "de" => "de",
        "es" => "es",
        "ru" => "ru",
        _ => "auto",
    }
}

fn truncate_youdao_input(text: &str) -> String {
    let count = text.chars().count();
    if count <= 20 {
        text.to_string()
    } else {
        let first10: String = text.chars().take(10).collect();
        let last10: String = text.chars().skip(count - 10).collect();
        format!("{}{}{}", first10, count, last10)
    }
}

#[derive(Deserialize)]
struct YoudaoResponse {
    #[serde(rename = "errorCode")]
    error_code: String,
    translation: Option<Vec<String>>,
}

impl YoudaoProvider {
    pub fn new(config: YoudaoConfig) -> Result<Self, ProviderError> {
        let client = shared_http_client()?;
        Ok(Self { client, config })
    }

    pub async fn translate(
        &self,
        request: &TranslationRequest,
    ) -> Result<TranslationResult, ProviderError> {
        let started_at = Instant::now();
        let from_lang = request
            .source_language()
            .map(|s| map_language_for_youdao(s.as_str()))
            .unwrap_or("auto");
        let to_lang = map_language_for_youdao(request.target_language().as_str());

        let now_epoch = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let curtime = now_epoch.as_secs().to_string();
        let salt = now_epoch.as_millis().to_string();

        let truncated = truncate_youdao_input(request.text());
        let sign_src = format!(
            "{}{}{}{}{}",
            self.config.app_key,
            truncated,
            salt,
            curtime,
            self.config.app_secret
        );

        let mut hasher = Sha256::new();
        hasher.update(sign_src.as_bytes());
        let sign = hex::encode(hasher.finalize());

        let form = [
            ("q", request.text()),
            ("from", from_lang),
            ("to", to_lang),
            ("appKey", &self.config.app_key),
            ("salt", &salt),
            ("curtime", &curtime),
            ("signType", "v3"),
            ("sign", &sign),
        ];

        let response = self
            .client
            .post(self.config.endpoint.clone())
            .form(&form)
            .timeout(Duration::from_secs(DEFAULT_TIMEOUT_SECONDS))
            .send()
            .await
            .map_err(|e| ProviderError::Network(e.to_string()))?;

        let status = response.status();
        if !status.is_success() {
            return Err(map_status_error(status, "有道翻译"));
        }

        let body = response.text().await.map_err(|e| ProviderError::Network(e.to_string()))?;
        let parsed: YoudaoResponse = serde_json::from_str(&body)
            .map_err(|e| ProviderError::InvalidResponse(format!("解析有道翻译响应失败: {e}")))?;

        if parsed.error_code != "0" {
            let friendly = match parsed.error_code.as_str() {
                "101" => "有道翻译缺少必填参数",
                "102" => "有道翻译不支持该语言转换",
                "108" => return Err(ProviderError::Authentication("有道翻译 AppKey 无效，请检查配置".into())),
                "110" => "有道翻译无相关服务权限",
                "111" => "有道翻译开发者账号无效",
                "202" => return Err(ProviderError::Authentication("有道翻译签名检验失败，请检查密钥是否正确".into())),
                "401" => "有道翻译账户欠费，请前往充值",
                "411" => return Err(ProviderError::RateLimited("有道翻译访问频次受限".into())),
                _ => "有道翻译接口返回错误",
            };
            return Err(ProviderError::Server {
                status: 200,
                message: format!("{friendly} (错误码: {})", parsed.error_code),
            });
        }

        let translation = parsed.translation.ok_or_else(|| {
            ProviderError::InvalidResponse("有道翻译未返回有效译文结果".to_string())
        })?;

        Ok(TranslationResult {
            text: translation.join("\n"),
            detected_language: None,
            provider: "youdao".to_string(),
            elapsed_ms: started_at.elapsed().as_millis() as u64,
        })
    }
}
