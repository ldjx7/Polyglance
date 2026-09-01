use translator_core::TranslationRequest;
use translator_providers::microsoft::{MicrosoftConfig, MicrosoftProvider, parse_response_body};

mod common;

#[test]
fn parses_a_microsoft_translation() {
    let body = r#"[{"detectedLanguage":{"language":"en","score":1.0},"translations":[{"text":"你好","to":"zh-Hans"}]}]"#;

    let parsed = parse_response_body(body).expect("valid response");

    assert_eq!(parsed.text, "你好");
    assert_eq!(parsed.detected_language.as_deref(), Some("en"));
}

#[test]
fn requires_no_user_or_build_credentials_and_https_outside_loopback() {
    assert!(MicrosoftConfig::new().is_ok());
    assert!(MicrosoftConfig::with_endpoint("http://127.0.0.1:1234/translate").is_ok());
    assert!(MicrosoftConfig::with_endpoint("http://example.com/translate").is_err());
}

#[tokio::test]
async fn sends_the_keyless_edge_translation_contract() {
    let (base, server) = common::serve_once(
        r#"[{"detectedLanguage":{"language":"en","score":1.0},"translations":[{"text":"你好","to":"zh-Hans"}]}]"#,
    );
    let endpoint = format!("{base}/translate/translatetext");
    let provider =
        MicrosoftProvider::new(MicrosoftConfig::with_endpoint(endpoint).unwrap()).unwrap();
    let request = TranslationRequest::new("Hello", None, "zh-CN").unwrap();

    let result = provider.translate(&request).await.unwrap();

    assert_eq!(result.text, "你好");
    assert_eq!(result.provider, "microsoft");
    let raw_request = server.join().unwrap().to_ascii_lowercase();
    assert!(
        raw_request.starts_with(
            "post /translate/translatetext?to=zh-hans&isenterpriseclient=false http/1.1"
        )
    );
    assert!(!raw_request.contains("ocp-apim-subscription-key"));
    assert!(!raw_request.contains("authorization:"));
    assert!(raw_request.contains(r#"["hello"]"#));
}
