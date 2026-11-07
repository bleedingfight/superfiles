//! Persistent metadata index.
//!
//! Purpose: show a directory instantly (even on a slow SMB share), support
//! offline browsing and global search, and keep transfer state across app
//! restarts. SQLite is used because it is available on every target and ships
//! with the OS on iOS/Android (we still bundle for consistency).
//!
//! Search intentionally uses plain `LIKE` for M0. FTS5 with unicode61/pinyin
//! tokenization is planned once the CJK search requirements are settled.

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{params, Connection};
use vfs_core::{Entry, EntryKind, Result, VfsError};

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
        let conn = self.lock()?;
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
                readonly    INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_entries_parent ON entries(parent);
            CREATE INDEX IF NOT EXISTS idx_entries_name ON entries(name);
            "#,
        )
        .map_err(db_err)
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Connection>> {
        self.conn
            .lock()
            .map_err(|_| VfsError::Io("index lock poisoned".into()))
    }

    pub fn upsert(&self, entry: &Entry) -> Result<()> {
        let conn = self.lock()?;
        conn.execute(
            r#"INSERT INTO entries (id, parent, name, kind, size, modified_ms, mime, hidden, readonly)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
               ON CONFLICT(id) DO UPDATE SET
                 parent=excluded.parent, name=excluded.name, kind=excluded.kind,
                 size=excluded.size, modified_ms=excluded.modified_ms, mime=excluded.mime,
                 hidden=excluded.hidden, readonly=excluded.readonly"#,
            params![
                entry.id,
                entry.parent,
                entry.name,
                kind_code(entry.kind),
                entry.size as i64,
                entry.modified_ms,
                entry.mime,
                entry.hidden as i64,
                entry.readonly as i64,
            ],
        )
        .map_err(db_err)?;
        Ok(())
    }

    /// Batch upsert inside a single transaction (one fsync instead of N).
    pub fn upsert_all(&self, entries: &[Entry]) -> Result<()> {
        if entries.is_empty() {
            return Ok(());
        }
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(db_err)?;
        {
            let mut stmt = tx
                .prepare(
                    r#"INSERT INTO entries (id, parent, name, kind, size, modified_ms, mime, hidden, readonly)
                       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                       ON CONFLICT(id) DO UPDATE SET
                         parent=excluded.parent, name=excluded.name, kind=excluded.kind,
                         size=excluded.size, modified_ms=excluded.modified_ms, mime=excluded.mime,
                         hidden=excluded.hidden, readonly=excluded.readonly"#,
                )
                .map_err(db_err)?;
            for entry in entries {
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
                ])
                .map_err(db_err)?;
            }
        }
        tx.commit().map_err(db_err)
    }

    pub fn remove(&self, id: &str) -> Result<()> {
        let conn = self.lock()?;
        conn.execute("DELETE FROM entries WHERE id = ?1", params![id])
            .map_err(db_err)?;
        Ok(())
    }

    pub fn clear(&self) -> Result<()> {
        let conn = self.lock()?;
        conn.execute("DELETE FROM entries", []).map_err(db_err)?;
        Ok(())
    }

    pub fn count(&self) -> Result<u64> {
        let conn = self.lock()?;
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM entries", [], |row| row.get(0))
            .map_err(db_err)?;
        Ok(count as u64)
    }

    /// Substring search over file names, newest modification first.
    pub fn search(&self, query: &str, limit: u32) -> Result<Vec<Entry>> {
        let conn = self.lock()?;
        let pattern = format!("%{}%", escape_like(query));
        let mut stmt = conn
            .prepare(
                r#"SELECT id, parent, name, kind, size, modified_ms, mime, hidden, readonly
                   FROM entries
                   WHERE name LIKE ?1 ESCAPE '\'
                   ORDER BY modified_ms DESC
                   LIMIT ?2"#,
            )
            .map_err(db_err)?;
        let rows = stmt
            .query_map(params![pattern, limit as i64], row_to_entry)
            .map_err(db_err)?;
        let mut entries = Vec::new();
        for row in rows {
            entries.push(row.map_err(db_err)?);
        }
        Ok(entries)
    }
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
}
