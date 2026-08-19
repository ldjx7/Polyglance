//! Translation service adapters.

use reqwest::Client;
use std::ops::Deref;
use std::sync::{Arc, OnceLock};

use crate::openai::ProviderError;

pub mod dispatch;
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
                // Microsoft's free endpoint rejects requests without one
                // ("Client Browser Version not supported"), and reqwest sends
                // none by default.
                .user_agent(concat!("Polyglance/", env!("CARGO_PKG_VERSION")))
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
        let first = shared_http_client().expect("a shared client");
        let second = shared_http_client().expect("a shared client");

        assert!(first.shares_connection_pool_with(&second));
    }

    /// Microsoft's free endpoint answers "Client Browser Version not supported"
    /// to requests without one, and reqwest sends none unless asked. Reading the
    /// bytes off a socket is the only way to see the headers it actually sends.
    #[tokio::test]
    async fn the_shared_client_identifies_itself_on_the_wire() {
        use std::io::{Read, Write};

        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a local port");
        let address = listener.local_addr().expect("a bound address");
        let accepted = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("an inbound request");
            let mut buffer = [0u8; 2048];
            let read = stream.read(&mut buffer).unwrap_or(0);
            let _ = stream.write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n");
            String::from_utf8_lossy(&buffer[..read]).into_owned()
        });

        let _ = shared_http_client()
            .expect("a shared client")
            .get(format!("http://{address}/"))
            .send()
            .await;

        let request = accepted.join().expect("the listener thread");
        let lowercased = request.to_lowercase();
        assert!(
            lowercased.contains("user-agent: polyglance/"),
            "sent headers were: {request}"
        );
    }
}
