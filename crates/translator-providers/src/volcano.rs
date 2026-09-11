use hmac::{Hmac, KeyInit, Mac};
use reqwest::Url;
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use translator_core::{LanguageCode, TranslationRequest, TranslationResult};

use crate::SharedHttpClient;
use crate::openai::{ProviderError, is_loopback_host, map_status_error};
use crate::shared_http_client;

const DEFAULT_ENDPOINT: &str = "https://translate.volcengineapi.com";
const DEFAULT_TIMEOUT_SECONDS: u64 = 30;
const REGION: &str = "cn-north-1";
const SERVICE: &str = "translate";

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone, Debug)]
pub struct VolcanoConfig {
    endpoint: Url,
    access_key: String,
    secret_key: String,
}

impl VolcanoConfig {
    pub fn new(
        endpoint: impl AsRef<str>,
        credentials: impl AsRef<str>,
    ) -> Result<Self, ProviderError> {
        let creds = credentials.as_ref().trim();
        let (ak, sk) = match creds.split_once(':') {
            Some((a, s)) => (a.trim().to_string(), s.trim().to_string()),
            None => {
                if !creds.is_empty() {
                    (creds.to_string(), String::new())
                } else {
                    return Err(ProviderError::InvalidConfig(
                        "火山翻译凭证格式需为 AccessKey:SecretKey，请在偏好设置中填写完整"
                            .to_string(),
                    ));
                }
            }
        };

        if ak.is_empty() {
            return Err(ProviderError::InvalidConfig(
                "火山翻译 AccessKey 为空，请在偏好设置中填写完整".to_string(),
            ));
        }

        let ep = endpoint.as_ref().trim();
        let target_url = if ep.is_empty() { DEFAULT_ENDPOINT } else { ep };
        let parsed = Url::parse(target_url)
            .map_err(|e| ProviderError::InvalidConfig(format!("火山翻译接口地址无效: {e}")))?;

        if parsed.scheme() != "https" && !is_loopback_host(&parsed) {
            return Err(ProviderError::InvalidConfig(
                "火山翻译接口必须使用 HTTPS 或本地回环地址".to_string(),
            ));
        }

        Ok(Self {
            endpoint: parsed,
            access_key: ak,
            secret_key: sk,
        })
    }
}

#[derive(Clone)]
pub struct VolcanoProvider {
    client: SharedHttpClient,
    config: VolcanoConfig,
}

