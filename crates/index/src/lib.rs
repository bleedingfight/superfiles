//! Persistent metadata index.
//!
//! Purpose: show a directory instantly (even on a slow SMB share), support
//! offline browsing and global search, and keep transfer state across app
//! restarts. SQLite is used because it is available on every target and ships
//! with the OS on iOS/Android (we still bundle for consistency).
//!
//! Search defaults to FTS5 with the `trigram` tokenizer, which gives
//! case-insensitive substring matching that works uniformly for English,
//! Chinese and mixed text. Every name is additionally indexed with a pinyin
//! sidecar string ("电视" -> "dianshi ds"), so full-pinyin and pinyin-initial
//! queries hit too. The old escaped-LIKE path remains as the fallback for
//! queries whose tokens are all shorter than three characters (the trigram
//! index structurally cannot answer those) and as a safety net if the FTS
//! table is ever unusable.

use std::path::Path;
use std::sync::Mutex;

use pinyin::ToPinyin;
use rusqlite::{params, Connection, OptionalExtension};
use vfs_core::{Entry, EntryKind, Result, VfsError};

mod transfers;

pub use transfers::{FileOffset, StoredTransfer, TransferTaskState};

/// Source tag for entries indexed from the local file system. Remote
/// backends (WebDAV/SMB, M2) write with their own source tag so one index
/// can aggregate several mounts and still filter per mount.
pub const DEFAULT_SOURCE: &str = "local";

/// Minimum token length (in alphanumeric chars) that the trigram index can
/// answer; shorter queries go through the LIKE fallback.
const TRIGRAM_MIN: usize = 3;

pub struct Index {
    conn: Mutex<Connection>,
}

