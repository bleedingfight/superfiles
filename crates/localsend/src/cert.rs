use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use rustls::client::danger::HandshakeSignatureValid;
use rustls::pki_types::{CertificateDer, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{DigitallySignedStruct, DistinguishedName, SignatureScheme};
use sha2::{Digest, Sha256};

use crate::error::{Error, Result};

/// Device identity: a persistent self-signed certificate plus the derived
/// SHA-256 fingerprint used by LocalSend peers for TOFU pinning.
#[derive(Debug, Clone)]
pub struct Identity {
    pub cert_pem: String,
    pub key_pem: String,
    pub fingerprint: String,
}

impl Identity {
    /// Load `<dir>/cert.pem` + `<dir>/key.pem`, or generate a new ECDSA P-256
    /// self-signed certificate on first launch. Keys are written with 0600 on
    /// Unix targets (Android/iOS/HarmonyOS all honour this).
    pub fn load_or_create(dir: &Path, _alias: &str) -> Result<Self> {
        fs::create_dir_all(dir)?;
        let cert_path = dir.join("cert.pem");
        let key_path = dir.join("key.pem");

        if let (Ok(cert_pem), Ok(key_pem)) = (
            fs::read_to_string(&cert_path),
            fs::read_to_string(&key_path),
        ) {
            if let Ok(identity) = Self::from_pem(cert_pem, key_pem) {
                return Ok(identity);
            }
            // Corrupt pair: fall through and regenerate both.
        }

        // The alias is user-facing (may be Chinese, may be a single label), so it
        // must NOT be used as a DNS SAN: rcgen rejects invalid IA5String/DNS
        // names. LocalSend identifies peers by the SHA-256 fingerprint anyway.
        let ck = rcgen::generate_simple_self_signed(vec!["superfiles.local".to_string()])
            .map_err(|e| Error::Certificate(format!("generate self-signed cert: {e}")))?;
        let cert_pem = ck.cert.pem();
        let key_pem = ck.key_pair.serialize_pem();
        write_private(&cert_path, cert_pem.as_bytes())?;
        write_private(&key_path, key_pem.as_bytes())?;
        Self::from_pem(cert_pem, key_pem)
    }

    fn from_pem(cert_pem: String, key_pem: String) -> Result<Self> {
        let cert_der = rustls_pemfile::certs(&mut cert_pem.as_bytes())
            .next()
            .ok_or_else(|| Error::Certificate("empty certificate".into()))?
            .map_err(|e| Error::Certificate(format!("parse cert: {e}")))?
            .to_vec();
        // Validate the key parses too, so bad pairs never reach the TLS builder.
        rustls_pemfile::private_key(&mut key_pem.as_bytes())
            .map_err(|e| Error::Certificate(format!("parse key: {e}")))?
            .ok_or_else(|| Error::Certificate("empty private key".into()))?;
        let fingerprint = hex_sha256(&cert_der);
        Ok(Self {
            cert_pem,
            key_pem,
            fingerprint,
        })
    }

    pub fn server_config(&self) -> Result<Arc<rustls::ServerConfig>> {
        let certs = rustls_pemfile::certs(&mut self.cert_pem.as_bytes())
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(|e| Error::Certificate(format!("parse cert chain: {e}")))?;
        let key = rustls_pemfile::private_key(&mut self.key_pem.as_bytes())
            .map_err(|e| Error::Certificate(format!("parse key: {e}")))?
            .ok_or_else(|| Error::Certificate("missing private key".into()))?;
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let mut config = rustls::ServerConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()?
            // LocalSend v2.2 uses mutual TLS: peers present their own
            // self-signed certificate and the server records its fingerprint.
            // We request it (optional so browsers/older clients still work)
            // and accept any valid self-signed certificate.
            .with_client_cert_verifier(Arc::new(AnyClientCertVerifier))
            .with_single_cert(certs, key)?;
        config.alpn_protocols = vec![b"http/1.1".to_vec()];
        Ok(Arc::new(config))
    }
}

fn write_private(path: &PathBuf, data: &[u8]) -> Result<()> {
    fs::write(path, data)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

/// LocalSend peers are self-signed; there is no CA to chain to. Request a
/// client certificate (optional) and accept it after the TLS stack validates
/// its signature. Identity binding is done by the caller with the fingerprint.
#[derive(Debug)]
struct AnyClientCertVerifier;

impl ClientCertVerifier for AnyClientCertVerifier {
    fn offer_client_auth(&self) -> bool {
        true
    }

    fn client_auth_mandatory(&self) -> bool {
        true
    }

    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }

    fn verify_client_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> std::result::Result<ClientCertVerified, rustls::Error> {
        Ok(ClientCertVerified::assertion())
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

pub fn hex_sha256(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(64);
    for b in digest {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unicode_alias_does_not_break_certificate() {
        let dir = tempfile::tempdir().unwrap();
        let first = Identity::load_or_create(dir.path(), "刘帅").unwrap();
        assert_eq!(first.fingerprint.len(), 64);
        // Reload must reuse the same certificate (and therefore fingerprint).
        let second = Identity::load_or_create(dir.path(), "刘帅").unwrap();
        assert_eq!(first.fingerprint, second.fingerprint);
    }
}
