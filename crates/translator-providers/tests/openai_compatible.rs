use translator_core::TranslationRequest;
use translator_providers::openai::{
    OpenAiCompatibleConfig, OpenAiCompatibleProvider, ProviderError, build_request_body,
    parse_response_body,
};

use std::io::{Read, Write};
use std::net::TcpListener;
use std::thread;

#[test]
fn builds_a_translation_only_chat_request() {
    let request = TranslationRequest::new("Hello", Some("en"), "zh-CN").unwrap();
    let config =
        OpenAiCompatibleConfig::new("https://api.openai.com/v1", "test-key", "gpt-4.1-mini")
            .unwrap();

    let body = build_request_body(&config, &request);

    assert_eq!(body["model"], "gpt-4.1-mini");
    assert_eq!(body["temperature"], 0);
    assert_eq!(body["messages"][1]["content"], "Hello");
    assert!(
        body["messages"][0]["content"]
            .as_str()
            .unwrap()
            .contains("zh-CN")
    );
}

#[test]
fn free_ai_requests_deny_data_collecting_model_providers() {
    let request = TranslationRequest::new("Hello", Some("en"), "zh-CN").unwrap();
    let config = OpenAiCompatibleConfig::new(
        "https://openrouter.ai/api/v1",
        "test-key",
        "openrouter/free",
    )
    .unwrap()
    .denying_data_collection();

    let body = build_request_body(&config, &request);

    assert_eq!(body["provider"]["data_collection"], "deny");
}

#[test]
fn parses_the_first_message_content() {
    let body = r#"{
        "choices": [{"message": {"content": "你好"}}],
        "usage": {"prompt_tokens": 3, "completion_tokens": 2}
    }"#;

    let parsed = parse_response_body(body).expect("valid response");

    assert_eq!(parsed.text, "你好");
}

#[test]
fn rejects_a_response_without_translated_text() {
    let error = parse_response_body(r#"{"choices": []}"#).unwrap_err();

    assert!(error.to_string().contains("translated text"));
}

#[test]
fn validates_configuration_before_network_access() {
    let error = OpenAiCompatibleConfig::new("http://localhost:8080", "", "model").unwrap_err();

    assert!(error.to_string().contains("API key"));
}

#[test]
fn allows_plain_http_only_for_loopback_services() {
    assert!(OpenAiCompatibleConfig::new("http://127.0.0.1:1234/v1", "key", "model").is_ok());
    assert!(OpenAiCompatibleConfig::new("http://localhost:1234/v1", "key", "model").is_ok());

    let error = OpenAiCompatibleConfig::new("http://example.com/v1", "key", "model").unwrap_err();
    assert!(error.to_string().contains("HTTPS"));
}

#[tokio::test]
async fn translates_through_an_openai_compatible_endpoint() {
    let (endpoint, server) = serve_once(200, r#"{"choices":[{"message":{"content":"你好"}}]}"#);
    let request = TranslationRequest::new("Hello", None, "zh-CN").unwrap();
    let config = OpenAiCompatibleConfig::new(endpoint, "test-key", "test-model").unwrap();
    let provider = OpenAiCompatibleProvider::new(config).unwrap();

    let result = provider.translate(&request).await.unwrap();

    assert_eq!(result.text, "你好");
    assert_eq!(result.provider, "openai-compatible");
    server.join().unwrap();
}

#[tokio::test]
async fn maps_authentication_and_rate_limit_responses() {
    let (auth_endpoint, auth_server) = serve_once(401, r#"{"error":{"message":"bad key"}}"#);
    let request = TranslationRequest::new("Hello", None, "zh-CN").unwrap();
    let auth_provider = OpenAiCompatibleProvider::new(
        OpenAiCompatibleConfig::new(auth_endpoint, "test-key", "test-model").unwrap(),
    )
    .unwrap();

    let auth_error = auth_provider.translate(&request).await.unwrap_err();
    assert!(matches!(auth_error, ProviderError::Authentication(message) if message == "bad key"));
    auth_server.join().unwrap();

    let (rate_endpoint, rate_server) = serve_once(429, "not-json");
    let rate_provider = OpenAiCompatibleProvider::new(
        OpenAiCompatibleConfig::new(rate_endpoint, "test-key", "test-model").unwrap(),
    )
    .unwrap();

    let rate_error = rate_provider.translate(&request).await.unwrap_err();
    assert!(matches!(rate_error, ProviderError::RateLimited(_)));
    rate_server.join().unwrap();
}

fn serve_once(status: u16, body: &'static str) -> (String, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = [0_u8; 16 * 1024];
        let _ = stream.read(&mut request).unwrap();
        let reason = match status {
            200 => "OK",
            401 => "Unauthorized",
            429 => "Too Many Requests",
            _ => "Error",
        };
        let response = format!(
            "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream.write_all(response.as_bytes()).unwrap();
    });

    (format!("http://{address}/v1"), server)
}
