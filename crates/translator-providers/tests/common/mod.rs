//! Shared helpers for the provider contract tests.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::thread;

/// Answers one request on an ephemeral port and returns what the client sent.
///
/// The server runs on a background thread so the provider under test can make a
/// real request against it.
pub fn serve_once(body: &'static str) -> (String, thread::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("an ephemeral port");
    let address = listener.local_addr().expect("a bound address");

    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("an inbound request");
        let raw_request = read_request(&mut stream);
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream.write_all(response.as_bytes()).expect("a response");
        raw_request
    });

    (format!("http://{address}"), server)
}

/// Reads a complete HTTP request.
///
/// A single `read()` is not enough. The request line, the headers and the body
/// can arrive in separate TCP segments, and asserting on a partially read
/// request makes these tests fail intermittently — roughly one run in three
/// under parallel load. Keep reading until the header block is terminated and
/// the body bytes declared by `Content-Length` have arrived.
fn read_request(stream: &mut TcpStream) -> String {
    let mut buffer = Vec::new();
    let mut chunk = [0_u8; 4096];

    loop {
        let complete = match header_end(&buffer) {
            Some(end) => buffer.len() >= end + 4 + content_length(&buffer[..end]),
            None => false,
        };
        if complete {
            break;
        }

        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(count) => buffer.extend_from_slice(&chunk[..count]),
        }
    }

    String::from_utf8_lossy(&buffer).into_owned()
}

fn header_end(buffer: &[u8]) -> Option<usize> {
    buffer.windows(4).position(|window| window == b"\r\n\r\n")
}

fn content_length(header_block: &[u8]) -> usize {
    String::from_utf8_lossy(header_block)
        .to_ascii_lowercase()
        .lines()
        .find_map(|line| line.strip_prefix("content-length:"))
        .and_then(|value| value.trim().parse().ok())
        .unwrap_or(0)
}
