use async_trait::async_trait;

use crate::cancel::CancelToken;
use crate::capabilities::Capabilities;
use crate::entry::Entry;
use crate::error::{Result, VfsError};
use crate::fd;
use crate::DEFAULT_CHUNK_SIZE;

/// One storage backend (local disk, SMB share, cloud drive, ...).
///
/// Implementations are expected to be stateless per entry id: every call gets
/// the full id, so the backend can be used concurrently from the transfer
/// engine without session state.
///
/// `read_range` / `write_range` are the primitive operations. Streaming to a
/// platform owned file descriptor has a default implementation on top of them,
/// so a new backend only needs three I/O methods to be fully functional.
#[async_trait]
pub trait Backend: Send + Sync + 'static {
    fn scheme(&self) -> &'static str;

    fn capabilities(&self) -> Capabilities;

    fn display_name(&self) -> String {
        self.scheme().to_string()
    }

    async fn stat(&self, id: &str) -> Result<Entry>;

    async fn list(&self, id: &str) -> Result<Vec<Entry>>;

    async fn create_dir(&self, parent: &str, name: &str) -> Result<Entry>;

    async fn create_file(&self, parent: &str, name: &str) -> Result<Entry>;

    async fn remove(&self, id: &str, recursive: bool) -> Result<()>;

    async fn rename(&self, id: &str, new_name: &str) -> Result<Entry>;

    /// Read at most `len` bytes starting at `offset`. Short reads are allowed.
    async fn read_range(&self, id: &str, offset: u64, len: usize) -> Result<Vec<u8>>;

    /// Drop any progressive playback cache held for `id` (no-op by default).
    /// Players call this when playback stops so temp files do not linger.
    async fn release_stream_cache(&self, _id: &str) {}

    /// Write `data` at `offset`, creating the file when it does not exist.
    async fn write_range(&self, id: &str, offset: u64, data: &[u8]) -> Result<()>;

    async fn truncate(&self, id: &str, size: u64) -> Result<()>;

    /// Stream the whole file into a caller owned descriptor.
    async fn read_to_fd(
        &self,
        id: &str,
        fd: i32,
        offset: u64,
        cancel: &CancelToken,
    ) -> Result<u64> {
        let mut offset = offset;
        let mut written = 0u64;
        loop {
            if cancel.is_cancelled() {
                return Err(VfsError::Cancelled);
            }
            let chunk = self.read_range(id, offset, DEFAULT_CHUNK_SIZE).await?;
            if chunk.is_empty() {
                break;
            }
            let n = chunk.len() as u64;
            fd::write_all(fd, &chunk).map_err(VfsError::io)?;
            offset += n;
            written += n;
        }
        Ok(written)
    }

    /// Stream a caller owned descriptor into the file at `offset`.
    async fn write_from_fd(
        &self,
        id: &str,
        fd: i32,
        offset: u64,
        cancel: &CancelToken,
    ) -> Result<u64> {
        let mut offset = offset;
        let mut written = 0u64;
        let mut buf = vec![0u8; DEFAULT_CHUNK_SIZE];
        loop {
            if cancel.is_cancelled() {
                return Err(VfsError::Cancelled);
            }
            let n = fd::read_some(fd, &mut buf).map_err(VfsError::io)?;
            if n == 0 {
                break;
            }
            self.write_range(id, offset, &buf[..n]).await?;
            offset += n as u64;
            written += n as u64;
        }
        Ok(written)
    }
}
