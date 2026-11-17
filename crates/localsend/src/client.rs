use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use rand::RngCore;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;
use vfs_core::{EntryKind, Vfs};

use crate::cert::Identity;
use crate::error::{Error, Result};
use crate::http;
use crate::protocol::{DeviceInfo, PrepareUpload, PrepareUploadResponse, PreparedFile};

/// A peer seen via multicast or `/register`.
#[derive(Debug, Clone)]
pub struct DiscoveredPeer {
    pub alias: String,
    pub ip: IpAddr,
    pub port: u16,
    pub fingerprint: String,
    pub device_type: String,
    pub last_seen_ms: u64,
}

impl DiscoveredPeer {
    pub fn fingerprint_bytes(&self) -> Option<[u8; 32]> {
        parse_fingerprint(&self.fingerprint)
    }
}

/// Stateless client for sending files / probing a peer.
pub struct LocalSendClient;

impl LocalSendClient {
    pub async fn register(
        ip: IpAddr,
        port: u16,
        info: &DeviceInfo,
        identity: &Identity,
        expected: Option<[u8; 32]>,
    ) -> Result<DeviceInfo> {
        register_at(ip, port, info, identity, expected).await
    }

    pub async fn send(
        vfs: &Arc<Vfs>,
        info: &DeviceInfo,
        identity: &Identity,
        peer: &DiscoveredPeer,
        files: Vec<String>,
    ) -> Result<()> {
        send_files(vfs, info, identity, peer, files, None).await
    }
}

pub async fn register_at(
    ip: IpAddr,
    port: u16,
    info: &DeviceInfo,
    identity: &Identity,
    expected: Option<[u8; 32]>,
) -> Result<DeviceInfo> {
    let body = serde_json::to_vec(info)?;
    let (status, response) = request(
        ip,
        port,
        "POST",
        "/api/localsend/v2/register",
        &body,
        identity,
        expected,
    )
    .await?;
    if status != 200 {
        return Err(Error::Protocol(format!(
            "register returned {status}: {}",
            String::from_utf8_lossy(&response)
        )));
    }
    Ok(serde_json::from_slice(&response)?)
}

pub async fn send_files(
    vfs: &Arc<Vfs>,
    info: &DeviceInfo,
    identity: &Identity,
    peer: &DiscoveredPeer,
    files: Vec<String>,
    pin: Option<&str>,
) -> Result<()> {
    if files.is_empty() {
        return Ok(());
    }
    let expected = peer.fingerprint_bytes();

    let mut prepared = HashMap::new();
    let mut id_to_vfs = HashMap::new();
    for vfs_id in files {
        let entry = vfs.stat(&vfs_id).await?;
        if entry.kind == EntryKind::Directory {
            return Err(Error::Protocol(format!("「{}」是文件夹", entry.name)));
        }
        let file_id = random_hex(8);
        id_to_vfs.insert(file_id.clone(), vfs_id);
        prepared.insert(
            file_id.clone(),
            PreparedFile {
                id: file_id,
                file_name: entry.name,
                size: entry.size,
                file_type: entry
                    .mime
                    .unwrap_or_else(|| "application/octet-stream".into()),
                sha256: None,
                preview: None,
                metadata: None,
            },
        );
    }

    let body = serde_json::to_vec(&PrepareUpload {
        info: Some(info.clone()),
        files: crate::protocol::Files::Map(prepared),
    })?;
    let path = match pin.filter(|p| !p.is_empty()) {
        Some(pin) => format!("/api/localsend/v2/prepare-upload?pin={pin}"),
        None => "/api/localsend/v2/prepare-upload".into(),
    };
    let (status, response) =
        request(peer.ip, peer.port, "POST", &path, &body, identity, expected).await?;
    if status == 204 {
        return Ok(());
    }
    if status != 200 {
        return Err(Error::Protocol(format!(
            "prepare-upload returned {status}: {}",
            String::from_utf8_lossy(&response)
        )));
    }
    let prepared: PrepareUploadResponse = serde_json::from_slice(&response)?;
    let session_id = prepared.session_id;
    for (file_id, token) in prepared.files {
        let Some(vfs_id) = id_to_vfs.get(&file_id) else {
            continue;
        };
        let entry = vfs.stat(vfs_id).await?;
        let upload_path = format!(
            "/api/localsend/v2/upload?sessionId={session_id}&fileId={file_id}&token={token}"
        );
        upload_one(
            vfs,
            peer.ip,
            peer.port,
            &upload_path,
            vfs_id,
            entry.size,
            identity,
            expected,
        )
        .await?;
    }
    Ok(())
}

/// Connect with TLS. Some peers require SNI (rustls cert resolvers), so if
/// the IP-literal handshake fails, retry once with a DNS name; the pinned
/// verifier ignores the hostname and still checks the certificate fingerprint.
async fn tls_connect(
    ip: IpAddr,
    port: u16,
    identity: &Identity,
    expected: Option<[u8; 32]>,
) -> Result<tokio_rustls::client::TlsStream<TcpStream>> {
    let connector = TlsConnector::from(client_config(identity, expected)?);
    let tcp = TcpStream::connect(SocketAddr::new(ip, port)).await?;
    match connector
        .connect(ServerName::IpAddress(ip.into()), tcp)
        .await
    {
        Ok(stream) => Ok(stream),
        Err(first) => {
            let tcp = TcpStream::connect(SocketAddr::new(ip, port)).await?;
            let name = ServerName::try_from("localsend.local").map_err(|_| Error::Io(first))?;
            connector.connect(name, tcp).await.map_err(Error::Io)
        }
    }
}

