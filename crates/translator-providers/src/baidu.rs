use md5::{Digest, Md5};
use reqwest::Url;
use serde::Deserialize;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use translator_core::{LanguageCode, TranslationRequest, TranslationResult};

use crate::SharedHttpClient;
use crate::openai::{ProviderError, is_loopback_host, map_status_error};
use crate::shared_http_client;

const DEFAULT_ENDPOINT: &str = "https://fanyi-api.baidu.com/api/trans/vip/translate";
const DEFAULT_TIMEOUT_SECONDS: u64 = 30;

#[derive(Clone, Debug)]
pub struct BaiduConfig {
    endpoint: Url,
    app_id: String,
    secret_key: String,
}

impl BaiduConfig {
    pub fn new(
        endpoint: impl AsRef<str>,
        credentials: impl AsRef<str>,
    ) -> Result<Self, ProviderError> {
        let creds = credentials.as_ref().trim();
        let (app_id, secret_key) = match creds.split_once(':') {
            Some((id, key)) => (id.trim().to_string(), key.trim().to_string()),
            None => {
                return Err(ProviderError::InvalidConfig(
                    "百度翻译凭证格式需为 AppID:密钥，请在偏好设置中填写完整".to_string(),
                ));
            }
        };

        if app_id.is_empty() || secret_key.is_empty() {
            return Err(ProviderError::InvalidConfig(
                "百度翻译 AppID 或密钥为空，请在偏好设置中填写完整".to_string(),
            ));
        }

        let ep = endpoint.as_ref().trim();
        let target_url = if ep.is_empty() { DEFAULT_ENDPOINT } else { ep };
        let parsed = Url::parse(target_url)
            .map_err(|e| ProviderError::InvalidConfig(format!("百度翻译接口地址无效: {e}")))?;

        if parsed.scheme() != "https" && !is_loopback_host(&parsed) {
            return Err(ProviderError::InvalidConfig(
                "百度翻译接口必须使用 HTTPS 或本地回环地址".to_string(),
            ));
        }

        Ok(Self {
            endpoint: parsed,
            app_id,
            secret_key,
        })
    }
}

#[derive(Clone)]
pub struct BaiduProvider {
    client: SharedHttpClient,
    config: BaiduConfig,
}

fn map_language_for_baidu(code: &str) -> &str {
    match code {
        "zh-Hans" | "zh-Hans-CN" | "zh-CN" | "zh" => "zh",
        "zh-Hant" | "zh-TW" | "zh-HK" => "cht",
        "en" | "en-US" | "en-GB" => "en",
        "ja" => "jp",
        "ko" => "kor",
        "fr" => "fra",
        "de" => "de",
        "es" => "spa",
        "ru" => "ru",
        _ => "auto",
    }
}

#[derive(Deserialize)]
struct BaiduTransItem {
    dst: String,
}

#[derive(Deserialize)]
struct BaiduResponse {
    from: Option<String>,
    error_code: Option<String>,
    error_msg: Option<String>,
    trans_result: Option<Vec<BaiduTransItem>>,
}

impl BaiduProvider {
    pub fn new(config: BaiduConfig) -> Result<Self, ProviderError> {
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
            .map(|s| map_language_for_baidu(s.as_str()))
            .unwrap_or("auto");
        let to_lang = map_language_for_baidu(request.target_language().as_str());

        let salt = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis().to_string())
            .unwrap_or_else(|_| "1435660288".to_string());

        let sign_str = format!(
            "{}{}{}{}",
            self.config.app_id,
            request.text(),
            salt,
            self.config.secret_key
        );

        let mut hasher = Md5::new();
        hasher.update(sign_str.as_bytes());
        let sign = hex::encode(hasher.finalize());

        let form = [
            ("q", request.text()),
            ("from", from_lang),
            ("to", to_lang),
            ("appid", &self.config.app_id),
            ("salt", &salt),
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
            return Err(map_status_error(status, "百度翻译"));
        }

        let body = response
            .text()
            .await
            .map_err(|e| ProviderError::Network(e.to_string()))?;
        let parsed: BaiduResponse = serde_json::from_str(&body)
            .map_err(|e| ProviderError::InvalidResponse(format!("解析百度翻译响应失败: {e}")))?;

        if let Some(err_code) = parsed.error_code {
            if err_code != "52000" {
                let msg = parsed.error_msg.unwrap_or_default();
                let friendly = match err_code.as_str() {
                    "52001" => "百度翻译请求超时，请稍后重试",
                    "52002" => "百度翻译系统错误，请稍后重试",
                    "52003" => {
                        return Err(ProviderError::Authentication(
                            "百度翻译未授权用户，请检查 AppID 与密钥是否正确".into(),
                        ));
                    }
                    "54000" => "百度翻译必填参数为空",
                    "54003" | "54005" => {
                        return Err(ProviderError::RateLimited(
                            "百度翻译访问频次受限或并发过高，请稍后重试".into(),
                        ));
                    }
                    "54004" => "百度翻译账户余额不足，请前往平台充值",
                    _ => "百度翻译接口返回错误",
                };
                return Err(ProviderError::Server {
                    status: 200,
                    message: format!("{friendly} ({err_code}: {msg})"),
                });
            }
        }

        let results = parsed.trans_result.ok_or_else(|| {
            ProviderError::InvalidResponse("百度翻译未返回有效译文结果".to_string())
        })?;

        let translated_text = results
            .into_iter()
            .map(|item| item.dst)
            .collect::<Vec<_>>()
            .join("\n");

        let detected = parsed
            .from
            .and_then(|f| LanguageCode::new(&f.to_lowercase()).ok());

        Ok(TranslationResult {
            text: translated_text,
            detected_language: detected,
            provider: "baidu".to_string(),
            elapsed_ms: started_at.elapsed().as_millis() as u64,
        })
    }
}
