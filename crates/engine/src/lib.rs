pub mod handle;
pub mod transfer;
pub mod zip;

pub use handle::{TransferHandle, TransferSnapshot, TransferState};
// Re-exported so callers of `run_resumable` can load/store resume records
// without depending on sfiles-index themselves.
pub use sfiles_index::StoredTransfer;
pub use transfer::{run, run_resumable, ConflictPolicy, CopyOptions, CopyRuntimeState};
pub use zip::{compress_zip, ZipMethod};
