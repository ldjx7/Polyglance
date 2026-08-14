use std::io::{Read, Write};
use std::net::TcpListener;
use std::thread;

use translator_core::TranslationRequest;
use translator_providers::google::{GoogleConfig, GoogleProvider, parse_response_body};

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
    let (endpoint, server) = serve_once(r#"[[["你好","Hello",null,null,10]],null,"en"]"#);
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
    (
        format!("http://{address}/translate_a/single?client=gtx&dt=t"),
        server,
    )
}