impl Index {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(VfsError::io)?;
        }
        let conn = Connection::open(path).map_err(db_err)?;
        // WAL keeps the UI responsive while a scan writes.
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(db_err)?;
        Self::from_conn(conn)
    }

    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory().map_err(db_err)?;
        Self::from_conn(conn)
    }

    fn from_conn(conn: Connection) -> Result<Self> {
        let index = Self {
            conn: Mutex::new(conn),
        };
        index.migrate()?;
        Ok(index)
    }

    fn migrate(&self) -> Result<()> {
        let mut conn = self.lock()?;
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS entries (
                id          TEXT PRIMARY KEY,
                parent      TEXT,
                name        TEXT NOT NULL,
                kind        INTEGER NOT NULL,
                size        INTEGER NOT NULL DEFAULT 0,
                modified_ms INTEGER,
                mime        TEXT,
                hidden      INTEGER NOT NULL DEFAULT 0,
                readonly    INTEGER NOT NULL DEFAULT 0,
                source      TEXT NOT NULL DEFAULT 'local'
            );
            CREATE INDEX IF NOT EXISTS idx_entries_parent ON entries(parent);
            CREATE INDEX IF NOT EXISTS idx_entries_name ON entries(name);
            -- Two content columns so a single MATCH covers the original
            -- name and the pinyin sidecar (see pinyin_index()).
            CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
                id UNINDEXED,
                name,
                pinyin,
                tokenize = 'trigram'
            );
            "#,
        )
        .map_err(db_err)?;
        // Databases created by the LIKE-based version predate `source`.
        if !has_column(&conn, "entries", "source")? {
            conn.execute_batch(
                "ALTER TABLE entries ADD COLUMN source TEXT NOT NULL DEFAULT 'local'",
            )
            .map_err(db_err)?;
        }
        conn.execute_batch("CREATE INDEX IF NOT EXISTS idx_entries_source ON entries(source)")
            .map_err(db_err)?;
        // 分类聚合：单独存小写扩展名并建索引，避免 LIKE '%.jpg' 全表扫。
        let has_ext = conn
            .query_row(
                "SELECT 1 FROM pragma_table_info('entries') WHERE name = 'ext'",
                [],
                |_| Ok(()),
            )
            .optional()
            .map_err(db_err)?
            .is_some();
        if !has_ext {
            conn.execute_batch("ALTER TABLE entries ADD COLUMN ext TEXT")
                .map_err(db_err)?;
        }
        // 自愈：扩展名必须由 Rust 的 ext_of 统一计算（最后一个小数点）。
        // 旧版本用 SQL 的“第一个点”回填过，会留下 `tar.gz`、`nomedia` 这类脏值；
        // 用 user_version 做一次性重算（点文件不带点，无法靠 LIKE '%.%' 识别）。
        let schema_version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(db_err)?;
        if schema_version < 2 {
            let rows: Vec<(String, String)> = {
                let mut stmt = conn
                    .prepare("SELECT id, name FROM entries")
                    .map_err(db_err)?;
                let iter = stmt
                    .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
                    .map_err(db_err)?;
                let mut out = Vec::new();
                for row in iter {
                    out.push(row.map_err(db_err)?);
                }
                out
            };
            let mut upd = conn
                .prepare("UPDATE entries SET ext = ?1 WHERE id = ?2")
                .map_err(db_err)?;
            for (id, name) in rows {
                upd.execute(params![ext_of(&name), id]).map_err(db_err)?;
            }
        }
        // 分类页同时按扩展名过滤、按修改时间倒序：复合索引让 SQLite 直接
        // 走索引区间，避免把命中行全部取出再排序。
        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_entries_ext ON entries(ext);
             CREATE INDEX IF NOT EXISTS idx_entries_ext_modified ON entries(ext, modified_ms DESC);",
        )
        .map_err(db_err)?;
        if schema_version < 2 {
            conn.pragma_update(None, "user_version", 2)
                .map_err(db_err)?;
        }
        conn.execute_batch(transfers::TRANSFERS_SCHEMA)
            .map_err(db_err)?;
        // Schema v1 (moving tasks): older DBs predate the is_move column.
        if !has_column(&conn, "transfers", "is_move")? {
            conn.execute_batch(
                "ALTER TABLE transfers ADD COLUMN is_move INTEGER NOT NULL DEFAULT 0",
            )
            .map_err(db_err)?;
        }
        // 最近打开（首页「最近打开」数据源；primary key 保证同一路径只留最新一条）
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS recent_opens (
                id        TEXT PRIMARY KEY,
                opened_ms INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_recent_opens_time ON recent_opens(opened_ms);
            "#,
        )
        .map_err(db_err)?;
        // 增量扫描账本：每个目录上次扫描时的 mtime。mtime 未变 = 子树无增删，
        // 下次扫描直接跳过整棵子树（locate 式增量；文件内容原地修改不在覆盖范围）。
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS dir_states (
                id       TEXT PRIMARY KEY,
                mtime_ms INTEGER NOT NULL
            );
            "#,
        )
        .map_err(db_err)?;
        // 收藏（快捷访问标记，纯 UI 语义、零扫描成本）
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS favorites (
                id       TEXT PRIMARY KEY,
                added_ms INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_favorites_time ON favorites(added_ms);
            "#,
        )
        .map_err(db_err)?;
        // 目录列举缓存的「上次更新」账本：每次 list()/扫描成功落索引时记录，
        // 离线浏览用「缓存条目 + 该时间」展示过期标记（M1 离线浏览）。
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS list_states (
                id           TEXT PRIMARY KEY,
                listed_at_ms INTEGER NOT NULL
            );
            "#,
        )
        .map_err(db_err)?;
        // Rebuild the FTS table when it is out of sync with entries (e.g.
        // rows written by the LIKE-based version), and once for the rowid
        // migration below. Counts are reliable because id is UNIQUE on both
        // sides.
        let fts_counts: (i64, i64) = conn
            .query_row(
                "SELECT (SELECT COUNT(*) FROM entries), (SELECT COUNT(*) FROM entries_fts)",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(db_err)?;
        // schema v1: FTS rows share `entries.rowid`. Before this, FTS owned an
        // independent rowid and every upsert did `DELETE ... WHERE id = ?` on
        // an UNINDEXED column — a full scan, i.e. O(N) per row and O(N²) per
        // listing (measured: 5000 entries 3.3s → 47ms after the fix).
        let version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(db_err)?;
        if fts_counts.0 != fts_counts.1 || version < 1 {
            rebuild_fts(&mut conn)?;
            conn.pragma_update(None, "user_version", 1)
                .map_err(db_err)?;
        }
        Ok(())
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Connection>> {
        // 锁中毒（持锁线程 panic 过）不等于数据损坏：SQLite 自身事务保证一致性，
        // 残留 guard 只是被中断——直接取回继续用。移动端进程随时可能被系统杀，
        // 把「锁中毒」升级成 panic 是拿稳定性换洁癖（2026-11 真机 SIGABRT 教训）。
        self.conn.lock().or_else(|e| Ok(e.into_inner()))
    }

    /// Record that the user just opened `id`（同一路径 upsert，仅保留最新时间）。
    pub fn record_open(&self, id: &str, opened_ms: u64) -> Result<()> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO recent_opens (id, opened_ms) VALUES (?1, ?2)
             ON CONFLICT(id) DO UPDATE SET opened_ms = excluded.opened_ms",
            params![id, opened_ms],
        )
        .map_err(db_err)?;
        Ok(())
    }

    /// Drop one recent-open record (does not touch the file itself).
    pub fn remove_recent(&self, id: &str) -> Result<()> {
        let conn = self.lock()?;
        conn.execute("DELETE FROM recent_opens WHERE id = ?1", params![id])
            .map_err(db_err)?;
        Ok(())
    }

    /// Most recently opened ids, newest first. Callers resolve entries via
    /// the vfs and simply skip paths that no longer exist.
    pub fn recent_opens(&self, limit: u32) -> Result<Vec<(String, u64)>> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare("SELECT id, opened_ms FROM recent_opens ORDER BY opened_ms DESC LIMIT ?1")
            .map_err(db_err)?;
        let rows = stmt
            .query_map(params![limit], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, u64>(1)?))
            })
            .map_err(db_err)?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(db_err)
    }

    // ---- 收藏（纯标记） ----

    pub fn add_favorite(&self, id: &str, added_ms: u64) -> Result<()> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO favorites (id, added_ms) VALUES (?1, ?2)
             ON CONFLICT(id) DO UPDATE SET added_ms = excluded.added_ms",
            params![id, added_ms],
        )
        .map_err(db_err)?;
        Ok(())
    }

    pub fn remove_favorite(&self, id: &str) -> Result<()> {
        let conn = self.lock()?;
        conn.execute("DELETE FROM favorites WHERE id = ?1", params![id])
            .map_err(db_err)?;
        Ok(())
    }

    pub fn favorite_ids(&self, limit: u32) -> Result<Vec<(String, u64)>> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare("SELECT id, added_ms FROM favorites ORDER BY added_ms DESC LIMIT ?1")
            .map_err(db_err)?;
        let rows = stmt
            .query_map(params![limit], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, u64>(1)?))
            })
            .map_err(db_err)?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(db_err)
    }

    /// 上次扫描该目录时记录的 mtime（增量判定用；无记录 = 首次扫描）。
    pub fn dir_state_mtime(&self, id: &str) -> Result<Option<i64>> {
        use rusqlite::OptionalExtension;
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare("SELECT mtime_ms FROM dir_states WHERE id = ?1")
            .map_err(db_err)?;
        stmt.query_row(params![id], |row| row.get::<_, i64>(0))
            .optional()
            .map_err(db_err)
    }

    pub fn save_dir_state(&self, id: &str, mtime_ms: i64) -> Result<()> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO dir_states (id, mtime_ms) VALUES (?1, ?2)
             ON CONFLICT(id) DO UPDATE SET mtime_ms = excluded.mtime_ms",
            params![id, mtime_ms],
        )
        .map_err(db_err)?;
        Ok(())
    }

    // ---- 目录列举缓存（M1 离线浏览） ----

    /// 记录一次目录列举时间（离线缓存的「上次更新」标记）。
    pub fn record_listing(&self, dir: &str, listed_at_ms: i64) -> Result<()> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO list_states (id, listed_at_ms) VALUES (?1, ?2)
             ON CONFLICT(id) DO UPDATE SET listed_at_ms = excluded.listed_at_ms",
            params![dir, listed_at_ms],
        )
        .map_err(db_err)?;
        Ok(())
    }

    /// 该目录最近一次成功列举的时间（无记录 = 从未缓存）。
    pub fn listed_at(&self, dir: &str) -> Result<Option<i64>> {
        use rusqlite::OptionalExtension;
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare("SELECT listed_at_ms FROM list_states WHERE id = ?1")
            .map_err(db_err)?;
        stmt.query_row(params![dir], |row| row.get::<_, i64>(0))
            .optional()
            .map_err(db_err)
    }

    /// 索引中 `parent` 的直接子项（离线浏览数据源；目录优先、名称升序）。
    pub fn children_of(&self, parent: &str) -> Result<Vec<Entry>> {
        let conn = self.lock()?;
        let sql = format!(
            "SELECT {ENTRY_COLUMNS}
             FROM entries e
             WHERE e.parent = ?1
             ORDER BY e.kind DESC, e.name COLLATE NOCASE ASC"
        );
        let mut stmt = conn.prepare(&sql).map_err(db_err)?;
        let rows = stmt
            .query_map(params![parent], row_to_entry)
            .map_err(db_err)?;
        collect_rows(rows)
    }

    /// 删除对账：`parent` 下本轮未再出现的条目（含其整棵子树与 FTS 行）。
    /// 返回删除的条目数。目录 mtime 变化才可能触发（见 FFI 增量逻辑）。
    pub fn prune_children(&self, parent: &str, keep_ids: &[String]) -> Result<u64> {
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(db_err)?;
        tx.execute(
            "CREATE TEMP TABLE IF NOT EXISTS keep_ids (id TEXT PRIMARY KEY)",
            [],
        )
        .map_err(db_err)?;
        tx.execute("DELETE FROM keep_ids", []).map_err(db_err)?;
        {
            let mut ins = tx
                .prepare("INSERT OR IGNORE INTO keep_ids (id) VALUES (?1)")
                .map_err(db_err)?;
            for id in keep_ids {
                ins.execute(params![id]).map_err(db_err)?;
            }
        }
        // 1) 找出该目录下已消失的直接子项
        let stale: Vec<String> = {
            let mut stmt = tx
                .prepare(
                    "SELECT id FROM entries
                     WHERE parent = ?1 AND id NOT IN (SELECT id FROM keep_ids)",
                )
                .map_err(db_err)?;
            let rows = stmt
                .query_map(params![parent], |row| row.get::<_, String>(0))
                .map_err(db_err)?;
            rows.collect::<std::result::Result<Vec<_>, _>>()
                .map_err(db_err)?
        };
        let mut removed = 0u64;
        for id in &stale {
            // 2) 级联删除该子项及其整棵子树（id 前缀 = 路径前缀）
            let mut stmt = tx
                .prepare(
                    "SELECT id FROM entries
                     WHERE id = ?1 OR substr(id, 1, length(?1) + 1) = ?1 || '/'",
                )
                .map_err(db_err)?;
            let subtree: Vec<String> = stmt
                .query_map(params![id], |row| row.get::<_, String>(0))
                .map_err(db_err)?
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(db_err)?;
            drop(stmt);
            for gone in subtree {
                let rowid: Option<i64> = tx
                    .query_row(
                        "SELECT rowid FROM entries WHERE id = ?1",
                        params![gone],
                        |row| row.get(0),
                    )
                    .optional()
                    .map_err(db_err)?;
                tx.execute("DELETE FROM entries WHERE id = ?1", params![gone])
                    .map_err(db_err)?;
                if let Some(rowid) = rowid {
                    tx.execute("DELETE FROM entries_fts WHERE rowid = ?1", params![rowid])
                        .map_err(db_err)?;
                }
                tx.execute("DELETE FROM dir_states WHERE id = ?1", params![gone])
                    .map_err(db_err)?;
                tx.execute("DELETE FROM list_states WHERE id = ?1", params![gone])
                    .map_err(db_err)?;
                removed += 1;
            }
        }
        tx.commit().map_err(db_err)?;
        Ok(removed)
    }

    /// Insert or update a single entry under the default (local) source.
    pub fn upsert(&self, entry: &Entry) -> Result<()> {
        let conn = self.lock()?;
        upsert_entry(&conn, DEFAULT_SOURCE, entry)
    }

    /// Batch upsert under the default (local) source inside a single
    /// transaction (one fsync instead of N).
    pub fn upsert_all(&self, entries: &[Entry]) -> Result<()> {
        self.upsert_all_for_source(DEFAULT_SOURCE, entries)
    }

    /// Same as [`upsert_all`](Self::upsert_all) but tags every entry with a
    /// source (e.g. `webdav://nas/movies`). This is the M2 groundwork for
    /// one index aggregating several mounts; use
    /// [`search_in_source`](Self::search_in_source) to read one mount back.
    pub fn upsert_all_for_source(&self, source: &str, entries: &[Entry]) -> Result<()> {
        if entries.is_empty() {
            return Ok(());
        }
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(db_err)?;
        {
            let mut upsert_stmt = tx.prepare(UPSERT_SQL).map_err(db_err)?;
            let mut rowid_stmt = tx
                .prepare("SELECT rowid FROM entries WHERE id = ?1")
                .map_err(db_err)?;
            let mut fts_delete = tx
                .prepare("DELETE FROM entries_fts WHERE rowid = ?1")
                .map_err(db_err)?;
            let mut fts_insert = tx
                .prepare(
                    "INSERT INTO entries_fts (rowid, id, name, pinyin) VALUES (?1, ?2, ?3, ?4)",
                )
                .map_err(db_err)?;
            for entry in entries {
                bind_upsert(&mut upsert_stmt, source, entry)?;
                // FTS rows are keyed by entries.rowid: point delete + insert,
                // no full scan (see rebuild_fts for the migration).
                let rowid: i64 = rowid_stmt
                    .query_row(params![entry.id], |row| row.get(0))
                    .map_err(db_err)?;
                fts_delete.execute(params![rowid]).map_err(db_err)?;
                fts_insert
                    .execute(params![
                        rowid,
                        entry.id,
                        entry.name,
                        pinyin_index(&entry.name)
                    ])
                    .map_err(db_err)?;
            }
        }
        tx.commit().map_err(db_err)
    }

    pub fn remove(&self, id: &str) -> Result<()> {
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(db_err)?;
        let rowid: Option<i64> = tx
            .query_row(
                "SELECT rowid FROM entries WHERE id = ?1",
                params![id],
                |row| row.get(0),
            )
            .optional()
            .map_err(db_err)?;
        tx.execute("DELETE FROM entries WHERE id = ?1", params![id])
            .map_err(db_err)?;
        if let Some(rowid) = rowid {
            tx.execute("DELETE FROM entries_fts WHERE rowid = ?1", params![rowid])
                .map_err(db_err)?;
        }
        tx.commit().map_err(db_err)
    }

    /// 某个存储根（`id` 本身或其子树）在索引里的条目数。
    pub fn count_under_prefix(&self, prefix: &str) -> Result<u64> {
        let prefix = normalize_prefix(prefix);
        let conn = self.lock()?;
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM entries
                 WHERE id = ?1 OR substr(id, 1, length(?1) + 1) = ?1 || '/'",
                params![prefix],
                |row| row.get(0),
            )
            .map_err(db_err)?;
        Ok(count as u64)
    }

    /// 删除 `id` 及其整棵子树（含 FTS 行与目录扫描状态）。返回删除行数。
    /// 文件系统删除后立即调用：保证搜索/分类页马上查不到已删文件。
    pub fn remove_subtree(&self, id: &str) -> Result<u64> {
        let id = normalize_prefix(id);
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(db_err)?;
        let ids: Vec<String> = {
            let mut stmt = tx
                .prepare(
                    "SELECT id FROM entries
                     WHERE id = ?1 OR substr(id, 1, length(?1) + 1) = ?1 || '/'",
                )
                .map_err(db_err)?;
            let rows = stmt
                .query_map(params![id], |row| row.get::<_, String>(0))
                .map_err(db_err)?;
            rows.collect::<std::result::Result<Vec<_>, _>>()
                .map_err(db_err)?
        };
        let mut removed = 0u64;
        for gone in ids {
            let rowid: Option<i64> = tx
                .query_row(
                    "SELECT rowid FROM entries WHERE id = ?1",
                    params![gone],
                    |row| row.get(0),
                )
                .optional()
                .map_err(db_err)?;
            tx.execute("DELETE FROM entries WHERE id = ?1", params![gone])
                .map_err(db_err)?;
            if let Some(rowid) = rowid {
                tx.execute("DELETE FROM entries_fts WHERE rowid = ?1", params![rowid])
                    .map_err(db_err)?;
            }
            tx.execute("DELETE FROM dir_states WHERE id = ?1", params![gone])
                .map_err(db_err)?;
            tx.execute("DELETE FROM list_states WHERE id = ?1", params![gone])
                .map_err(db_err)?;
            removed += 1;
        }
        tx.commit().map_err(db_err)?;
        Ok(removed)
    }

    /// 目录改名/移动：把 `old_id` 及整棵子树的 id/parent 前缀改写成
    /// `new_id`，同时同步 FTS 的 id 列与目录扫描状态。纯 SQL，不碰文件系统。
    /// 返回改写的行数；调用方随后 [`upsert`](Self::upsert) 新的根条目刷新元数据。
    pub fn rekey_subtree(&self, old_id: &str, new_id: &str) -> Result<u64> {
        let old_id = normalize_prefix(old_id);
        if old_id == new_id {
            return Ok(0);
        }
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(db_err)?;
        let rows: Vec<(String, Option<String>)> = {
            let mut stmt = tx
                .prepare(
                    "SELECT id, parent FROM entries
                     WHERE id = ?1 OR substr(id, 1, length(?1) + 1) = ?1 || '/'",
                )
                .map_err(db_err)?;
            let iter = stmt
                .query_map(params![old_id], |row| Ok((row.get(0)?, row.get(1)?)))
                .map_err(db_err)?;
            iter.collect::<std::result::Result<Vec<_>, _>>()
                .map_err(db_err)?
        };
        let mut count = 0u64;
        for (id, parent) in rows {
            let suffix = &id[old_id.len()..];
            let new_child = format!("{new_id}{suffix}");
            if new_child == id {
                continue;
            }
            let new_parent = match parent {
                Some(p) if p == old_id => new_id.to_string(),
                Some(p) => match p.strip_prefix(old_id) {
                    Some(rest) => format!("{new_id}{rest}"),
                    None => p,
                },
                None => String::new(),
            };
            let rowid: Option<i64> = tx
                .query_row(
                    "SELECT rowid FROM entries WHERE id = ?1",
                    params![id],
                    |row| row.get(0),
                )
                .optional()
                .map_err(db_err)?;
            tx.execute(
                "UPDATE entries SET id = ?1, parent = ?2 WHERE id = ?3",
                params![new_child, new_parent, id],
            )
            .map_err(db_err)?;
            if let Some(rowid) = rowid {
                tx.execute(
                    "UPDATE entries_fts SET id = ?1 WHERE rowid = ?2",
                    params![new_child, rowid],
                )
                .map_err(db_err)?;
            }
            tx.execute(
                "UPDATE OR REPLACE dir_states SET id = ?1 WHERE id = ?2",
                params![new_child, id],
            )
            .map_err(db_err)?;
            count += 1;
        }
        tx.commit().map_err(db_err)?;
        Ok(count)
    }

    pub fn clear(&self) -> Result<()> {
        let conn = self.lock()?;
        // 必须连扫描账本一起清：否则 dir_states/list_states 还留着，
        // 下一次「重建」会以为目录没变化而整棵跳过（真机踩过）。
        conn.execute_batch(
            "DELETE FROM entries;
             DELETE FROM entries_fts;
             DELETE FROM dir_states;
             DELETE FROM list_states;",
        )
        .map_err(db_err)
    }

    pub fn count(&self) -> Result<u64> {
        let conn = self.lock()?;
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM entries", [], |row| row.get(0))
            .map_err(db_err)?;
        Ok(count as u64)
    }

    /// Substring search over file names, newest modification first.
    ///
    /// Defaults to FTS5 (trigram) when the query has a token of at least
    /// three characters; shorter queries (pinyin initials, 1-2 CJK chars)
    /// fall back to escaped LIKE over the name and pinyin columns. An empty
    /// query matches everything (M0 behavior).
    pub fn search(&self, query: &str, limit: u32) -> Result<Vec<Entry>> {
        self.search_filtered(None, query, limit)
    }

    /// Count files whose extension matches any of `exts` (case-insensitive).
    /// Backed by a single SQL scan, so the home screen can show real numbers
    /// without walking the tree.
    pub fn count_by_exts(&self, exts: &[String], include_hidden: bool) -> Result<u64> {
        if exts.is_empty() {
            return Ok(0);
        }
        let conn = self.lock()?;
        let (clause, binds) = ext_predicate(exts);
        if clause.is_empty() {
            return Ok(0);
        }
        let hidden = hidden_clause(include_hidden);
        let sql = format!("SELECT COUNT(*) FROM entries e WHERE e.kind = 0 AND ({clause}){hidden}");
        let mut stmt = conn.prepare(&sql).map_err(db_err)?;
        let count: i64 = stmt
            .query_row(rusqlite::params_from_iter(binds.iter()), |row| row.get(0))
            .map_err(db_err)?;
        Ok(count as u64)
    }

    /// List files matching `exts`, newest first. `limit` caps the result so a
    /// huge category cannot stall the UI.
    pub fn list_by_exts(&self, exts: &[String], limit: u32) -> Result<Vec<Entry>> {
        self.list_by_exts_page(exts, 0, limit, true)
    }

    /// 分页版本（`offset` 为空表示从头）：首屏只取几百条，剩余由后台续载。
    pub fn list_by_exts_page(
        &self,
        exts: &[String],
        offset: u32,
        limit: u32,
        include_hidden: bool,
    ) -> Result<Vec<Entry>> {
        if exts.is_empty() || limit == 0 {
            return Ok(Vec::new());
        }
        let conn = self.lock()?;
        let (clause, binds) = ext_predicate(exts);
        if clause.is_empty() {
            return Ok(Vec::new());
        }
        let hidden = hidden_clause(include_hidden);
        let sql = format!(
            "SELECT {ENTRY_COLUMNS}
             FROM entries e
             WHERE e.kind = 0 AND ({clause}){hidden}
             ORDER BY e.modified_ms DESC
             LIMIT {limit} OFFSET {offset}"
        );
        let mut stmt = conn.prepare(&sql).map_err(db_err)?;
        let rows = stmt
            .query_map(rusqlite::params_from_iter(binds.iter()), row_to_entry)
            .map_err(db_err)?;
        collect_rows(rows)
    }

    /// Like [`search`](Self::search) but only returns entries written under
    /// `source` (see [`upsert_all_for_source`](Self::upsert_all_for_source)).
    pub fn search_in_source(&self, source: &str, query: &str, limit: u32) -> Result<Vec<Entry>> {
        self.search_filtered(Some(source), query, limit)
    }

    // --- Transfer task persistence (see transfers.rs) ---

    /// Insert or update a transfer record (see [`StoredTransfer`]).
    pub fn save_transfer(&self, transfer: &StoredTransfer) -> Result<()> {
        let conn = self.lock()?;
        transfers::save_transfer(&conn, transfer)
    }

    /// Checkpoint write while a transfer runs: progress counters plus the
    /// per-file offset map, cheap enough to call every few MiB copied.
    pub fn update_transfer_progress(
        &self,
        id: &str,
        files_done: u64,
        bytes_done: u64,
        file_offsets: &[FileOffset],
    ) -> Result<()> {
        let conn = self.lock()?;
        transfers::update_transfer_progress(&conn, id, files_done, bytes_done, file_offsets)
    }

    /// Move a transfer into its terminal state (completed/failed/cancelled).
    pub fn finish_transfer(
        &self,
        id: &str,
        state: TransferTaskState,
        error: Option<&str>,
    ) -> Result<()> {
        let conn = self.lock()?;
        transfers::finish_transfer(&conn, id, state, error)
    }

    /// Rows in `queued`/`running` state, oldest first — the set a restart
    /// should offer to resume.
    pub fn load_unfinished_transfers(&self) -> Result<Vec<StoredTransfer>> {
        let conn = self.lock()?;
        transfers::load_unfinished_transfers(&conn)
    }

    /// Recently terminal jobs, newest first — completed rows feed the
    /// storage-cleanup page, and failed/cancelled rows surface the
    /// partially-written leftovers a cleanup should reclaim.
    pub fn load_recent_terminal_transfers(&self, limit: u32) -> Result<Vec<StoredTransfer>> {
        let conn = self.lock()?;
        transfers::load_recent_terminal_transfers(&conn, limit)
    }

    /// Drop the record entirely (user dismissed it from the UI).
    pub fn forget_transfer(&self, id: &str) -> Result<()> {
        let conn = self.lock()?;
        transfers::forget_transfer(&conn, id)
    }

    fn search_filtered(&self, source: Option<&str>, query: &str, limit: u32) -> Result<Vec<Entry>> {
        let conn = self.lock()?;
        if longest_alnum_run(query) >= TRIGRAM_MIN {
            // The FTS tokens are embedded in a double-quoted string and inner
            // quotes are neutralized, so nothing in `query` can break out —
            // MATCH input is injection-safe by construction.
            if let Ok(entries) = search_fts(&conn, source, query, limit) {
                return Ok(entries);
            }
            // FTS table dropped/corrupted from the outside: keep searching.
        }
        search_like(&conn, source, query, limit)
    }
}