fn map_language_for_volcano(code: &str) -> &str {
    match code {
        "zh-Hans" | "zh-Hans-CN" | "zh-CN" | "zh" => "zh",
        "zh-Hant" | "zh-TW" | "zh-HK" => "zh-Hant",
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

fn hmac_sha256(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC can take key of any size");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

#[derive(Deserialize)]
struct VolcanoItem {
    #[serde(rename = "Translation")]
    translation: String,
    #[serde(rename = "DetectedSourceLanguage")]
    detected_source_language: Option<String>,
}

#[derive(Deserialize)]
struct VolcanoError {
    #[serde(rename = "Code")]
    code: Option<String>,
    #[serde(rename = "Message")]
    message: Option<String>,
}

#[derive(Deserialize)]
struct VolcanoMeta {
    #[serde(rename = "Error")]
    error: Option<VolcanoError>,
}

#[derive(Deserialize)]
struct VolcanoResponse {
    #[serde(rename = "TranslationList")]
    translation_list: Option<Vec<VolcanoItem>>,
    #[serde(rename = "ResponseMetadata")]
    response_metadata: Option<VolcanoMeta>,
}

impl VolcanoProvider {
    pub fn new(config: VolcanoConfig) -> Result<Self, ProviderError> {
        let client = shared_http_client()?;
        Ok(Self { client, config })
    }

    pub async fn translate(
        &self,
        request: &TranslationRequest,
    ) -> Result<TranslationResult, ProviderError> {
        let started_at = Instant::now();
        let target_lang = map_language_for_volcano(request.target_language().as_str());

        let payload = json!({
            "TargetLanguage": target_lang,
            "TextList": [request.text()]
        });
        let body_str = payload.to_string();

        let mut req_url = self.config.endpoint.clone();
        req_url
            .query_pairs_mut()
            .append_pair("Action", "TranslateText")
            .append_pair("Version", "2020-06-01");

        let mut req_builder = self.client.post(req_url.clone());
        req_builder = req_builder.header("Content-Type", "application/json");

        if self.config.secret_key.is_empty() {
            // Bearer Token 模式
            req_builder = req_builder.header(
                "Authorization",
                format!("Bearer {}", self.config.access_key),
            );
        } else {
            // 完整 Volcengine V4 HMAC-SHA256 签名算法
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            // 简易格式化 UTC: YYYYMMDDTHHMMSSZ
            let (year, month, day, hour, min, sec) = epoch_to_utc_parts(now);
            let date_short = format!("{:04}{:02}{:02}", year, month, day);
            let x_date = format!(
                "{:04}{:02}{:02}T{:02}{:02}{:02}Z",
                year, month, day, hour, min, sec
            );

            let mut body_hasher = Sha256::new();
            body_hasher.update(body_str.as_bytes());
            let x_content_sha256 = hex::encode(body_hasher.finalize());

            let host = req_url.host_str().unwrap_or("translate.volcengineapi.com");
            let canonical_query = "Action=TranslateText&Version=2020-06-01";
            let canonical_headers = format!(
                "content-type:application/json\nhost:{}\nx-content-sha256:{}\nx-date:{}\n",
                host, x_content_sha256, x_date
            );
            let signed_headers = "content-type;host;x-content-sha256;x-date";

            let canonical_request = format!(
                "POST\n/\n{}\n{}\n{}\n{}",
                canonical_query, canonical_headers, signed_headers, x_content_sha256
            );

            let mut req_hasher = Sha256::new();
            req_hasher.update(canonical_request.as_bytes());
            let hashed_req = hex::encode(req_hasher.finalize());

            let credential_scope = format!("{}/{}/{}/request", date_short, REGION, SERVICE);
            let string_to_sign = format!(
                "HMAC-SHA256\n{}\n{}\n{}",
                x_date, credential_scope, hashed_req
            );

            let k_date = hmac_sha256(self.config.secret_key.as_bytes(), date_short.as_bytes());
            let k_region = hmac_sha256(&k_date, REGION.as_bytes());
            let k_service = hmac_sha256(&k_region, SERVICE.as_bytes());
            let k_signing = hmac_sha256(&k_service, b"request");
            let signature = hex::encode(hmac_sha256(&k_signing, string_to_sign.as_bytes()));

            let auth_header = format!(
                "HMAC-SHA256 Credential={}/{}, SignedHeaders={}, Signature={}",
                self.config.access_key, credential_scope, signed_headers, signature
            );

            req_builder = req_builder
                .header("X-Date", x_date)
                .header("X-Content-Sha256", x_content_sha256)
                .header("Authorization", auth_header);
        }

        let response = req_builder
            .body(body_str)
            .timeout(Duration::from_secs(DEFAULT_TIMEOUT_SECONDS))
            .send()
            .await
            .map_err(|e| ProviderError::Network(e.to_string()))?;

        let status = response.status();
        if !status.is_success() {
            return Err(map_status_error(status, "火山翻译"));
        }

        let body = response
            .text()
            .await
            .map_err(|e| ProviderError::Network(e.to_string()))?;
        let parsed: VolcanoResponse = serde_json::from_str(&body)
            .map_err(|e| ProviderError::InvalidResponse(format!("解析火山翻译响应失败: {e}")))?;

        if let Some(meta) = parsed.response_metadata {
            if let Some(err) = meta.error {
                let code = err.code.unwrap_or_default();
                let msg = err.message.unwrap_or_default();
                if !code.is_empty() {
                    return Err(ProviderError::Server {
                        status: 200,
                        message: format!("火山翻译错误 ({code}): {msg}"),
                    });
                }
            }
        }

        let items = parsed
            .translation_list
            .ok_or_else(|| ProviderError::InvalidResponse("火山翻译未返回译文列表".to_string()))?;

        let first = items
            .into_iter()
            .next()
            .ok_or_else(|| ProviderError::InvalidResponse("火山翻译译文为空".to_string()))?;

        let detected = first
            .detected_source_language
            .and_then(|l| LanguageCode::new(&l.to_lowercase()).ok());

        Ok(TranslationResult {
            text: first.translation,
            detected_language: detected,
            provider: "volcano".to_string(),
            elapsed_ms: started_at.elapsed().as_millis() as u64,
        })
    }
}

fn epoch_to_utc_parts(epoch_sec: u64) -> (u32, u32, u32, u32, u32, u32) {
    let sec = (epoch_sec % 60) as u32;
    let min = ((epoch_sec / 60) % 60) as u32;
    let hour = ((epoch_sec / 3600) % 24) as u32;

    let mut days = (epoch_sec / 86400) as i64;
    let mut year = 1970;
    loop {
        let leap = is_leap_year(year);
        let days_in_year = if leap { 366 } else { 365 };
        if days < days_in_year {
            break;
        }
        days -= days_in_year;
        year += 1;
    }

    let leap = is_leap_year(year);
    let month_days = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let mut month = 1;
    for &d in &month_days {
        if days < d {
            break;
        }
        days -= d;
        month += 1;
    }
    let day = (days + 1) as u32;

    (year as u32, month, day, hour, min, sec)
}

fn is_leap_year(y: i64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)
}
