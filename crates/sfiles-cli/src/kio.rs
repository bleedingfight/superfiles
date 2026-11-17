//! `kio` — fixed-shape IPC surface for the KDE KIO worker (Dolphin).
//!
//! The worker (apps/kio-worker, the `superfiles://` protocol) never links
//! into the kernel: it spawns `sfiles kio …` and consumes line-oriented
//! JSON, so the whole kernel stays in Rust and the C++ side stays thin.
//!
//! ```text
//! sfiles kio mounts       # [{"label","kind","root_id"} …]
//! sfiles kio ls <id>      # entry objects, one per line
//! sfiles kio stat <id>    # one entry object
//! sfiles kio cat <id>     # raw bytes -> stdout (read_to_fd passthrough)
//! ```
//!
//! Mounts are declarative, in `$SF_CONFIG` (default
//! `~/.config/superfiles/mounts.json`, see apps/kio-worker/mounts.example.json):
//! local storages are the same jailed LocalBackend the mobile apps ship,
//! remote storages are the same WebDAV/SMB/SFTP backends, prefix-mounted
//! via `Vfs::mount_at` — the same path the FFI `mount_webdav/smb/sftp`
//! take. Nothing here can bypass a jail by construction.

use std::io::Write;
use std::path::PathBuf;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use vfs_core::{backends, CancelToken, Entry, EntryKind, Vfs};

type BoxError = Box<dyn std::error::Error>;

/// $SF_CONFIG, else ~/.config/superfiles/mounts.json.
fn config_path() -> Result<PathBuf, BoxError> {
    if let Ok(path) = std::env::var("SF_CONFIG") {
        if !path.is_empty() {
            return Ok(PathBuf::from(path));
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/".to_string());
    Ok(PathBuf::from(home).join(".config/superfiles/mounts.json"))
}

#[derive(Debug, Default, Deserialize)]
struct StorageTable {
    #[serde(default)]
    storages: Vec<Storage>,
}

#[derive(Debug, Deserialize)]
struct Storage {
    label: String,
    #[serde(flatten)]
    conf: Conf,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum Conf {
    Local {
        root: PathBuf,
    },
    Webdav {
        base_url: String,
        #[serde(default)]
        username: String,
        #[serde(default)]
        password: String,
    },
    Smb {
        server: String,
        share: String,
        #[serde(default)]
        port: Option<u16>,
        #[serde(default)]
        username: String,
        #[serde(default)]
        password: String,
    },
    Sftp {
        server: String,
        #[serde(default)]
        port: Option<u16>,
        #[serde(default)]
        username: String,
        #[serde(default)]
        password: String,
    },
}

#[derive(Serialize)]
struct MountOut<'a> {
    label: &'a str,
    kind: &'static str,
    root_id: &'a str,
}

#[derive(Serialize)]
struct EntryOut<'a> {
    id: &'a str,
    name: &'a str,
    kind: &'static str,
    size: u64,
    modified_ms: Option<i64>,
    mime: Option<&'a str>,
    hidden: bool,
    readonly: bool,
}

fn kind_str(kind: &EntryKind) -> &'static str {
    match kind {
        EntryKind::Directory => "dir",
        EntryKind::Symlink => "symlink",
        EntryKind::Special => "special",
        EntryKind::File => "file",
    }
}

fn entry_out(entry: &Entry) -> EntryOut<'_> {
    EntryOut {
        id: &entry.id,
        name: &entry.name,
        kind: kind_str(&entry.kind),
        size: entry.size,
        modified_ms: entry.modified_ms,
        mime: entry.mime.as_deref(),
        hidden: entry.hidden,
        readonly: entry.readonly,
    }
}

/// One flat, resolved mount: what the worker's virtual root is made of.
struct FlatMount {
    label: String,
    kind: &'static str,
    root_id: String,
}

