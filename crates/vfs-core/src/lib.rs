//! Portable virtual filesystem core.
//!
//! Everything in this crate is platform agnostic. Backends (local disk, SMB,
//! SFTP, WebDAV, S3, ...) implement [`Backend`] and are mounted into a [`Vfs`].
//! UI layers only ever talk to `Vfs` (usually through the `sfiles-ffi` crate).

pub mod backend;
pub mod backends;
pub mod cancel;
pub mod capabilities;
pub mod entry;
pub mod error;
pub mod fd;
pub mod netbios;
pub mod uri;
pub mod vfs;

pub use backend::Backend;
pub use cancel::CancelToken;
pub use capabilities::Capabilities;
pub use entry::{Entry, EntryKind};
pub use error::{Result, VfsError};
pub use vfs::Vfs;

/// Default chunk size used for streaming reads/writes (256 KiB).
///
/// Small enough to keep memory bounded on iOS extensions, large enough to keep
/// SMB/WebDAV round trips efficient.
pub const DEFAULT_CHUNK_SIZE: usize = 256 * 1024;