async fn upload_one(
    vfs: &Arc<Vfs>,
    ip: IpAddr,
    port: u16,
    path: &str,
    vfs_id: &str,
    size: u64,
    identity: &Identity,
    expected: Option<[u8; 32]>,
) -> Result<()> {
    let mut tls = tls_connect(ip, port, identity, expected).await?;

    let head = format!(
        "POST {path} HTTP/1.1\r\nHost: {ip}:{port}\r\nConnection: close\r\nContent-Type: application/octet-stream\r\nContent-Length: {size}\r\n\r\n"
    );
    tls.write_all(head.as_bytes()).await?;
    let mut offset = 0u64;
    while offset < size {
        let want = ((size - offset) as usize).min(256 * 1024);
        let chunk = vfs.read_range(vfs_id, offset, want).await?;
        if chunk.is_empty() {
            return Err(Error::Protocol("file shrank while uploading".into()));
        }
        tls.write_all(&chunk).await?;
        offset += chunk.len() as u64;
    }
    tls.flush().await?;

    let mut reader = BufReader::new(tls);
    let mut status_line = String::new();
    reader.read_line(&mut status_line).await?;
    let headers = http::read_headers(&mut reader).await?;
    let status = parse_status_line(&status_line)?;
    if status != 200 {
        let len = headers
            .get("content-length")
            .and_then(|v| v.parse().ok())
            .unwrap_or(0u64);
        let body = http::read_body(&mut reader, len, false, 64 * 1024)
            .await
            .unwrap_or_default();
        return Err(Error::Protocol(format!(
            "upload returned {status}: {}",
            String::from_utf8_lossy(&body)
        )));
    }
    Ok(())
}

async fn request(
    ip: IpAddr,
    port: u16,
    method: &str,
    path: &str,
    body: &[u8],
    identity: &Identity,
    expected: Option<[u8; 32]>,
) -> Result<(u16, Vec<u8>)> {
    let mut tls = tls_connect(ip, port, identity, expected).await?;
    let head = format!(
        "{method} {path} HTTP/1.1\r\nHost: {ip}:{port}\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
        body.len()
    );
    tls.write_all(head.as_bytes()).await?;
    tls.write_all(body).await?;
    tls.flush().await?;

    let mut reader = BufReader::new(tls);
    let mut status_line = String::new();
    reader.read_line(&mut status_line).await?;
    let status = parse_status_line(&status_line)?;
    let headers = http::read_headers(&mut reader).await?;
    let len = headers
        .get("content-length")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0u64);
    let chunked = headers
        .get("transfer-encoding")
        .map(|v| v.to_ascii_lowercase().contains("chunked"))
        .unwrap_or(false);
    let body = http::read_body(&mut reader, len, chunked, 4 * 1024 * 1024).await?;
    Ok((status, body))
}

fn parse_status_line(line: &str) -> Result<u16> {
    line.split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| Error::Protocol(format!("bad status line: {line:?}")))
}

fn client_config(identity: &Identity, expected: Option<[u8; 32]>) -> Result<Arc<ClientConfig>> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let certs = rustls_pemfile::certs(&mut identity.cert_pem.as_bytes())
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|e| Error::Certificate(format!("parse client cert chain: {e}")))?;
    let key = rustls_pemfile::private_key(&mut identity.key_pem.as_bytes())
        .map_err(|e| Error::Certificate(format!("parse client key: {e}")))?
        .ok_or_else(|| Error::Certificate("missing client private key".into()))?;
    let mut config = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("TLS versions")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(PinnedVerifier { expected }))
        // LocalSend v2.2 mutual TLS: present our device certificate so the
        // receiver can verify/identify us (and it is mandatory on the
        // official implementation when web share is disabled).
        .with_client_auth_cert(certs, key)
        .map_err(|e| Error::Certificate(format!("client auth cert: {e}")))?;
    // We only speak HTTP/1.1; advertising it avoids `no_application_protocol`
    // alerts from peers that require ALPN.
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(Arc::new(config))
}

#[derive(Debug)]
struct PinnedVerifier {
    expected: Option<[u8; 32]>,
}

impl ServerCertVerifier for PinnedVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
        let got = Sha256::digest(end_entity.as_ref());
        if let Some(expected) = self.expected {
            if got.as_slice() != expected {
                return Err(rustls::Error::General(
                    "certificate fingerprint mismatch".into(),
                ));
            }
        }
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        // Advertise every common scheme: self-signed peers may use RSA,
        // ECDSA P-256/P-384/P-521 or Ed25519, and a short list can make the
        // handshake fail with "received fatal alert" before our verifier runs.
        vec![
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::ECDSA_NISTP384_SHA384,
            SignatureScheme::ECDSA_NISTP521_SHA512,
            SignatureScheme::ED25519,
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PSS_SHA512,
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::RSA_PKCS1_SHA384,
            SignatureScheme::RSA_PKCS1_SHA512,
        ]
    }
}

fn parse_fingerprint(value: &str) -> Option<[u8; 32]> {
    if value.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, chunk) in value.as_bytes().chunks(2).enumerate() {
        let hi = (chunk[0] as char).to_digit(16)?;
        let lo = (chunk[1] as char).to_digit(16)?;
        out[i] = (hi * 16 + lo) as u8;
    }
    Some(out)
}

fn random_hex(bytes: usize) -> String {
    let mut raw = vec![0u8; bytes];
    rand::thread_rng().fill_bytes(&mut raw);
    let mut out = String::with_capacity(bytes * 2);
    for b in raw {
        out.push_str(&format!("{b:02x}"));
    }
    out
}