/// Build a VFS holding every configured storage.
///
/// Each storage (including local ones) is a prefix mount, so `list/stat/cat`
/// below only ever speak backend ids. A missing or empty config falls back to
/// a single jailed `$HOME` under the label "Home".
async fn build_vfs() -> Result<(Vfs, Vec<FlatMount>), BoxError> {
    let path = config_path()?;
    let table: StorageTable = match std::fs::read_to_string(&path) {
        Ok(raw) if !raw.trim().is_empty() => serde_json::from_str(&raw)
            .map_err(|e| format!("bad mounts config at {}: {e}", path.display()))?,
        _ => StorageTable::default(),
    };

    let mut mounts: Vec<FlatMount> = Vec::new();
    let vfs = Vfs::new();

    for storage in table.storages {
        let label = storage.label;
        match storage.conf {
            Conf::Local { root } => {
                let backend = Arc::new(backends::LocalBackend::new(&root)?);
                let root_id = backend.root_id();
                vfs.mount_at(&root_id, backend);
                mounts.push(FlatMount {
                    label,
                    kind: "local",
                    root_id,
                });
            }
            Conf::Webdav {
                base_url,
                username,
                password,
            } => {
                let auth = if username.is_empty() && password.is_empty() {
                    backends::WebdavAuth::None
                } else {
                    backends::WebdavAuth::Basic { username, password }
                };
                let backend = Arc::new(backends::WebdavBackend::new(&base_url, auth)?);
                let root_id = backend.root_id();
                vfs.mount_at(&root_id, backend);
                mounts.push(FlatMount {
                    label,
                    kind: "webdav",
                    root_id,
                });
            }
            Conf::Smb {
                server,
                share,
                port,
                username,
                password,
            } => {
                let auth = if username.is_empty() && password.is_empty() {
                    backends::SmbAuth::guest()
                } else {
                    backends::SmbAuth::new(username, password)
                };
                let backend =
                    Arc::new(backends::SmbBackend::connect(&server, &share, port, auth).await?);
                let root_id = backend.root_id();
                vfs.mount_at(&root_id, backend);
                mounts.push(FlatMount {
                    label,
                    kind: "smb",
                    root_id,
                });
            }
            Conf::Sftp {
                server,
                port,
                username,
                password,
            } => {
                let auth = if username.is_empty() {
                    return Err(format!("sftp storage '{label}': username is required").into());
                } else {
                    backends::SftpAuth::Password { username, password }
                };
                let backend = Arc::new(
                    backends::SftpBackend::connect(&server, port.unwrap_or(22), auth).await?,
                );
                let root_id = backend.root_id();
                vfs.mount_at(&root_id, backend);
                mounts.push(FlatMount {
                    label,
                    kind: "sftp",
                    root_id,
                });
            }
        }
    }

    if mounts.is_empty() {
        let home = PathBuf::from(std::env::var("HOME").map_err(|_| "$HOME is not set")?);
        let backend = Arc::new(backends::LocalBackend::new(&home)?);
        let root_id = backend.root_id();
        vfs.mount_at(&root_id, backend);
        mounts.push(FlatMount {
            label: "Home".to_string(),
            kind: "local",
            root_id,
        });
    }

    Ok((vfs, mounts))
}

pub async fn run(args: &[String]) -> Result<(), BoxError> {
    let Some(command) = args.first().map(String::as_str) else {
        print_help();
        return Ok(());
    };

    match command {
        "mounts" => {
            let (_, mounts) = build_vfs().await?;
            let stdout = std::io::stdout();
            let mut out = stdout.lock();
            for mount in &mounts {
                serde_json::to_writer(
                    &mut out,
                    &MountOut {
                        label: &mount.label,
                        kind: mount.kind,
                        root_id: &mount.root_id,
                    },
                )?;
                writeln!(out)?;
            }
        }
        "ls" => {
            let id = need(args, 1, "sfiles kio ls <id>")?;
            let (vfs, _) = build_vfs().await?;
            let stdout = std::io::stdout();
            let mut out = stdout.lock();
            for entry in vfs.list(id).await? {
                serde_json::to_writer(&mut out, &entry_out(&entry))?;
                writeln!(out)?;
            }
        }
        "stat" => {
            let id = need(args, 1, "sfiles kio stat <id>")?;
            let (vfs, _) = build_vfs().await?;
            let entry = vfs.stat(id).await?;
            serde_json::to_writer(std::io::stdout(), &entry_out(&entry))?;
            println!();
        }
        "cat" => {
            let id = need(args, 1, "sfiles kio cat <id>")?;
            let (vfs, _) = build_vfs().await?;
            let cancel = CancelToken::new();
            // `1` is fd 1 (stdout); backends stream straight into it, binary safe.
            vfs.read_to_fd(id, 1, 0, &cancel).await?;
        }
        "-h" | "--help" | "help" => print_help(),
        other => {
            eprintln!("unknown kio command: {other}");
            print_help();
            return Err("unknown command".into());
        }
    }
    Ok(())
}

fn need<'a>(args: &'a [String], index: usize, usage: &str) -> Result<&'a str, BoxError> {
    args.get(index)
        .map(String::as_str)
        .ok_or_else(|| format!("usage: {usage}").into())
}

fn print_help() {
    println!(
        "sfiles kio — KDE KIO worker surface (Dolphin superfiles://)

USAGE:
  sfiles kio mounts              list the mount registry as JSON lines
  sfiles kio ls <id>             list a directory as JSON lines
  sfiles kio stat <id>           one entry as a single JSON line
  sfiles kio cat <id>            stream a file's raw bytes to stdout

Mounts come from $SF_CONFIG, default ~/.config/superfiles/mounts.json
(example: apps/kio-worker/mounts.example.json)."
    );
}