/// UPSERT shared by `upsert_all_for_source` and `upsert`; bound with
/// [`bind_upsert`].
const UPSERT_SQL: &str = r#"INSERT INTO entries (id, parent, name, ext, kind, size, modified_ms, mime, hidden, readonly, source)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
     ON CONFLICT(id) DO UPDATE SET
       parent=excluded.parent, name=excluded.name, ext=excluded.ext, kind=excluded.kind,
       size=excluded.size, modified_ms=excluded.modified_ms, mime=excluded.mime,
       hidden=excluded.hidden, readonly=excluded.readonly, source=excluded.source"#;

/// Entry columns used in every SELECT (must match [`row_to_entry`]).
const ENTRY_COLUMNS: &str =
    "e.id, e.parent, e.name, e.kind, e.size, e.modified_ms, e.mime, e.hidden, e.readonly";

fn bind_upsert(stmt: &mut rusqlite::Statement<'_>, source: &str, entry: &Entry) -> Result<()> {
    stmt.execute(params![
        entry.id,
        entry.parent,
        entry.name,
        ext_of(&entry.name),
        kind_code(entry.kind),
        entry.size as i64,
        entry.modified_ms,
        entry.mime,
        entry.hidden as i64,
        entry.readonly as i64,
        source,
    ])
    .map_err(db_err)?;
    Ok(())
}

