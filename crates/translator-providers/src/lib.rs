//! Translation service adapters.

use reqwest::Client;
use std::ops::Deref;
use std::sync::{Arc, OnceLock};

use crate::openai::ProviderError;

pub mod google;
pub mod microsoft;
pub mod openai;
pub mod streaming;

#[derive(Clone)]
pub(crate) struct SharedHttpClient {
    inner: Arc<Client>,
}

impl Deref for SharedHttpClient {
    type Target = Client;

    fn deref(&self) -> &Self::Target {
        &self.inner
    }
}

impl SharedHttpClient {
    #[cfg(test)]
    fn shares_connection_pool_with(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.inner, &other.inner)
    }
}

pub(crate) fn shared_http_client() -> Result<SharedHttpClient, ProviderError> {
    static CLIENT: OnceLock<SharedHttpClient> = OnceLock::new();
    if let Some(client) = CLIENT.get() {
        return Ok(client.clone());
    }

    let client = SharedHttpClient {
        inner: Arc::new(
            Client::builder()
                .build()
                .map_err(|error| ProviderError::Network(error.to_string()))?,
        ),
    };
    let _ = CLIENT.set(client);
    Ok(CLIENT
        .get()
        .expect("shared HTTP client initialized")
        .clone())
}

#[cfg(test)]
mod tests {
    use super::shared_http_client;

    #[test]
    fn every_provider_reuses_the_same_process_wide_connection_pool() {
        let first = shared_http_client().expect("shared client");
        let second = shared_http_client().expect("shared client");

        assert!(first.shares_connection_pool_with(&second));
    }
}
