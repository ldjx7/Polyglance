use std::io::{Read, Write};
use std::net::TcpListener;
use std::thread;

use translator_core::TranslationRequest;
use translator_providers::microsoft::{MicrosoftConfig, MicrosoftProvider, parse_response_body};

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
    let (endpoint, server) = serve_once(
        r#"[{"detectedLanguage":{"language":"en","score":1.0},"translations":[{"text":"你好","to":"zh-Hans"}]}]"#,
    );
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

fn serve_once(body: &'static str) -> (String, thread::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = [0_u8; 32 * 1024];
        let byte_count = stream.read(&mut request).unwrap();
        let raw_request = String::from_utf8_lossy(&request[..byte_count]).to_string();
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream.write_all(response.as_bytes()).unwrap();
        raw_request
    });
    (format!("http://{address}/translate/translatetext"), server)
}