fn upsert_entry(conn: &Connection, source: &str, entry: &Entry) -> Result<()> {
    bind_upsert(
        &mut conn.prepare(UPSERT_SQL).map_err(db_err)?,
        source,
        entry,
    )?;
    // Keep the FTS row in sync by re-indexing the name. Deleting by `rowid`
    // is a point lookup; `id` is UNINDEXED and would scan the whole table.
    let rowid: i64 = conn
        .query_row(
            "SELECT rowid FROM entries WHERE id = ?1",
            params![entry.id],
            |row| row.get(0),
        )
        .map_err(db_err)?;
    conn.execute("DELETE FROM entries_fts WHERE rowid = ?1", params![rowid])
        .map_err(db_err)?;
    conn.execute(
        "INSERT INTO entries_fts (rowid, id, name, pinyin) VALUES (?1, ?2, ?3, ?4)",
        params![rowid, entry.id, entry.name, pinyin_index(&entry.name)],
    )
    .map_err(db_err)?;
    Ok(())
}

/// Rebuild the whole FTS table with `rowid` aligned to `entries.rowid`
/// (schema v1). Regenerating from `entries` also repairs entries/FTS drift.
fn rebuild_fts(conn: &mut Connection) -> Result<()> {
    let rows: Vec<(i64, String, String)> = {
        let mut stmt = conn
            .prepare("SELECT rowid, id, name FROM entries")
            .map_err(db_err)?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .map_err(db_err)?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(db_err)?
    };
    let tx = conn.transaction().map_err(db_err)?;
    tx.execute("DROP TABLE IF EXISTS entries_fts", [])
        .map_err(db_err)?;
    tx.execute(
        "CREATE VIRTUAL TABLE entries_fts USING fts5(
            id UNINDEXED, name, pinyin, tokenize = 'trigram'
        )",
        [],
    )
    .map_err(db_err)?;
    {
        let mut insert = tx
            .prepare("INSERT INTO entries_fts (rowid, id, name, pinyin) VALUES (?1, ?2, ?3, ?4)")
            .map_err(db_err)?;
        for (rowid, id, name) in &rows {
            insert
                .execute(params![rowid, id, name, pinyin_index(name)])
                .map_err(db_err)?;
        }
    }
    tx.commit().map_err(db_err)
}

