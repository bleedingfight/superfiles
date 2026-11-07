use std::path::Path;

/// Result alias used across the whole core.
pub type Result<T> = std::result::Result<T, VfsError>;

/// Error taxonomy shared by every backend.
///
/// Keep this list small and semantic: UI code switches on these variants to
/// decide what to show, so adding a variant is an API change for both Swift and
/// Kotlin. Anything backend specific belongs in the payload.
#[derive(Debug, Clone, thiserror::Error)]
pub enum VfsError {
    #[error("not found: {0}")]
    NotFound(String),
    #[error("permission denied: {0}")]
    PermissionDenied(String),
    #[error("already exists: {0}")]
    AlreadyExists(String),
    #[error("unsupported operation: {0}")]
    Unsupported(String),
    #[error("network error: {0}")]
    Network(String),
    #[error("cancelled")]
    Cancelled,
    #[error("invalid name: {0}")]
    InvalidName(String),
    #[error("io error: {0}")]
    Io(String),
}

impl VfsError {
    pub fn io(err: std::io::Error) -> Self {
        match err.kind() {
            std::io::ErrorKind::NotFound => VfsError::NotFound(err.to_string()),
            std::io::ErrorKind::PermissionDenied => VfsError::PermissionDenied(err.to_string()),
            std::io::ErrorKind::AlreadyExists => VfsError::AlreadyExists(err.to_string()),
            _ => VfsError::Io(err.to_string()),
        }
    }

    pub fn io_at(path: &Path, err: std::io::Error) -> Self {
        match err.kind() {
            std::io::ErrorKind::NotFound => VfsError::NotFound(path.display().to_string()),
            std::io::ErrorKind::PermissionDenied => {
                VfsError::PermissionDenied(path.display().to_string())
            }
            std::io::ErrorKind::AlreadyExists => {
                VfsError::AlreadyExists(path.display().to_string())
            }
            _ => VfsError::Io(format!("{}: {}", path.display(), err)),
        }
    }
}
