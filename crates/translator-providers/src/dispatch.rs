//! Provider selection and dispatch.
//!
//! Choosing a service, building its configuration, and the privacy policy that
//! goes with each one are product decisions, so they live here rather than in a
//! platform binding.

use translator_core::{TranslationRequest, TranslationResult};

use crate::google::{GoogleConfig, GoogleProvider};
use crate::microsoft::{MicrosoftConfig, MicrosoftProvider};
use crate::openai::{OpenAiCompatibleConfig, OpenAiCompatibleProvider, ProviderError};

pub const GOOGLE: &str = "google";
pub const MICROSOFT: &str = "microsoft";
pub const FREE_AI: &str = "free-ai";
pub const FREEAI: &str = "freeai";
pub const OPENAI_COMPATIBLE: &str = "openai-compatible";
pub const OPENAICOMPATIBLE: &str = "openaicompatible";
pub const DEFAULT_FREE_AI_KEY: &str = match option_env!("POLYGLANCE_FREE_AI_API_KEY") {
    Some(value) => value,
    None => "",
};
pub const DEFAULT_FREE_AI_ENDPOINT: &str = "https://openrouter.ai/api/v1";
pub const DEFAULT_FREE_AI_MODEL: &str = "openrouter/auto";

/// A resolved service, ready to translate.
pub enum Selection {
    Google(GoogleConfig),
    Microsoft(MicrosoftConfig),
    OpenAiCompatible(OpenAiCompatibleConfig),
}

/// Resolves a stored provider name into a usable configuration.
///
/// An empty endpoint means "use the built-in one", which is how the free
/// Google and Microsoft services are configured.
pub fn select(
    provider: &str,
    endpoint: String,
    api_key: String,
    model: String,
) -> Result<Selection, ProviderError> {
    match provider {
        GOOGLE => {
            let config = if endpoint.trim().is_empty() {
                GoogleConfig::new()
            } else {
                GoogleConfig::with_endpoint(endpoint)
            }?;
            Ok(Selection::Google(config))
        }
        MICROSOFT => {
            let config = if endpoint.trim().is_empty() {
                MicrosoftConfig::new()
            } else {
                MicrosoftConfig::with_endpoint(endpoint)
            }?;
            Ok(Selection::Microsoft(config))
        }
        FREE_AI | FREEAI | OPENAI_COMPATIBLE | OPENAICOMPATIBLE => {
            let is_free_ai = provider == FREE_AI || provider == FREEAI;
            let (ep, key, mdl) = if is_free_ai {
                (
                    if endpoint.trim().is_empty() {
                        DEFAULT_FREE_AI_ENDPOINT.to_string()
                    } else {
                        endpoint
                    },
                    if api_key.trim().is_empty() {
                        DEFAULT_FREE_AI_KEY.to_string()
                    } else {
                        api_key
                    },
                    if model.trim().is_empty() {
                        DEFAULT_FREE_AI_MODEL.to_string()
                    } else {
                        model
                    },
                )
            } else {
                if api_key.trim().is_empty() {
                    return Err(ProviderError::InvalidConfig(
                        "未配置 API Key，请在偏好设置中填写 OpenAI / DeepSeek / SiliconFlow 等兼容 API Key".to_string(),
                    ));
                }
                (
                    if endpoint.trim().is_empty() {
                        "https://api.openai.com/v1".to_string()
                    } else {
                        endpoint
                    },
                    api_key,
                    if model.trim().is_empty() {
                        "gpt-4o-mini".to_string()
                    } else {
                        model
                    },
                )
            };

            let mut config = OpenAiCompatibleConfig::new(ep, key, mdl)?;
            if is_free_ai {
                config = config.denying_data_collection();
            }
            Ok(Selection::OpenAiCompatible(config))
        }
        _ => Err(ProviderError::InvalidConfig(format!(
            "unknown translation provider: {provider}"
        ))),
    }
}

pub async fn translate(
    selection: Selection,
    request: &TranslationRequest,
) -> Result<TranslationResult, ProviderError> {
    match selection {
        Selection::Google(config) => GoogleProvider::new(config)?.translate(request).await,
        Selection::Microsoft(config) => MicrosoftProvider::new(config)?.translate(request).await,
        Selection::OpenAiCompatible(config) => {
            OpenAiCompatibleProvider::new(config)?
                .translate(request)
                .await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_shipped_provider_name_resolves() {
        for provider in [GOOGLE, MICROSOFT] {
            assert!(
                select(provider, String::new(), String::new(), String::new()).is_ok(),
                "{provider} must resolve without an endpoint"
            );
        }
        assert!(
            select(
                OPENAI_COMPATIBLE,
                "https://api.openai.com/v1".to_owned(),
                "key".to_owned(),
                "gpt-4.1-mini".to_owned()
            )
            .is_ok()
        );
    }

    #[test]
    fn an_unknown_provider_is_rejected() {
        let error = select("nope", String::new(), String::new(), String::new());

        assert!(matches!(error, Err(ProviderError::InvalidConfig(_))));
    }

    #[test]
    fn a_custom_endpoint_overrides_the_built_in_one() {
        let selection = select(
            GOOGLE,
            "https://example.test/translate".to_owned(),
            String::new(),
            String::new(),
        );

        assert!(matches!(selection, Ok(Selection::Google(_))));
    }

    #[test]
    fn only_the_bundled_free_service_denies_data_collection() {
        let free = select(
            FREE_AI,
            "https://openrouter.ai/api/v1".to_owned(),
            "key".to_owned(),
            "model".to_owned(),
        )
        .expect("free-ai resolves");
        let custom = select(
            OPENAI_COMPATIBLE,
            "https://api.openai.com/v1".to_owned(),
            "key".to_owned(),
            "model".to_owned(),
        )
        .expect("custom AI resolves");

        let Selection::OpenAiCompatible(free) = free else {
            panic!("expected an OpenAI-compatible selection")
        };
        let Selection::OpenAiCompatible(custom) = custom else {
            panic!("expected an OpenAI-compatible selection")
        };
        assert!(free.denies_data_collection());
        assert!(!custom.denies_data_collection());
    }
}
