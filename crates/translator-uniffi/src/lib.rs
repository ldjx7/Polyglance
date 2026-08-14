//! Swift-facing translation API.

use std::sync::Arc;
use tokio::runtime::{Builder, Runtime};
use translator_core::{TranslationError as CoreError, TranslationRequest};
use translator_providers::google::{GoogleConfig, GoogleProvider};
use translator_providers::microsoft::{MicrosoftConfig, MicrosoftProvider};
use translator_providers::openai::{
    OpenAiCompatibleConfig, OpenAiCompatibleProvider, ProviderError,
};

uniffi::setup_scaffolding!();

#[derive(Clone, Debug, uniffi::Record)]
pub struct TranslationInput {
    pub provider: String,
    pub endpoint: String,
    pub api_key: String,
    pub model: String,
    pub region: Option<String>,
    pub text: String,
    pub source_language: Option<String>,
    pub target_language: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct TranslationOutput {
    pub text: String,
    pub provider: String,
    pub elapsed_ms: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error, uniffi::Error)]
pub enum TranslationFailure {
    #[error("translation input is invalid")]
    InvalidInput,
    #[error("translation provider configuration is invalid")]
    InvalidConfiguration,
    #[error("translation provider rejected the credentials")]
    Authentication,
    #[error("translation provider rate limit was reached")]
    RateLimited,
    #[error("translation network request failed")]
    Network,
    #[error("translation provider returned an error")]
    Provider,
    #[error("translation provider returned an invalid response")]
    InvalidResponse,
    #[error("translation engine could not be initialized")]
    Initialization,
}

#[derive(uniffi::Object)]
pub struct TranslationEngine {
    runtime: Runtime,
}

#[uniffi::export]
impl TranslationEngine {
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, TranslationFailure> {
        let runtime = Builder::new_multi_thread()
            .enable_all()
            .thread_name("native-translator")
            .build()
            .map_err(|_| TranslationFailure::Initialization)?;
        Ok(Arc::new(Self { runtime }))
    }

    pub fn translate(
        &self,
        input: TranslationInput,
    ) -> Result<TranslationOutput, TranslationFailure> {
        let request = TranslationRequest::new(
            input.text,
            input.source_language.as_deref(),
            &input.target_language,
        )
        .map_err(map_core_error)?;
        let result = match input.provider.as_str() {
            "openai-compatible" | "free-ai" => {
                let mut config =
                    OpenAiCompatibleConfig::new(input.endpoint, input.api_key, input.model)
                        .map_err(map_provider_error)?;
                if input.provider == "free-ai" {
                    config = config.denying_data_collection();
                }
                let provider = OpenAiCompatibleProvider::new(config).map_err(map_provider_error)?;
                self.runtime
                    .block_on(provider.translate(&request))
                    .map_err(map_provider_error)?
            }
            "google" => {
                let config = if input.endpoint.trim().is_empty() {
                    GoogleConfig::new()
                } else {
                    GoogleConfig::with_endpoint(input.endpoint)
                }
                .map_err(map_provider_error)?;
                let provider = GoogleProvider::new(config).map_err(map_provider_error)?;
                self.runtime
                    .block_on(provider.translate(&request))
                    .map_err(map_provider_error)?
            }
            "microsoft" => {
                let config = if input.endpoint.trim().is_empty() {
                    MicrosoftConfig::new()
                } else {
                    MicrosoftConfig::with_endpoint(input.endpoint)
                }
                .map_err(map_provider_error)?;
                let provider = MicrosoftProvider::new(config).map_err(map_provider_error)?;
                self.runtime
                    .block_on(provider.translate(&request))
                    .map_err(map_provider_error)?
            }
            _ => return Err(TranslationFailure::InvalidConfiguration),
        };

        Ok(TranslationOutput {
            text: result.text,
            provider: result.provider,
            elapsed_ms: result.elapsed_ms,
        })
    }
}

fn map_core_error(_error: CoreError) -> TranslationFailure {
    TranslationFailure::InvalidInput
}

fn map_provider_error(error: ProviderError) -> TranslationFailure {
    match error {
        ProviderError::InvalidRequest(_) => TranslationFailure::InvalidInput,
        ProviderError::InvalidConfig(_) => TranslationFailure::InvalidConfiguration,
        ProviderError::Network(_) => TranslationFailure::Network,
        ProviderError::Authentication(_) => TranslationFailure::Authentication,
        ProviderError::RateLimited(_) => TranslationFailure::RateLimited,
        ProviderError::Server { .. } => TranslationFailure::Provider,
        ProviderError::InvalidResponse(_) => TranslationFailure::InvalidResponse,
    }
}
