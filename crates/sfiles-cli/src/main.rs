//! `sfiles` — a minimal CLI over the same core the mobile apps use.
//!
//! It exists for three reasons:
//!   1. smoke-test the core on a desktop without Xcode/Android Studio;
//!   2. prove the core has no mobile-specific assumptions;
//!   3. give the future desktop/terminal target a starting point.

use std::sync::Arc;

use vfs_core::{CancelToken, Entry, EntryKind, Vfs};

#[tokio::main]
async fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args).await {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("error: {err}");
            std::process::ExitCode::FAILURE
        }
    }
}

async fn run(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let Some(command) = args.first().map(String::as_str) else {
        print_help();
        return Ok(());
    };

    match command {
        "ls" => {
            let root = need(args, 1, "sfiles ls <root> [path]")?;
            let vfs = Vfs::with_local_root(root)?;
            let id = args
                .get(2)
                .cloned()
                .unwrap_or_else(|| vfs.local_root().to_string());
            for entry in vfs.list(&id).await? {
                print_entry(&entry);
            }
        }
        "mkdir" => {
            let root = need(args, 1, "sfiles mkdir <root> <name>")?;
            let name = need(args, 2, "sfiles mkdir <root> <name>")?;
            let vfs = Vfs::with_local_root(root)?;
            let parent = vfs.local_root().to_string();
            let entry = vfs.create_dir(&parent, name).await?;
            println!("created {}", entry.id);
        }
        "rm" => {
            let root = need(args, 1, "sfiles rm <root> <path>")?;
            let path = need(args, 2, "sfiles rm <root> <path>")?;
            let vfs = Vfs::with_local_root(root)?;
            vfs.remove(path, true).await?;
            println!("removed {path}");
        }
        "cp" => {
            let root = need(args, 1, "sfiles cp <root> <src> <dest-dir>")?;
            let src = need(args, 2, "sfiles cp <root> <src> <dest-dir>")?;
            let dest = need(args, 3, "sfiles cp <root> <src> <dest-dir>")?;
            let vfs = Arc::new(Vfs::with_local_root(root)?);
            let handle = Arc::new(sfiles_engine::TransferHandle::new(
                "cli",
                CancelToken::new(),
            ));
            sfiles_engine::run(
                vfs,
                vec![src.to_string()],
                dest.to_string(),
                sfiles_engine::CopyOptions::default(),
                handle.clone(),
            )
            .await;
            let snapshot = handle.snapshot();
            println!(
                "{:?}: {}/{} bytes, {}/{} files{}",
                snapshot.state,
                snapshot.bytes_done,
                snapshot.bytes_total,
                snapshot.files_done,
                snapshot.files_total,
                snapshot
                    .error
                    .map(|error| format!(" ({error})"))
                    .unwrap_or_default()
            );
        }
        "index" => {
            let root = need(args, 1, "sfiles index <root> <db.sqlite>")?;
            let db = need(args, 2, "sfiles index <root> <db.sqlite>")?;
            let vfs = Vfs::with_local_root(root)?;
            let index = sfiles_index::Index::open(db)?;
            let mut stack = vec![vfs.local_root().to_string()];
            let mut count = 0u64;
            while let Some(dir) = stack.pop() {
                let entries = vfs.list(&dir).await?;
                index.upsert_all(&entries)?;
                count += entries.len() as u64;
                for entry in entries {
                    if entry.is_dir() {
                        stack.push(entry.id);
                    }
                }
            }
            println!("indexed {count} entries into {db}");
        }
        "search" => {
            let db = need(args, 1, "sfiles search <db.sqlite> <query>")?;
            let query = need(args, 2, "sfiles search <db.sqlite> <query>")?;
            let index = sfiles_index::Index::open(db)?;
            for entry in index.search(query, 50)? {
                print_entry(&entry);
            }
        }
        "serve" => {
            let root = need(args, 1, "sfiles serve <root> [id]")?;
            let vfs = Arc::new(Vfs::with_local_root(root)?);
            let id = args
                .get(2)
                .cloned()
                .unwrap_or_else(|| vfs.local_root().to_string());
            let server = sfiles_stream::StreamServer::start(vfs).await?;
            println!("{}", server.url_for(&id));
            println!("(serving until Ctrl+C; open the URL in any player)");
            tokio::signal::ctrl_c().await?;
            server.shutdown().await;
        }
        "-h" | "--help" | "help" => print_help(),
        other => {
            eprintln!("unknown command: {other}");
            print_help();
            return Err("unknown command".into());
        }
    }
    Ok(())
}

fn need<'a>(
    args: &'a [String],
    index: usize,
    usage: &str,
) -> Result<&'a str, Box<dyn std::error::Error>> {
    args.get(index)
        .map(String::as_str)
        .ok_or_else(|| format!("usage: {usage}").into())
}

fn print_entry(entry: &Entry) {
    let marker = match entry.kind {
        EntryKind::Directory => 'd',
        EntryKind::Symlink => 'l',
        EntryKind::Special => '?',
        EntryKind::File => '-',
    };
    let size = if entry.kind == EntryKind::Directory {
        String::from("-")
    } else {
        human_size(entry.size)
    };
    println!("{marker} {size:>10}  {}", entry.name);
}

fn human_size(bytes: u64) -> String {
    const UNITS: [&str; 4] = ["KB", "MB", "GB", "TB"];
    if bytes < 1024 {
        return format!("{bytes} B");
    }
    let mut value = bytes as f64;
    let mut unit = 0usize;
    while value >= 1024.0 && unit < UNITS.len() {
        value /= 1024.0;
        unit += 1;
    }
    format!("{value:.1} {}", UNITS[unit - 1])
}

fn print_help() {
    println!(
        "sfiles — Super Files core CLI

USAGE:
  sfiles ls <root> [path]           list a directory
  sfiles mkdir <root> <name>        create a folder at the root
  sfiles rm <root> <path>           remove a file or folder recursively
  sfiles cp <root> <src> <dest-dir> copy a file or tree
  sfiles index <root> <db.sqlite>   index a tree into SQLite
  sfiles search <db.sqlite> <query> search the index
  sfiles serve <root> [id]          stream an entry over loopback HTTP+Range

`root` is the jail the local backend is allowed to touch."
    );
}
