use translator_core::TranslationRequest;
use translator_providers::google::{GoogleConfig, GoogleProvider, parse_response_body};

mod common;

#[test]
fn parses_and_decodes_a_google_translation() {
    let body = r#"[[["Tom &amp; Jerry","Tom and Jerry",null,null,10]],null,"en"]"#;

    let parsed = parse_response_body(body).expect("valid response");

    assert_eq!(parsed.text, "Tom & Jerry");
    assert_eq!(parsed.detected_language.as_deref(), Some("en"));
}

#[test]
fn requires_no_user_credentials_and_https_outside_loopback() {
    assert!(GoogleConfig::new().is_ok());
    assert!(GoogleConfig::with_endpoint("http://127.0.0.1:1234/translate").is_ok());
    assert!(GoogleConfig::with_endpoint("http://example.com/translate").is_err());
}

#[tokio::test]
async fn sends_the_keyless_google_web_translation_contract() {
    let (base, server) = common::serve_once(r#"[[["你好","Hello",null,null,10]],null,"en"]"#);
    let endpoint = format!("{base}/translate_a/single?client=gtx&dt=t");
    let provider = GoogleProvider::new(GoogleConfig::with_endpoint(endpoint).unwrap()).unwrap();
    let request = TranslationRequest::new("Hello", None, "zh-CN").unwrap();

    let result = provider.translate(&request).await.unwrap();

    assert_eq!(result.text, "你好");
    assert_eq!(result.provider, "google");
    assert_eq!(result.detected_language.unwrap().as_str(), "en");
    let raw_request = server.join().unwrap();
    assert!(raw_request.starts_with("POST /translate_a/single?client=gtx&dt=t HTTP/1.1"));
    assert!(raw_request.contains("content-type: application/x-www-form-urlencoded"));
    assert!(raw_request.contains("sl=auto&tl=zh-CN&q=Hello"));
    assert!(!raw_request.to_ascii_lowercase().contains("api-key"));
    assert!(!raw_request.to_ascii_lowercase().contains("authorization"));
}
