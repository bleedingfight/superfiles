use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, AtomicU8, Ordering};
use std::sync::RwLock;
use std::time::{SystemTime, UNIX_EPOCH};

use vfs_core::CancelToken;

/// Epoch milliseconds (best effort; 0 when the clock predates the epoch).
fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Lifecycle of a transfer task.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferState {
    Queued,
    Running,
    /// 用户暂停（非终态）：任务仍占着注册表，可 unpause 继续或 cancel 终止。
    Paused,
    Completed,
    Failed,
    Cancelled,
}

impl TransferState {
    fn code(self) -> u8 {
        match self {
            TransferState::Queued => 0,
            TransferState::Running => 1,
            TransferState::Paused => 5,
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
            5 => TransferState::Paused,
            _ => TransferState::Queued,
        }
    }

    /// 任务是否已落定（不会再变）：完成 / 失败 / 已取消。
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            TransferState::Completed | TransferState::Failed | TransferState::Cancelled
        )
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
    /// 任务创建（开始）时间，epoch 毫秒。
    pub started_at_ms: i64,
    /// 结束时间（完成/失败/取消），未结束为 None。
    pub finished_at_ms: Option<i64>,
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
    started_at_ms: AtomicI64,
    finished_at_ms: AtomicI64,
    cancel: CancelToken,
    /// 暂停请求：工作循环在每个块边界检查；true 时循环停摆（状态 Paused），
    /// unpause 后继续。取消优先于暂停——暂停等待中 cancel 立即生效。
    pause_requested: AtomicBool,
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
            started_at_ms: AtomicI64::new(now_ms()),
            finished_at_ms: AtomicI64::new(0),
            cancel,
            pause_requested: AtomicBool::new(false),
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
            started_at_ms: self.started_at_ms.load(Ordering::SeqCst),
            finished_at_ms: {
                let v = self.finished_at_ms.load(Ordering::SeqCst);
                if v > 0 {
                    Some(v)
                } else {
                    None
                }
            },
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

    /// 请求暂停。标志先落、状态后改（先读状态再置标志会在 unpause→pause 的
    /// 瞬间丢请求）：UI 下一拍就能看到「已暂停」，工作循环在最近块边界停摆；
    /// 终态任务只置标志不改写状态。
    pub fn pause(&self) {
        self.pause_requested.store(true, Ordering::SeqCst);
        let current = TransferState::from_code(self.state.load(Ordering::SeqCst));
        if !current.is_terminal() && current != TransferState::Paused {
            self.state
                .store(TransferState::Paused.code(), Ordering::SeqCst);
        }
    }

    /// 解除暂停继续跑。只把仍停在 Paused 的任务拨回 Running；期间若已进入
    /// 终态（被取消），不越权改写。
    pub fn unpause(&self) {
        self.pause_requested.store(false, Ordering::SeqCst);
        if !self.is_pause_requested()
            && TransferState::from_code(self.state.load(Ordering::SeqCst)) == TransferState::Paused
        {
            self.state
                .store(TransferState::Running.code(), Ordering::SeqCst);
        }
    }

    pub fn is_pause_requested(&self) -> bool {
        self.pause_requested.load(Ordering::SeqCst)
    }

    /// 暂停闸门在等待中把行保持为 Paused（transfer.rs 调用）。与 pause() 并发
    /// 时自纠：下一拍重试，最坏 120ms 的显示抖动，不影响正确性。
    pub(crate) fn mark_paused(&self) {
        if !self.is_pause_requested() {
            return;
        }
        let current = TransferState::from_code(self.state.load(Ordering::SeqCst));
        if !current.is_terminal() && current != TransferState::Paused {
            self.state
                .store(TransferState::Paused.code(), Ordering::SeqCst);
        }
    }

    /// 暂停闸门退出时把停摆进 Paused 的行拨回 Running；若有新的暂停请求
    /// （或已终态），什么都不做。
    pub(crate) fn mark_running_if_paused(&self) {
        if self.is_pause_requested() {
            return;
        }
        if TransferState::from_code(self.state.load(Ordering::SeqCst)) == TransferState::Paused {
            self.state
                .store(TransferState::Running.code(), Ordering::SeqCst);
        }
    }

    pub fn set_running(&self) {
        // 带着暂停请求起跑的任务直接以 Paused 落面：第一道闸门会把它真正停住
        if self.is_pause_requested() {
            self.state
                .store(TransferState::Paused.code(), Ordering::SeqCst);
            return;
        }
        self.state
            .store(TransferState::Running.code(), Ordering::SeqCst);
    }

    pub fn set_totals(&self, files: u64, bytes: u64) {
        self.files_total.store(files, Ordering::SeqCst);
        self.bytes_total.store(bytes, Ordering::SeqCst);
    }

    /// Pre-loads progress recovered from a previous (crashed) run so the
    /// resumed copy's progress bar continues where the last one stopped
    /// instead of restarting at zero. Engine-internal (`transfer::run_resumable`).
    pub(crate) fn seed_progress(&self, files_done: u64, bytes_done: u64) {
        self.files_done.fetch_add(files_done, Ordering::SeqCst);
        self.bytes_done.fetch_add(bytes_done, Ordering::SeqCst);
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
        self.finished_at_ms.store(now_ms(), Ordering::SeqCst);
        // 保留最后的 current 文件名：传输记录条目用它做标题
    }

    pub fn finish_cancelled(&self) {
        self.state
            .store(TransferState::Cancelled.code(), Ordering::SeqCst);
        self.finished_at_ms.store(now_ms(), Ordering::SeqCst);
        // 保留最后的 current 文件名：传输记录条目用它做标题
    }

    pub fn finish_err(&self, message: impl Into<String>) {
        *self.error.write().unwrap() = Some(message.into());
        self.state
            .store(TransferState::Failed.code(), Ordering::SeqCst);
        self.finished_at_ms.store(now_ms(), Ordering::SeqCst);
        // 保留最后的 current 文件名：传输记录条目用它做标题
    }
}
