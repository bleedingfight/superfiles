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
use rusqlite::{params, Connection};
use vfs_core::{Entry, EntryKind, Result, VfsError};

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
        // Rebuild the FTS table when it is out of sync with entries (e.g.
        // rows written by the LIKE-based version). Counts are reliable
        // because id is the primary key on both sides.
        let needs_rebuild: bool = conn
            .query_row(
                "SELECT (SELECT COUNT(*) FROM entries) != (SELECT COUNT(*) FROM entries_fts)",
                [],
                |row| row.get(0),
            )
            .map_err(db_err)?;
        if !needs_rebuild {
            return Ok(());
        }
        let rows: Vec<(String, String)> = {
            let mut stmt = conn
                .prepare("SELECT id, name FROM entries")
                .map_err(db_err)?;
            let rows = stmt
                .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
                .map_err(db_err)?;
            let mut collected = Vec::new();
            for row in rows {
                collected.push(row.map_err(db_err)?);
            }
            collected
        };
        let tx = conn.transaction().map_err(db_err)?;
        tx.execute("DELETE FROM entries_fts", []).map_err(db_err)?;
        {
            let mut insert = tx
                .prepare("INSERT INTO entries_fts (id, name, pinyin) VALUES (?1, ?2, ?3)")
                .map_err(db_err)?;
            for (id, name) in &rows {
                insert
                    .execute(params![id, name, pinyin_index(name)])
                    .map_err(db_err)?;
            }
        }
        tx.commit().map_err(db_err)
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Connection>> {
        self.conn
            .lock()
            .map_err(|_| VfsError::Io("index lock poisoned".into()))
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
            let mut fts_delete = tx
                .prepare("DELETE FROM entries_fts WHERE id = ?1")
                .map_err(db_err)?;
            let mut fts_insert = tx
                .prepare("INSERT INTO entries_fts (id, name, pinyin) VALUES (?1, ?2, ?3)")
                .map_err(db_err)?;
            for entry in entries {
                bind_upsert(&mut upsert_stmt, source, entry)?;
                fts_delete.execute(params![entry.id]).map_err(db_err)?;
                fts_insert
                    .execute(params![entry.id, entry.name, pinyin_index(&entry.name)])
                    .map_err(db_err)?;
            }
        }
        tx.commit().map_err(db_err)
    }

    pub fn remove(&self, id: &str) -> Result<()> {
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(db_err)?;
        tx.execute("DELETE FROM entries WHERE id = ?1", params![id])
            .map_err(db_err)?;
        tx.execute("DELETE FROM entries_fts WHERE id = ?1", params![id])
            .map_err(db_err)?;
        tx.commit().map_err(db_err)
    }

    pub fn clear(&self) -> Result<()> {
        let conn = self.lock()?;
        conn.execute_batch("DELETE FROM entries; DELETE FROM entries_fts;")
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

    /// Like [`search`](Self::search) but only returns entries written under
    /// `source` (see [`upsert_all_for_source`](Self::upsert_all_for_source)).
    pub fn search_in_source(&self, source: &str, query: &str, limit: u32) -> Result<Vec<Entry>> {
        self.search_filtered(Some(source), query, limit)
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
const UPSERT_SQL: &str = r#"INSERT INTO entries (id, parent, name, kind, size, modified_ms, mime, hidden, readonly, source)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
     ON CONFLICT(id) DO UPDATE SET
       parent=excluded.parent, name=excluded.name, kind=excluded.kind,
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
    // Keep the FTS row in sync by re-indexing the name.
    conn.execute("DELETE FROM entries_fts WHERE id = ?1", params![entry.id])
        .map_err(db_err)?;
    conn.execute(
        "INSERT INTO entries_fts (id, name, pinyin) VALUES (?1, ?2, ?3)",
        params![entry.id, entry.name, pinyin_index(&entry.name)],
    )
    .map_err(db_err)?;
    Ok(())
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
