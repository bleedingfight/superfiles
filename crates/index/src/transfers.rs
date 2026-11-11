//! Transfer task persistence (M1).
//!
//! A row in the `transfers` table carries everything needed to resume a copy
//! after the process was killed: the original source list and destination,
//! the scan totals, progress counters, and a per-file byte-offset checkpoint
//! map. Rows in `queued`/`running` state are considered unfinished (a clean
//! shutdown or a crash leaves them in `running`; only an explicit finish
//! moves them out). JSON is used for the two embedded documents because the
//! schema stays stable even as the checkpoint format evolves.

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use vfs_core::{Result, VfsError};

use crate::db_err;

/// Lifecycle states mirrored from `sfiles-engine`'s `TransferState`. Stored
/// as text so rows stay readable with a plain sqlite3 shell.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferTaskState {
    Queued,
    Running,
    Completed,
    Failed,
    Cancelled,
}

impl TransferTaskState {
    pub fn as_str(self) -> &'static str {
        match self {
            TransferTaskState::Queued => "queued",
            TransferTaskState::Running => "running",
            TransferTaskState::Completed => "completed",
            TransferTaskState::Failed => "failed",
            TransferTaskState::Cancelled => "cancelled",
        }
    }

    fn from_str(state: &str) -> Self {
        match state {
            "running" => TransferTaskState::Running,
            "completed" => TransferTaskState::Completed,
            "failed" => TransferTaskState::Failed,
            "cancelled" => TransferTaskState::Cancelled,
            _ => TransferTaskState::Queued,
        }
    }
}

/// Per-file checkpoint: how many bytes of `source_id` had been written to
/// the destination when the record was persisted. `size` pins the source
/// length at record time; a size mismatch on resume means the source changed
/// and the file restarts from zero. `offset >= size` marks the file done.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileOffset {
    pub source_id: String,
    pub size: u64,
    pub offset: u64,
}

/// A `transfers` row decoded for callers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredTransfer {
    pub id: String,
    pub sources: Vec<String>,
    pub dest_dir: String,
    /// 移动任务（复制成功后删除源）。持久化是为了进程被杀后恢复仍能完成删除。
    pub is_move: bool,
    pub state: TransferTaskState,
    pub files_total: u64,
    pub files_done: u64,
    pub bytes_total: u64,
    pub bytes_done: u64,
    /// Checkpoints keyed implicitly by `FileOffset::source_id`.
    pub file_offsets: Vec<FileOffset>,
    pub error: Option<String>,
    /// Unix epoch milliseconds; managed by the index on writes.
    pub created_at: i64,
    pub updated_at: i64,
}

impl StoredTransfer {
    /// Build a fresh `running` row. Progress starts at zero; timestamps are
    /// stamped by [`save_transfer`].
    pub fn new_running(
        id: impl Into<String>,
        sources: Vec<String>,
        dest_dir: impl Into<String>,
        files_total: u64,
        bytes_total: u64,
    ) -> Self {
        Self {
            id: id.into(),
            sources,
            dest_dir: dest_dir.into(),
            is_move: false,
            state: TransferTaskState::Running,
            files_total,
            files_done: 0,
            bytes_total,
            bytes_done: 0,
            file_offsets: Vec::new(),
            error: None,
            created_at: 0,
            updated_at: 0,
        }
    }
}

/// DDL executed from `Index::migrate`.
pub(super) const TRANSFERS_SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS transfers (
    id                TEXT PRIMARY KEY,
    sources_json      TEXT NOT NULL,
    dest_dir          TEXT NOT NULL,
    is_move           INTEGER NOT NULL DEFAULT 0,
    state             TEXT NOT NULL,
    files_total       INTEGER NOT NULL DEFAULT 0,
    files_done        INTEGER NOT NULL DEFAULT 0,
    bytes_total       INTEGER NOT NULL DEFAULT 0,
    bytes_done        INTEGER NOT NULL DEFAULT 0,
    file_offsets_json TEXT NOT NULL DEFAULT '[]',
    error             TEXT,
    created_at        INTEGER NOT NULL DEFAULT 0,
    updated_at        INTEGER NOT NULL DEFAULT 0
);
"#;