fn search_fts(
    conn: &Connection,
    source: Option<&str>,
    query: &str,
    limit: u32,
) -> Result<Vec<Entry>> {
    let fts_query = format!("\"{}\"", query.replace('"', " "));
    let sql = format!(
        "SELECT {ENTRY_COLUMNS}
         FROM entries_fts JOIN entries e ON e.id = entries_fts.id
         WHERE entries_fts MATCH ?1
           AND (?2 IS NULL OR e.source = ?2)
         ORDER BY e.modified_ms DESC
         LIMIT ?3"
    );
    let mut stmt = conn.prepare(&sql).map_err(db_err)?;
    let rows = stmt
        .query_map(params![fts_query, source, limit as i64], row_to_entry)
        .map_err(db_err)?;
    collect_rows(rows)
}

fn search_like(
    conn: &Connection,
    source: Option<&str>,
    query: &str,
    limit: u32,
) -> Result<Vec<Entry>> {
    let pattern = format!("%{}%", escape_like(query));
    // Goes through the FTS table's content columns so pinyin initials
    // (e.g. "ds" for 电视) and short CJK queries can be answered without
    // trigram support.
    let sql = format!(
        "SELECT {ENTRY_COLUMNS}
         FROM entries_fts JOIN entries e ON e.id = entries_fts.id
         WHERE (entries_fts.name LIKE ?1 ESCAPE '\\' OR entries_fts.pinyin LIKE ?1 ESCAPE '\\')
           AND (?2 IS NULL OR e.source = ?2)
         ORDER BY e.modified_ms DESC
         LIMIT ?3"
    );
    let mut stmt = conn.prepare(&sql).map_err(db_err)?;
    let rows = stmt
        .query_map(params![pattern, source, limit as i64], row_to_entry)
        .map_err(db_err)?;
    collect_rows(rows)
}

fn collect_rows(
    rows: rusqlite::MappedRows<'_, impl FnMut(&rusqlite::Row<'_>) -> rusqlite::Result<Entry>>,
) -> Result<Vec<Entry>> {
    let mut entries = Vec::new();
    for row in rows {
        entries.push(row.map_err(db_err)?);
    }
    Ok(entries)
}

