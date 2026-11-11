use std::io;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("io: {0}")]
    Io(#[from] io::Error),
    #[error("vfs: {0}")]
    Vfs(#[from] vfs_core::VfsError),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("tls: {0}")]
    Tls(#[from] rustls::Error),
    #[error("certificate: {0}")]
    Certificate(String),
    #[error("protocol: {0}")]
    Protocol(String),
    #[error("not running")]
    NotRunning,
}

pub type Result<T> = std::result::Result<T, Error>;
