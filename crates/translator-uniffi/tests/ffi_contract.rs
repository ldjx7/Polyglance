use translator_uniffi::{TranslationEngine, TranslationFailure, TranslationInput};

use std::io::{Read, Write};
use std::net::TcpListener;
use std::thread;

fn valid_input() -> TranslationInput {
    TranslationInput {
        endpoint: "https://api.openai.com/v1".to_owned(),
        api_key: "test-key".to_owned(),
        model: "gpt-4.1-mini".to_owned(),
        text: "Hello".to_owned(),
        source_language: Some("en".to_owned()),
        target_language: "zh-CN".to_owned(),
    }
}

#[test]
fn validates_input_without_starting_a_network_request() {
    let mut input = valid_input();
    input.text = "  ".to_owned();
    let engine = TranslationEngine::new().expect("engine");

    let error = engine.translate(input).unwrap_err();

    assert_eq!(error, TranslationFailure::InvalidInput);
}

#[test]
fn rejects_a_missing_api_key() {
    let mut input = valid_input();
    input.api_key.clear();
    let engine = TranslationEngine::new().expect("engine");

    let error = engine.translate(input).unwrap_err();

    assert_eq!(error, TranslationFailure::InvalidConfiguration);
}

#[test]
fn translates_successfully_across_the_ffi_contract() {
    let (endpoint, server) = serve_once(r#"{"choices":[{"message":{"content":"你好"}}]}"#);
    let mut input = valid_input();
    input.endpoint = endpoint;
    let engine = TranslationEngine::new().expect("engine");

    let output = engine.translate(input).expect("translation result");

    assert_eq!(output.text, "你好");
    assert_eq!(output.provider, "openai-compatible");
    server.join().unwrap();
}

fn serve_once(body: &'static str) -> (String, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = [0_u8; 16 * 1024];
        let _ = stream.read(&mut request).unwrap();
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream.write_all(response.as_bytes()).unwrap();
    });

    (format!("http://{address}/v1"), server)
}