fn has_column(conn: &Connection, table: &str, column: &str) -> Result<bool> {
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(db_err)?;
    let names = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(db_err)?;
    for name in names {
        if name.map_err(db_err)? == column {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Pinyin sidecar string for the FTS index: concatenated full pinyin of all
/// CJK characters plus, when there is more than one, their initials as a
/// separate token — "电视剧" becomes "dianshiji dsj" so that "dianshiji",
/// substring queries like "dians" and initials queries like "dsj"/"ds" all
/// hit.
///
/// The `pinyin` crate (mozillazg/pinyin-rust) was chosen because it is pure
/// Rust with zero runtime dependencies and embeds its GB2312+ character
/// tables at compile time — no IO, no C code, nothing extra to ship on
/// mobile targets. Only the most common pronunciation is indexed;
/// heteronyms are acceptable misses for file name search.
fn pinyin_index(name: &str) -> String {
    let mut full = String::new();
    let mut initials = String::new();
    for ch in name.chars() {
        if let Some(pinyin) = ch.to_pinyin() {
            full.push_str(pinyin.plain());
            initials.push_str(pinyin.first_letter());
        }
    }
    if initials.len() > 1 {
        full.push(' ');
        full.push_str(&initials);
    }
    full
}

/// Length of the longest run of alphanumeric characters. The trigram
/// tokenizer treats all other characters as separators, so a query can use
/// the FTS index only when one of its tokens reaches [`TRIGRAM_MIN`].
fn longest_alnum_run(query: &str) -> usize {
    let mut best = 0;
    let mut run = 0;
    for ch in query.chars() {
        if ch.is_alphanumeric() {
            run += 1;
            best = best.max(run);
        } else {
            run = 0;
        }
    }
    best
}

/// `lower(name) LIKE '%.jpg' OR ...` plus the bound patterns.
fn ext_predicate(exts: &[String]) -> (String, Vec<String>) {
    let mut binds = Vec::new();
    for raw in exts {
        let e = raw.trim().trim_start_matches('.').to_lowercase();
        if !e.is_empty() {
            binds.push(e);
        }
    }
    if binds.is_empty() {
        return (String::new(), binds);
    }
    let placeholders = vec!["?"; binds.len()].join(",");
    (format!("e.ext IN ({placeholders})"), binds)
}

/// 存储根/目录前缀规范化：去掉末尾多余的 `/`（`webdav://host/` → `webdav://host`）。
/// 保留协议头的 `//` 和系统根 `/`，否则前缀匹配会变成 `webdav://host//…` 而永远命中 0 行。
fn normalize_prefix(id: &str) -> &str {
    if id.len() > 1 && id.ends_with('/') {
        let trimmed = id.trim_end_matches('/');
        if trimmed.ends_with(':') {
            id
        } else {
            trimmed
        }
    } else {
        id
    }
}

/// 与 UI 的「显示隐藏文件」开关保持一致：默认不把隐藏文件和点文件算进分类。
fn hidden_clause(include_hidden: bool) -> &'static str {
    if include_hidden {
        ""
    } else {
        " AND e.hidden = 0 AND e.name NOT LIKE '.%'"
    }
}

/// 小写扩展名（无点）：取最后一个点之后；`.nomedia`、`a.` 视为无扩展名。
fn ext_of(name: &str) -> Option<String> {
    let (stem, ext) = name.rsplit_once('.')?;
    if stem.is_empty() || ext.is_empty() {
        return None;
    }
    Some(ext.to_lowercase())
}

fn escape_like(input: &str) -> String {
    input
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

fn kind_code(kind: EntryKind) -> i64 {
    match kind {
        EntryKind::File => 0,
        EntryKind::Directory => 1,
        EntryKind::Symlink => 2,
        EntryKind::Special => 3,
    }
}

fn kind_from_code(code: i64) -> EntryKind {
    match code {
        1 => EntryKind::Directory,
        2 => EntryKind::Symlink,
        3 => EntryKind::Special,
        _ => EntryKind::File,
    }
}

fn row_to_entry(row: &rusqlite::Row<'_>) -> rusqlite::Result<Entry> {
    Ok(Entry {
        id: row.get(0)?,
        parent: row.get(1)?,
        name: row.get(2)?,
        kind: kind_from_code(row.get(3)?),
        size: row.get::<_, i64>(4)? as u64,
        modified_ms: row.get(5)?,
        mime: row.get(6)?,
        hidden: row.get::<_, i64>(7)? != 0,
        readonly: row.get::<_, i64>(8)? != 0,
    })
}

fn db_err(err: rusqlite::Error) -> VfsError {
    VfsError::Io(format!("index: {err}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn favorites_roundtrip() {
        let index = Index::open_in_memory().unwrap();
        index.add_favorite("/a", 100).unwrap();
        index.add_favorite("/b", 200).unwrap();
        index.add_favorite("/a", 300).unwrap(); // 重复收藏 → 更新时间
        let ids = index.favorite_ids(10).unwrap();
        assert_eq!(ids, vec![("/a".to_string(), 300), ("/b".to_string(), 200)]);
        index.remove_favorite("/a").unwrap();
        assert_eq!(index.favorite_ids(10).unwrap().len(), 1);
    }

    #[test]
    fn prune_children_removes_stale_subtrees() {
        fn at(id: &str, parent: &str, name: &str) -> Entry {
            let mut e = entry(id, name);
            e.parent = Some(parent.to_string());
            e
        }
        let index = Index::open_in_memory().unwrap();
        index.upsert(&at("/a", "/", "a")).unwrap();
        index.upsert(&at("/a/keep.txt", "/a", "keep.txt")).unwrap();
        index.upsert(&at("/a/gone", "/a", "gone")).unwrap();
        index
            .upsert(&at("/a/gone/deep.txt", "/a/gone", "deep.txt"))
            .unwrap();
        let keep = vec!["/a/keep.txt".to_string()];
        let removed = index.prune_children("/a", &keep).unwrap();
        assert_eq!(removed, 2, "gone + deep.txt should be pruned");
        assert!(index
            .search("keep", 10)
            .unwrap()
            .iter()
            .any(|e| e.name == "keep.txt"));
        assert!(!index
            .search("deep", 10)
            .unwrap()
            .iter()
            .any(|e| e.name == "deep.txt"));
    }

    #[test]
    fn children_of_and_listed_at_drive_offline_browsing() {
        fn at(id: &str, parent: &str, name: &str, kind: EntryKind) -> Entry {
            let mut e = entry(id, name);
            e.parent = Some(parent.to_string());
            e.kind = kind;
            e
        }
        let index = Index::open_in_memory().unwrap();
        assert!(index.children_of("/a").unwrap().is_empty());
        assert_eq!(index.listed_at("/a").unwrap(), None);

        index
            .upsert_all(&[
                at("/a", "/", "a", EntryKind::Directory),
                at("/a/zeta.txt", "/a", "zeta.txt", EntryKind::File),
                at("/a/sub", "/a", "sub", EntryKind::Directory),
                at("/a/alpha.txt", "/a", "alpha.txt", EntryKind::File),
            ])
            .unwrap();
        index.record_listing("/a", 1_700_000_000_000).unwrap();

        // 目录优先、名称升序；不含子目录内的深层条目。
        let names: Vec<String> = index
            .children_of("/a")
            .unwrap()
            .into_iter()
            .map(|e| e.name)
            .collect();
        assert_eq!(names, vec!["sub", "alpha.txt", "zeta.txt"]);
        assert_eq!(index.listed_at("/a").unwrap(), Some(1_700_000_000_000));

        // 重复列举只保留最新时间。
        index.record_listing("/a", 1_700_000_100_000).unwrap();
        assert_eq!(index.listed_at("/a").unwrap(), Some(1_700_000_100_000));
    }

    #[test]
    fn recent_opens_are_ordered_and_deduplicated() {
        let index = Index::open_in_memory().unwrap();
        index.record_open("/a", 100).unwrap();
        index.record_open("/b", 200).unwrap();
        index.record_open("/a", 300).unwrap(); // 同一路径只保留最新时间
        let rows = index.recent_opens(10).unwrap();
        assert_eq!(rows, vec![("/a".to_string(), 300), ("/b".to_string(), 200)]);
        assert_eq!(index.recent_opens(1).unwrap().len(), 1);
    }

    fn entry(id: &str, name: &str) -> Entry {
        Entry {
            id: id.to_string(),
            parent: Some("/root".into()),
            name: name.to_string(),
            kind: EntryKind::File,
            size: 42,
            modified_ms: Some(1_700_000_000_000),
            mime: Some("video/mp4".into()),
            hidden: false,
            readonly: false,
        }
    }

    #[test]
    fn remove_subtree_drops_descendants_and_search_hits() {
        let index = Index::open_in_memory().unwrap();
        let mut dir = entry("/root/photos", "photos");
        dir.kind = EntryKind::Directory;
        let mut a = entry("/root/photos/a.jpg", "a.jpg");
        a.parent = Some("/root/photos".into());
        let mut b = entry("/root/photos/sub/b.jpg", "b.jpg");
        b.parent = Some("/root/photos/sub".into());
        index.upsert_all(&[dir, a, b]).unwrap();
        assert!(index
            .search("b.jpg", 10)
            .unwrap()
            .iter()
            .any(|e| e.name == "b.jpg"));
        assert_eq!(index.remove_subtree("/root/photos").unwrap(), 3);
        assert!(index.search("a.jpg", 10).unwrap().is_empty());
        assert!(index.search("b.jpg", 10).unwrap().is_empty());
    }

    #[test]
    fn rekey_subtree_moves_ids_parents_and_search_rows() {
        let index = Index::open_in_memory().unwrap();
        let mut dir = entry("/root/old", "old");
        dir.kind = EntryKind::Directory;
        let mut a = entry("/root/old/a.jpg", "a.jpg");
        a.parent = Some("/root/old".into());
        let mut b = entry("/root/old/sub/b.jpg", "b.jpg");
        b.parent = Some("/root/old/sub".into());
        index.upsert_all(&[dir, a, b]).unwrap();

        assert_eq!(index.rekey_subtree("/root/old", "/root/new").unwrap(), 3);
        let hits = index.search("b.jpg", 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].id, "/root/new/sub/b.jpg");
        assert_eq!(hits[0].parent.as_deref(), Some("/root/new/sub"));
        assert!(index
            .children_of("/root/new")
            .unwrap()
            .iter()
            .any(|e| e.name == "a.jpg"));
        assert!(index
            .search("b.jpg", 10)
            .unwrap()
            .iter()
            .all(|e| !e.id.starts_with("/root/old")));
    }

    #[test]
    fn prefix_queries_tolerate_trailing_slash() {
        let index = Index::open_in_memory().unwrap();
        let mut a = entry("webdav://nas/a.txt", "a.txt");
        a.parent = Some("webdav://nas/".into());
        let mut b = entry("webdav://nas/sub/b.txt", "b.txt");
        b.parent = Some("webdav://nas/sub".into());
        index.upsert_all(&[a, b]).unwrap();

        // 挂载根 id 带尾斜杠（WebDAV/SMB 的 root_id 就是这样）
        assert_eq!(index.count_under_prefix("webdav://nas/").unwrap(), 2);
        assert_eq!(index.count_under_prefix("webdav://nas").unwrap(), 2);
        assert_eq!(index.remove_subtree("webdav://nas/").unwrap(), 2);
        assert_eq!(index.count_under_prefix("webdav://nas/").unwrap(), 0);
    }

    #[test]
    fn clear_wipes_scan_bookkeeping_so_rebuild_really_rescans() {
        let index = Index::open_in_memory().unwrap();
        let mut dir = entry("/root/a", "a");
        dir.kind = EntryKind::Directory;
        index.upsert(&dir).unwrap();
        index.save_dir_state("/root/a", 123).unwrap();
        index.record_listing("/root/a", 456).unwrap();
        assert_eq!(index.dir_state_mtime("/root/a").unwrap(), Some(123));

        index.clear().unwrap();
        assert_eq!(index.dir_state_mtime("/root/a").unwrap(), None);
        assert_eq!(index.listed_at("/root/a").unwrap(), None);
    }

    #[test]
    fn ext_of_uses_last_dot_and_ignores_dotfiles() {
        assert_eq!(ext_of("a.tar.gz").as_deref(), Some("gz"));
        assert_eq!(ext_of("IMG_0001.JPG").as_deref(), Some("jpg"));
        assert_eq!(ext_of(".nomedia"), None);
        assert_eq!(ext_of("a."), None);
        assert_eq!(ext_of("noext"), None);
    }

    #[test]
    fn count_and_list_by_exts_use_indexed_column() {
        let index = Index::open_in_memory().unwrap();
        let mut a = entry("/root/DCIM/a.JPG", "a.JPG");
        a.modified_ms = Some(300);
        let mut b = entry("/root/DCIM/b.jpg", "b.jpg");
        b.modified_ms = Some(200);
        let mut c = entry("/root/Music/c.mp3", "c.mp3");
        c.modified_ms = Some(100);
        index.upsert_all(&[a, b, c]).unwrap();

        let images = vec!["jpg".to_string(), "jpeg".to_string()];
        assert_eq!(index.count_by_exts(&images, true).unwrap(), 2);
        let listed = index.list_by_exts(&images, 10).unwrap();
        assert_eq!(listed.len(), 2);
        assert_eq!(listed[0].name, "a.JPG", "newest first");
        assert_eq!(index.count_by_exts(&["mp3".to_string()], true).unwrap(), 1);
        assert!(index.count_by_exts(&[], true).unwrap() == 0);

        // 隐藏文件默认不计入分类；打开「显示隐藏文件」后才出现。
        let mut hidden = entry("/root/DCIM/.secret.jpg", ".secret.jpg");
        hidden.hidden = true;
        index.upsert(&hidden).unwrap();
        assert_eq!(index.count_by_exts(&images, false).unwrap(), 2);
        assert_eq!(index.count_by_exts(&images, true).unwrap(), 3);
        assert!(index
            .list_by_exts_page(&images, 0, 10, false)
            .unwrap()
            .iter()
            .all(|e| e.name != ".secret.jpg"));
        assert!(index
            .list_by_exts_page(&images, 0, 10, true)
            .unwrap()
            .iter()
            .any(|e| e.name == ".secret.jpg"));
    }

    #[test]
    fn upsert_and_search() {
        let index = Index::open_in_memory().unwrap();
        index
            .upsert_all(&[entry("1", "Interstellar.mkv"), entry("2", "inception.mp4")])
            .unwrap();
        assert_eq!(index.count().unwrap(), 2);

        let hits = index.search("inter", 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].name, "Interstellar.mkv");

        // Case insensitive and wildcard-safe.
        assert_eq!(index.search("INCEP", 10).unwrap().len(), 1);
        assert_eq!(index.search("%", 10).unwrap().len(), 0);

        index.upsert(&entry("1", "Interstellar.remux.mkv")).unwrap();
        assert_eq!(index.count().unwrap(), 2);
        assert_eq!(index.search("remux", 10).unwrap().len(), 1);
    }

    #[test]
    fn chinese_search() {
        let index = Index::open_in_memory().unwrap();
        index
            .upsert_all(&[entry("1", "电视剧.mkv"), entry("2", "plain-notes.txt")])
            .unwrap();

        // >= 3 chars: FTS trigram; 1-2 chars: LIKE fallback.
        assert_eq!(single_hit(&index, "电视剧"), "电视剧.mkv");
        assert_eq!(single_hit(&index, "电视"), "电视剧.mkv");
        assert_eq!(single_hit(&index, "电"), "电视剧.mkv");
        assert_eq!(index.search("电影", 10).unwrap().len(), 0);
    }

    #[test]
    fn pinyin_search() {
        let index = Index::open_in_memory().unwrap();
        index.upsert_all(&[entry("1", "电视剧.mkv")]).unwrap();

        // Note: 剧 is "ju" (ü -> u); the sidecar string is "dianshiju dsj".
        assert_eq!(single_hit(&index, "dianshiju"), "电视剧.mkv");
        assert_eq!(single_hit(&index, "dians"), "电视剧.mkv");
        assert_eq!(single_hit(&index, "shiju"), "电视剧.mkv");
        assert_eq!(single_hit(&index, "DIANSHIJU"), "电视剧.mkv");
        // Initials of length 3 and 2 (the latter via the LIKE fallback).
        assert_eq!(single_hit(&index, "dsj"), "电视剧.mkv");
        assert_eq!(single_hit(&index, "ds"), "电视剧.mkv");
        assert_eq!(single_hit(&index, "DS"), "电视剧.mkv");
    }

    #[test]
    fn english_and_mixed_search() {
        let index = Index::open_in_memory().unwrap();
        index
            .upsert_all(&[
                entry("1", "Interstellar.mkv"),
                entry("2", "Season 01 春晚.mkv"),
                entry("3", "2024 春节联欢晚会.mp4"),
            ])
            .unwrap();

        assert_eq!(single_hit(&index, "INTER"), "Interstellar.mkv");
        assert_eq!(single_hit(&index, "Season"), "Season 01 春晚.mkv");
        // Mixed CJK/ASCII names: query either script.
        assert_eq!(single_hit(&index, "春晚"), "Season 01 春晚.mkv");
        assert_eq!(single_hit(&index, "01"), "Season 01 春晚.mkv");
        assert_eq!(single_hit(&index, "春节联欢晚会"), "2024 春节联欢晚会.mp4");
        assert_eq!(single_hit(&index, "2024"), "2024 春节联欢晚会.mp4");
        // Pinyin of 春晚 vs 春节联欢晚会 are distinct sidecar strings.
        assert_eq!(single_hit(&index, "chunwan"), "Season 01 春晚.mkv");
        assert_eq!(
            single_hit(&index, "chunjielianhuanwanhui"),
            "2024 春节联欢晚会.mp4"
        );
        assert_eq!(single_hit(&index, "cjlhwh"), "2024 春节联欢晚会.mp4");
    }

    #[test]
    fn source_filtering() {
        let index = Index::open_in_memory().unwrap();
        index.upsert_all(&[entry("1", "movie.mkv")]).unwrap();
        index
            .upsert_all_for_source("webdav://nas/movies", &[entry("2", "movie remote.mkv")])
            .unwrap();

        // Default query does not filter by source.
        assert_eq!(index.search("movie", 10).unwrap().len(), 2);
        assert_eq!(index.search("mo", 10).unwrap().len(), 2);

        let remote = index
            .search_in_source("webdav://nas/movies", "movie", 10)
            .unwrap();
        assert_eq!(remote.len(), 1);
        assert_eq!(remote[0].id, "2");

        let local = index.search_in_source(DEFAULT_SOURCE, "movie", 10).unwrap();
        assert_eq!(local.len(), 1);
        assert_eq!(local[0].id, "1");

        // LIKE fallback path honors the filter too.
        let remote = index
            .search_in_source("webdav://nas/movies", "mo", 10)
            .unwrap();
        assert_eq!(remote.len(), 1);
        assert_eq!(remote[0].id, "2");

        assert_eq!(index.count().unwrap(), 2);
    }

    #[test]
    fn special_characters_and_injection_safety() {
        let index = Index::open_in_memory().unwrap();
        index
            .upsert_all(&[
                entry("1", "rock & roll.txt"),
                entry("2", "it's fine.txt"),
                entry("3", "say \"hi\".txt"),
                entry("4", "100% real.db"),
                entry("5", "star_trek.mkv"),
            ])
            .unwrap();

        // Punctuation must be treated literally and never break the query.
        assert_eq!(index.search("&", 10).unwrap()[0].id, "1");
        assert_eq!(index.search("it's", 10).unwrap()[0].id, "2");
        assert_eq!(index.search("\"hi\"", 10).unwrap()[0].id, "3");
        assert_eq!(index.search("%", 10).unwrap()[0].id, "4");
        assert_eq!(index.search("_", 10).unwrap()[0].id, "5");
        assert_eq!(index.search("star_trek", 10).unwrap()[0].id, "5");

        // Classic injection attempts must simply match nothing (no error).
        for attack in ["\" OR 1=1 --", "'; DROP TABLE entries; --", "%%%", "\"***"] {
            let hits = index.search(attack, 10).unwrap();
            assert!(hits.is_empty(), "{attack} matched unexpectedly");
        }
        assert_eq!(index.count().unwrap(), 5);
    }

    #[test]
    fn lock_survives_poisoning() {
        // 模拟「持锁线程被 panic 打断」后的锁中毒：老实现下此后所有 DB 操作
        // 永久失败（移动端进程被 kill 场景的同类形态）。
        let index = Index::open_in_memory().unwrap();
        struct SendPtr(usize);
        unsafe impl Send for SendPtr {}
        let ptr = SendPtr(&index as *const Index as usize);
        let handle = std::thread::spawn(move || {
            let index = unsafe { &*(ptr.0 as *const Index) };
            let conn = index.conn.lock();
            let _guard = conn.unwrap_or_else(|e| e.into_inner());
            panic!("boom while holding the index lock");
        });
        assert!(handle.join().is_err()); // 线程确实 panic 了（锁已中毒）

        // 锁中毒后必须还能正常读写（SQLite 事务本身保证一致性）。
        index.upsert(&entry("/a.txt", "a.txt")).unwrap();
        assert_eq!(index.search("a.txt", 10).unwrap().len(), 1);
    }

    #[test]
    fn remove_and_clear_keep_fts_in_sync() {
        let index = Index::open_in_memory().unwrap();
        index
            .upsert_all(&[entry("1", "Interstellar.mkv"), entry("2", "西游记.mkv")])
            .unwrap();
        index.remove("2").unwrap();
        assert_eq!(index.search("xiyouji", 10).unwrap().len(), 0);
        assert_eq!(index.search("inter", 10).unwrap().len(), 1);
        index.clear().unwrap();
        assert_eq!(index.search("inter", 10).unwrap().len(), 0);
        assert_eq!(index.count().unwrap(), 0);
    }

    #[test]
    fn migration_from_like_based_database() {
        // Simulate a database produced by the old LIKE-based version: no
        // `source` column, no FTS table.
        let dir =
            std::env::temp_dir().join(format!("sfiles-index-migration-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("old.sqlite");
        let _ = std::fs::remove_file(&path);
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                r#"
                CREATE TABLE entries (
                    id          TEXT PRIMARY KEY,
                    parent      TEXT,
                    name        TEXT NOT NULL,
                    kind        INTEGER NOT NULL,
                    size        INTEGER NOT NULL DEFAULT 0,
                    modified_ms INTEGER,
                    mime        TEXT,
                    hidden      INTEGER NOT NULL DEFAULT 0,
                    readonly    INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO entries (id, parent, name, kind, size)
                VALUES ('1', '/root', '西游记.mkv', 0, 42);
                "#,
            )
            .unwrap();
        }

        let index = Index::open(&path).unwrap();
        assert_eq!(index.count().unwrap(), 1);
        // Existing rows are rebuilt into the FTS table, pinyin included,
        // and default to the local source.
        assert_eq!(single_hit(&index, "西游记"), "西游记.mkv");
        assert_eq!(single_hit(&index, "xiyouji"), "西游记.mkv");
        assert_eq!(
            index
                .search_in_source(DEFAULT_SOURCE, "xiyouji", 10)
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            index
                .search_in_source("webdav://nas", "xiyouji", 10)
                .unwrap()
                .len(),
            0
        );

        std::fs::remove_dir_all(&dir).unwrap();
    }

    fn single_hit(index: &Index, query: &str) -> String {
        let hits = index.search(query, 10).unwrap();
        assert_eq!(hits.len(), 1, "query {query:?} should hit exactly once");
        hits[0].name.clone()
    }
}
