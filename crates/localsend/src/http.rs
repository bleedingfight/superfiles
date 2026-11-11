use std::collections::HashMap;

use serde::Serialize;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub struct Head {
    pub method: String,
    pub target: String,
    pub headers: HashMap<String, String>,
}

impl Head {
    pub fn content_length(&self) -> u64 {
        self.headers
            .get("content-length")
            .and_then(|v| v.parse().ok())
            .unwrap_or(0)
    }

    pub fn is_chunked(&self) -> bool {
        self.headers
            .get("transfer-encoding")
            .map(|v| v.to_ascii_lowercase().contains("chunked"))
            .unwrap_or(false)
    }

    pub fn wants_continue(&self) -> bool {
        self.headers
            .get("expect")
            .map(|v| v.eq_ignore_ascii_case("100-continue"))
            .unwrap_or(false)
    }
}

/// Read one request head. `Ok(None)` when the peer closed before sending one.
pub async fn read_head<R: AsyncBufRead + Unpin>(reader: &mut R) -> std::io::Result<Option<Head>> {
    let mut line = String::new();
    if reader.read_line(&mut line).await? == 0 {
        return Ok(None);
    }
    let mut parts = line.trim_end().split_whitespace();
    let (Some(method), Some(target), Some(_)) = (parts.next(), parts.next(), parts.next()) else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "bad request line",
        ));
    };
    let method = method.to_ascii_uppercase();
    let target = target.to_string();

    let headers = read_headers(reader).await?;
    Ok(Some(Head {
        method,
        target,
        headers,
    }))
}

/// Read headers (after a request/status line) until the blank line.
pub async fn read_headers<R: AsyncBufRead + Unpin>(
    reader: &mut R,
) -> std::io::Result<HashMap<String, String>> {
    let mut headers = HashMap::new();
    let mut total = 0usize;
    loop {
        let mut h = String::new();
        if reader.read_line(&mut h).await? == 0 {
            break;
        }
        total += h.len();
        if total > 64 * 1024 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "headers too large",
            ));
        }
        let h = h.trim_end_matches(['\r', '\n']);
        if h.is_empty() {
            break;
        }
        if let Some((k, v)) = h.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    Ok(headers)
}

pub async fn read_body<R: AsyncBufRead + Unpin>(
    reader: &mut R,
    len: u64,
    chunked: bool,
    cap: usize,
) -> std::io::Result<Vec<u8>> {
    if chunked {
        return read_chunked(reader, cap).await;
    }
    if len > cap as u64 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "body too large",
        ));
    }
    let mut buf = vec![0u8; len as usize];
    reader.read_exact(&mut buf).await?;
    Ok(buf)
}

/// Decode a `Transfer-Encoding: chunked` body into memory (JSON endpoints
/// only; upload bodies are streamed by the server).
pub async fn read_chunked<R: AsyncBufRead + Unpin>(
    reader: &mut R,
    cap: usize,
) -> std::io::Result<Vec<u8>> {
    let mut out = Vec::new();
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).await? == 0 {
            break;
        }
        let size_str = line.trim().split(';').next().unwrap_or("").trim();
        let size = usize::from_str_radix(size_str, 16).map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, "bad chunk size")
        })?;
        if size == 0 {
            // Consume trailers until the blank line.
            loop {
                let mut trailer = String::new();
                if reader.read_line(&mut trailer).await? == 0 || trailer.trim().is_empty() {
                    break;
                }
            }
            break;
        }
        if out.len() + size > cap {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "body too large",
            ));
        }
        let start = out.len();
        out.resize(start + size, 0);
        reader.read_exact(&mut out[start..]).await?;
        let mut crlf = [0u8; 2];
        reader.read_exact(&mut crlf).await?;
    }
    Ok(out)
}

pub async fn respond_json<W: AsyncWrite + Unpin>(
    writer: &mut W,
    status: u16,
    value: &impl Serialize,
) -> std::io::Result<()> {
    let body = serde_json::to_vec(value)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    respond_bytes(writer, status, "application/json", &body).await
}

pub async fn respond_bytes<W: AsyncWrite + Unpin>(
    writer: &mut W,
    status: u16,
    content_type: &str,
    body: &[u8],
) -> std::io::Result<()> {
    let head = format!(
        "HTTP/1.1 {status} {}\r\nConnection: close\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\n\r\n",
        status_text(status),
        body.len()
    );
    writer.write_all(head.as_bytes()).await?;
    writer.write_all(body).await?;
    writer.flush().await
}

pub async fn respond_empty<W: AsyncWrite + Unpin>(
    writer: &mut W,
    status: u16,
) -> std::io::Result<()> {
    let head = format!(
        "HTTP/1.1 {status} {}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
        status_text(status)
    );
    writer.write_all(head.as_bytes()).await?;
    writer.flush().await
}

fn status_text(status: u16) -> &'static str {
    match status {
        100 => "Continue",
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Payload Too Large",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        _ => "Internal Server Error",
    }
}

pub fn query_param(target: &str, key: &str) -> Option<String> {
    let (_, query) = target.split_once('?')?;
    for pair in query.split('&') {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        if k == key {
            return Some(percent_decode(v));
        }
    }
    None
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = (bytes[i + 1] as char).to_digit(16);
            let lo = (bytes[i + 2] as char).to_digit(16);
            if let (Some(hi), Some(lo)) = (hi, lo) {
                out.push((hi * 16 + lo) as u8);
                i += 3;
                continue;
            }
        }
        out.push(if bytes[i] == b'+' { b' ' } else { bytes[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_query_values() {
        assert_eq!(
            query_param("/x?sessionId=abc&token=1%2F2", "token").as_deref(),
            Some("1/2")
        );
        assert_eq!(query_param("/x?pin=123456", "pin").as_deref(), Some("123456"));
        assert_eq!(query_param("/x", "pin"), None);
    }
}

#[cfg(test)]
mod chunked_tests {
    use super::*;

    #[tokio::test]
    async fn decodes_chunked_body() {
        let raw = b"4\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Trailer: 1\r\n\r\n";
        let mut reader: &[u8] = raw;
        let out = read_chunked(&mut reader, 1024).await.unwrap();
        assert_eq!(out, b"Wikipedia");
    }
}
