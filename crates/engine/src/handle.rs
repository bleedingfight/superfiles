use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::RwLock;

use vfs_core::CancelToken;

/// Lifecycle of a transfer task.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferState {
    Queued,
    Running,
    Completed,
    Failed,
    Cancelled,
}

impl TransferState {
    fn code(self) -> u8 {
        match self {
            TransferState::Queued => 0,
            TransferState::Running => 1,
            TransferState::Completed => 2,
            TransferState::Failed => 3,
            TransferState::Cancelled => 4,
        }
    }

    fn from_code(code: u8) -> Self {
        match code {
            1 => TransferState::Running,
            2 => TransferState::Completed,
            3 => TransferState::Failed,
            4 => TransferState::Cancelled,
            _ => TransferState::Queued,
        }
    }
}

/// Immutable snapshot of a transfer, safe to hand to Swift/Kotlin.
#[derive(Debug, Clone)]
pub struct TransferSnapshot {
    pub id: String,
    pub state: TransferState,
    pub bytes_done: u64,
    pub bytes_total: u64,
    pub files_done: u64,
    pub files_total: u64,
    pub current: Option<String>,
    pub error: Option<String>,
}

/// Thread-safe progress handle.
///
/// The UI polls this (or the FFI wrapper polls it) instead of receiving a
/// callback across the FFI boundary. Polling is intentionally boring: it cannot
/// deadlock, it survives app backgrounding, and it is trivial to map onto
/// `AsyncSequence` (Swift) and `Flow` (Kotlin).
pub struct TransferHandle {
    id: String,
    state: AtomicU8,
    bytes_done: AtomicU64,
    bytes_total: AtomicU64,
    files_done: AtomicU64,
    files_total: AtomicU64,
    current: RwLock<Option<String>>,
    error: RwLock<Option<String>>,
    cancel: CancelToken,
}

impl TransferHandle {
    pub fn new(id: impl Into<String>, cancel: CancelToken) -> Self {
        Self {
            id: id.into(),
            state: AtomicU8::new(TransferState::Queued.code()),
            bytes_done: AtomicU64::new(0),
            bytes_total: AtomicU64::new(0),
            files_done: AtomicU64::new(0),
            files_total: AtomicU64::new(0),
            current: RwLock::new(None),
            error: RwLock::new(None),
            cancel,
        }
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn snapshot(&self) -> TransferSnapshot {
        TransferSnapshot {
            id: self.id.clone(),
            state: TransferState::from_code(self.state.load(Ordering::SeqCst)),
            bytes_done: self.bytes_done.load(Ordering::SeqCst),
            bytes_total: self.bytes_total.load(Ordering::SeqCst),
            files_done: self.files_done.load(Ordering::SeqCst),
            files_total: self.files_total.load(Ordering::SeqCst),
            current: self.current.read().unwrap().clone(),
            error: self.error.read().unwrap().clone(),
        }
    }

    pub fn cancel(&self) {
        self.cancel.cancel();
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.is_cancelled()
    }

    pub fn cancel_token(&self) -> CancelToken {
        self.cancel.clone()
    }

    pub fn set_running(&self) {
        self.state
            .store(TransferState::Running.code(), Ordering::SeqCst);
    }

    pub fn set_totals(&self, files: u64, bytes: u64) {
        self.files_total.store(files, Ordering::SeqCst);
        self.bytes_total.store(bytes, Ordering::SeqCst);
    }

    pub fn set_current(&self, name: Option<String>) {
        *self.current.write().unwrap() = name;
    }

    pub fn add_bytes(&self, bytes: u64) {
        self.bytes_done.fetch_add(bytes, Ordering::SeqCst);
    }

    pub fn complete_file(&self) {
        self.files_done.fetch_add(1, Ordering::SeqCst);
    }

    pub fn finish_ok(&self) {
        self.state
            .store(TransferState::Completed.code(), Ordering::SeqCst);
        self.set_current(None);
    }

    pub fn finish_cancelled(&self) {
        self.state
            .store(TransferState::Cancelled.code(), Ordering::SeqCst);
        self.set_current(None);
    }

    pub fn finish_err(&self, message: impl Into<String>) {
        *self.error.write().unwrap() = Some(message.into());
        self.state
            .store(TransferState::Failed.code(), Ordering::SeqCst);
        self.set_current(None);
    }
}
