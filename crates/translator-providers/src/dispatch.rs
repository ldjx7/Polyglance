//! Provider selection and dispatch.
//!
//! Choosing a service, building its configuration, and the privacy policy that
//! goes with each one are product decisions, so they live here rather than in a
//! platform binding.

use translator_core::{TranslationRequest, TranslationResult};

use crate::free_ai::{FreeAiConfig, FreeAiProvider};
use crate::google::{GoogleConfig, GoogleProvider};
use crate::microsoft::{MicrosoftConfig, MicrosoftProvider};
use crate::openai::{OpenAiCompatibleConfig, OpenAiCompatibleProvider, ProviderError};

pub const GOOGLE: &str = "google";
pub const MICROSOFT: &str = "microsoft";
pub const FREE_AI: &str = "free-ai";
pub const FREEAI: &str = "freeai";
pub const OPENAI_COMPATIBLE: &str = "openai-compatible";
pub const OPENAICOMPATIBLE: &str = "openaicompatible";

pub use crate::free_ai::DEFAULT_FREE_AI_ENDPOINT;

/// A resolved service, ready to translate.
pub enum Selection {
    Google(GoogleConfig),
    Microsoft(MicrosoftConfig),
    FreeAi(FreeAiConfig),
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
        // The bundled service takes no credential and no model: it is the
        // project's own Worker, which owns both. An ignored `model` here is not
        // an oversight; letting a client choose one is exactly what made the
        // previous design billable by anyone holding the binary.
        FREE_AI | FREEAI => {
            let config = if endpoint.trim().is_empty() {
                FreeAiConfig::default_endpoint()
            } else {
                FreeAiConfig::new(endpoint)
            }?;
            Ok(Selection::FreeAi(config))
        }
        OPENAI_COMPATIBLE | OPENAICOMPATIBLE => {
            if api_key.trim().is_empty() {
                return Err(ProviderError::InvalidConfig(
                    "未配置 API Key，请在偏好设置中填写 OpenAI / DeepSeek / SiliconFlow 等兼容 API Key"
                        .to_string(),
                ));
            }
            let endpoint = if endpoint.trim().is_empty() {
                "https://api.openai.com/v1".to_owned()
            } else {
                endpoint
            };
            let model = if model.trim().is_empty() {
                "gpt-4o-mini".to_owned()
            } else {
                model
            };
            Ok(Selection::OpenAiCompatible(OpenAiCompatibleConfig::new(
                endpoint, api_key, model,
            )?))
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
        Selection::FreeAi(config) => FreeAiProvider::new(config)?.translate(request).await,
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
        for provider in [GOOGLE, MICROSOFT, FREE_AI] {
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
    fn the_bundled_free_service_never_reaches_the_openai_path() {
        let selection = select(FREE_AI, String::new(), String::new(), "gpt-4o".to_owned())
            .expect("free-ai resolves without credentials");

        assert!(
            matches!(selection, Selection::FreeAi(_)),
            "a client-supplied model must not push the free service onto the OpenAI path"
        );
    }

    #[test]
    fn the_bundled_free_service_defaults_to_the_project_endpoint() {
        let selection =
            select(FREE_AI, String::new(), String::new(), String::new()).expect("free-ai resolves");

        let Selection::FreeAi(config) = selection else {
            panic!("expected a free AI selection")
        };
        assert_eq!(config.endpoint().as_str(), DEFAULT_FREE_AI_ENDPOINT);
        assert_eq!(config.endpoint().scheme(), "https");
    }

    #[test]
    fn a_custom_ai_service_still_demands_a_key() {
        let error = select(
            OPENAI_COMPATIBLE,
            "https://api.openai.com/v1".to_owned(),
            String::new(),
            "gpt-4.1-mini".to_owned(),
        );

        assert!(matches!(error, Err(ProviderError::InvalidConfig(_))));
    }
}