/// Insert or update a transfer row. `created_at` is stamped on first insert
/// and preserved on conflict; `updated_at` always moves to now.
pub(super) fn save_transfer(conn: &Connection, transfer: &StoredTransfer) -> Result<()> {
    let now = now_ms();
    conn.execute(
        r#"INSERT INTO transfers
             (id, sources_json, dest_dir, is_move, state,
              files_total, files_done, bytes_total, bytes_done,
              file_offsets_json, error, created_at, updated_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
           ON CONFLICT(id) DO UPDATE SET
             sources_json=excluded.sources_json, dest_dir=excluded.dest_dir,
             is_move=excluded.is_move, state=excluded.state,
             files_total=excluded.files_total, files_done=excluded.files_done,
             bytes_total=excluded.bytes_total, bytes_done=excluded.bytes_done,
             file_offsets_json=excluded.file_offsets_json, error=excluded.error,
             updated_at=excluded.updated_at"#,
        params![
            transfer.id,
            to_json(&transfer.sources)?,
            transfer.dest_dir,
            transfer.is_move as i32,
            transfer.state.as_str(),
            transfer.files_total as i64,
            transfer.files_done as i64,
            transfer.bytes_total as i64,
            transfer.bytes_done as i64,
            to_json(&transfer.file_offsets)?,
            transfer.error,
            if transfer.created_at > 0 {
                transfer.created_at
            } else {
                now
            },
            now,
        ],
    )
    .map_err(db_err)?;
    Ok(())
}

/// Checkpoint write during a running transfer: progress counters plus the
/// per-file offset map, nothing else.
pub(super) fn update_transfer_progress(
    conn: &Connection,
    id: &str,
    files_done: u64,
    bytes_done: u64,
    file_offsets: &[FileOffset],
) -> Result<()> {
    conn.execute(
        "UPDATE transfers
         SET files_done = ?2, bytes_done = ?3, file_offsets_json = ?4, updated_at = ?5
         WHERE id = ?1",
        params![
            id,
            files_done as i64,
            bytes_done as i64,
            to_json(file_offsets)?,
            now_ms()
        ],
    )
    .map_err(db_err)?;
    Ok(())
}

/// Move a transfer into its terminal state.
pub(super) fn finish_transfer(
    conn: &Connection,
    id: &str,
    state: TransferTaskState,
    error: Option<&str>,
) -> Result<()> {
    conn.execute(
        "UPDATE transfers SET state = ?2, error = ?3, updated_at = ?4 WHERE id = ?1",
        params![id, state.as_str(), error, now_ms()],
    )
    .map_err(db_err)?;
    Ok(())
}

/// Rows a restart should offer to resume, oldest first.
pub(super) fn load_unfinished_transfers(conn: &Connection) -> Result<Vec<StoredTransfer>> {
    let mut stmt = conn
        .prepare(
            "SELECT id, sources_json, dest_dir, is_move, state,
                    files_total, files_done, bytes_total, bytes_done,
                    file_offsets_json, error, created_at, updated_at
             FROM transfers
             WHERE state IN ('queued', 'running')
             ORDER BY created_at",
        )
        .map_err(db_err)?;
    let rows = stmt.query_map([], row_to_transfer).map_err(db_err)?;
    let mut transfers = Vec::new();
    for row in rows {
        transfers.push(row.map_err(db_err)?);
    }
    Ok(transfers)
}

pub(super) fn forget_transfer(conn: &Connection, id: &str) -> Result<()> {
    conn.execute("DELETE FROM transfers WHERE id = ?1", params![id])
        .map_err(db_err)?;
    Ok(())
}

fn row_to_transfer(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredTransfer> {
    let sources_json: String = row.get(1)?;
    let state: String = row.get(4)?;
    let offsets_json: String = row.get(9)?;
    Ok(StoredTransfer {
        id: row.get(0)?,
        // Malformed JSON in a row we wrote ourselves is data corruption;
        // degrade to empty so the row stays loadable instead of failing
        // the whole listing.
        sources: from_json(&sources_json).unwrap_or_default(),
        dest_dir: row.get(2)?,
        is_move: row.get::<_, i64>(3)? != 0,
        state: TransferTaskState::from_str(&state),
        files_total: row.get::<_, i64>(5)? as u64,
        files_done: row.get::<_, i64>(6)? as u64,
        bytes_total: row.get::<_, i64>(7)? as u64,
        bytes_done: row.get::<_, i64>(8)? as u64,
        file_offsets: from_json(&offsets_json).unwrap_or_default(),
        error: row.get(10)?,
        created_at: row.get(11)?,
        updated_at: row.get(12)?,
    })
}

fn to_json(value: &(impl Serialize + ?Sized)) -> Result<String> {
    serde_json::to_string(value).map_err(|err| VfsError::Io(format!("index json: {err}")))
}

fn from_json<T: for<'de> Deserialize<'de>>(json: &str) -> Option<T> {
    serde_json::from_str(json).ok()
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Index;

    fn stored(id: &str) -> StoredTransfer {
        StoredTransfer {
            is_move: false,
            id: id.to_string(),
            sources: vec!["local:///src/a".into(), "local:///src/b".into()],
            dest_dir: "local:///dst".into(),
            state: TransferTaskState::Running,
            files_total: 4,
            files_done: 1,
            bytes_total: 10_000,
            bytes_done: 6_144,
            file_offsets: vec![
                FileOffset {
                    source_id: "local:///src/a".into(),
                    size: 4096,
                    offset: 4096,
                },
                FileOffset {
                    source_id: "local:///src/b".into(),
                    size: 4096,
                    offset: 2048,
                },
            ],
            error: None,
            created_at: 0,
            updated_at: 0,
        }
    }

    #[test]
    fn transfer_roundtrip() {
        let index = Index::open_in_memory().unwrap();
        let mut transfer = stored("t1");
        index.save_transfer(&transfer).unwrap();

        let loaded = index.load_unfinished_transfers().unwrap();
        assert_eq!(loaded.len(), 1);
        let row = &loaded[0];
        transfer.created_at = row.created_at;
        transfer.updated_at = row.updated_at;
        assert_eq!(row, &transfer);
        assert!(row.created_at > 0);
        assert!(row.updated_at >= row.created_at);

        // Progress checkpoint: only counters and offsets move.
        index
            .update_transfer_progress(
                "t1",
                3,
                9_000,
                &[FileOffset {
                    source_id: "local:///src/b".into(),
                    size: 4096,
                    offset: 4096,
                }],
            )
            .unwrap();
        let row = &index.load_unfinished_transfers().unwrap()[0];
        assert_eq!(row.files_done, 3);
        assert_eq!(row.bytes_done, 9_000);
        assert_eq!(row.file_offsets.len(), 1);
        assert_eq!(row.file_offsets[0].offset, 4096);
        assert_eq!(row.bytes_total, 10_000, "totals must not be touched");

        // Finished rows leave the unfinished listing.
        index
            .finish_transfer("t1", TransferTaskState::Completed, None)
            .unwrap();
        assert!(index.load_unfinished_transfers().unwrap().is_empty());

        index
            .finish_transfer("t1", TransferTaskState::Failed, Some("disk full"))
            .unwrap();
        assert!(index.load_unfinished_transfers().unwrap().is_empty());

        index.forget_transfer("t1").unwrap();
        index.forget_transfer("t1").unwrap(); // idempotent
    }

    #[test]
    fn unfinished_survives_reopen() {
        // Simulate a crash: persist mid-transfer, drop the database without
        // finishing, then reopen and expect the row back.
        let dir = std::env::temp_dir().join(format!("sfiles-transfers-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("crash.sqlite");
        let _ = std::fs::remove_file(&path);

        {
            let index = Index::open(&path).unwrap();
            index.save_transfer(&stored("t-crash")).unwrap();
            index
                .update_transfer_progress(
                    "t-crash",
                    1,
                    6_144,
                    &[FileOffset {
                        source_id: "local:///src/b".into(),
                        size: 4096,
                        offset: 2048,
                    }],
                )
                .unwrap();
            // Dropped here without finish_transfer: the crash scenario.
        }

        let index = Index::open(&path).unwrap();
        let loaded = index.load_unfinished_transfers().unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].id, "t-crash");
        assert_eq!(loaded[0].state, TransferTaskState::Running);
        assert_eq!(loaded[0].bytes_done, 6_144);
        assert_eq!(loaded[0].file_offsets.len(), 1);
        assert_eq!(loaded[0].file_offsets[0].source_id, "local:///src/b");
        assert_eq!(loaded[0].file_offsets[0].offset, 2048);

        // A row finished before the "crash" must not come back.
        index
            .finish_transfer("t-crash", TransferTaskState::Cancelled, None)
            .unwrap();
        drop(index);
        let index = Index::open(&path).unwrap();
        assert!(index.load_unfinished_transfers().unwrap().is_empty());

        std::fs::remove_dir_all(&dir).unwrap();
    }
}
