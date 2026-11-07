//! Minimal HTTP/1.1 framing, hand-rolled to keep the crate dependency-free:
//! one request per connection (`Connection: close`), headers capped at 16 KiB.
//! Loopback media serving is a seek-storm of tiny requests, not a bulk
//! channel, so connection setup cost on 127.0.0.1 is noise.

use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::timeout;

use vfs_core::VfsError;

const HEADER_CAP: usize = 16 * 1024;
const READ_TIMEOUT: Duration = Duration::from_secs(30);

pub struct Request {
    pub method: String,
    pub path: String,
    pub range: Option<String>,
}

/// Read exactly one request; `Ok(None)` when the peer closed cleanly.
pub async fn read_request(stream: &mut TcpStream) -> std::io::Result<Option<Request>> {
    let mut buf = Vec::with_capacity(2048);
    let mut chunk = [0u8; 4096];
    let header_end = loop {
        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break pos;
        }
        if buf.len() >= HEADER_CAP {
            respond(stream, 431, "headers too large", &[]).await.ok();
            return Ok(None);
        }
        match timeout(READ_TIMEOUT, stream.read(&mut chunk)).await {
            Ok(Ok(0)) if buf.is_empty() => return Ok(None),
            Ok(Ok(0)) => {
                respond(stream, 400, "truncated request", &[]).await.ok();
                return Ok(None);
            }
            Ok(Ok(n)) => buf.extend_from_slice(&chunk[..n]),
            Ok(Err(e)) => return Err(e),
            Err(_) => {
                respond(stream, 408, "request timeout", &[]).await.ok();
                return Ok(None);
            }
        }
    };

    let head = String::from_utf8_lossy(&buf[..header_end]).into_owned();
    let mut lines = head.split("\r\n");
    let Some(line) = lines.next() else {
        respond(stream, 400, "bad request", &[]).await.ok();
        return Ok(None);
    };
    let mut parts = line.split_whitespace();
    let (Some(method), Some(path), Some(_version)) = (parts.next(), parts.next(), parts.next())
    else {
        respond(stream, 400, "bad request line", &[]).await.ok();
        return Ok(None);
    };
    let range = lines
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.trim().eq_ignore_ascii_case("range"))
        .map(|(_, v)| v.trim().to_string());

    Ok(Some(Request {
        method: method.to_ascii_uppercase(),
        path: path.to_string(),
        range,
    }))
}

pub async fn respond(
    stream: &mut TcpStream,
    status: u16,
    text: &str,
    extra_headers: &[(&str, &str)],
) -> std::io::Result<()> {
    let mut out = format!("HTTP/1.1 {status} {text}\r\nConnection: close\r\n");
    for (name, value) in extra_headers {
        out.push_str(&format!("{name}: {value}\r\n"));
    }
    out.push_str("\r\n");
    stream.write_all(out.as_bytes()).await
}

/// Map core errors onto HTTP semantics for the player-facing surface.
pub fn status_for(err: &VfsError) -> (u16, &'static str) {
    match err {
        VfsError::NotFound(_) => (404, "Not Found"),
        VfsError::PermissionDenied(_) => (403, "Forbidden"),
        VfsError::Unsupported(_) => (404, "Not Found"), // no backend -> same as missing
        VfsError::Cancelled => (500, "Cancelled"),
        _ => (500, "Internal Server Error"),
    }
}

/// Percent-encode an entry id for the URL path; `/` stays as separator.
pub fn encode_id(id: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(id.len());
    for &b in id.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' => out.push(b as char),
            b'-' | b'.' | b'_' | b'~' | b'/' | b'$' | b'&' | b'+' | b',' | b':' | b';' | b'='
            | b'@' | b'!' | b'\'' | b'(' | b')' | b'*' => out.push(b as char),
            _ => {
                out.push('%');
                out.push(HEX[(b >> 4) as usize] as char);
                out.push(HEX[(b & 0xF) as usize] as char);
            }
        }
    }
    out
}

pub fn decode_id(path: &str) -> Option<String> {
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return None;
            }
            let hi = hex(bytes[i + 1])?;
            let lo = hex(bytes[i + 2])?;
            out.push(hi << 4 | lo);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn id_encoding_roundtrip() {
        let id = "webdav://nas:5006/我的 photos/cat (1)#.jpg?x";
        let encoded = encode_id(id);
        assert_eq!(decode_id(&encoded).as_deref(), Some(id));
        assert_eq!(decode_id("a%2F%zz"), None);
        assert_eq!(decode_id("plain/path"), Some("plain/path".into()));
    }
}
