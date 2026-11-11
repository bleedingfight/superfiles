//! SMB→local throughput benchmark (dev tool, not shipped).
//!
//! ```bash
//! SF_SMB_HOST=192.168.31.10 SF_SMB_SHARE=Media SF_SMB_USER=liushuai \
//! SF_SMB_PASS=... SF_SMB_FILE=Videos/audio_logics.mov \
//!   cargo run -p sfiles-engine --example smb_bench --release
//! ```
//!
//! Reports raw single-stream read, dual concurrent read (the engine's copy
//! pattern), quad concurrent read, and a full engine copy into `SF_BENCH_DEST`.

use std::sync::Arc;
use std::time::Instant;

use sfiles_engine::{run, ConflictPolicy, CopyOptions, TransferHandle};
use vfs_core::backends::{SmbAuth, SmbBackend};
use vfs_core::{Backend, CancelToken, Vfs};

const MIB: usize = 1024 * 1024;
const CHUNK: u64 = MIB as u64;

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} not set"))
}

fn rate(bytes: u64, secs: f64) -> f64 {
    bytes as f64 / 1024.0 / 1024.0 / secs
}

async fn raw_read(backend: &SmbBackend, id: &str, size: u64, lanes: u64) -> f64 {
    let mut done = 0u64;
    let started = Instant::now();
    let mut offset = 0u64;

    macro_rules! read_at {
        ($off:expr) => {{
            let off = $off;
            let len = CHUNK.min(size.saturating_sub(off)) as usize;
            backend.read_range(id, off, len)
        }};
    }

    while offset < size {
        let total = match lanes {
            1 => read_at!(offset).await.expect("read").len() as u64,
            2 => {
                let (a, b) = tokio::join!(read_at!(offset), read_at!(offset + CHUNK));
                a.expect("read").len() as u64 + b.expect("read").len() as u64
            }
            4 => {
                let (a, b, c, d) = tokio::join!(
                    read_at!(offset),
                    read_at!(offset + CHUNK),
                    read_at!(offset + 2 * CHUNK),
                    read_at!(offset + 3 * CHUNK)
                );
                a.expect("read").len() as u64
                    + b.expect("read").len() as u64
                    + c.expect("read").len() as u64
                    + d.expect("read").len() as u64
            }
            8 => {
                let (a, b, c, d) = tokio::join!(
                    read_at!(offset),
                    read_at!(offset + CHUNK),
                    read_at!(offset + 2 * CHUNK),
                    read_at!(offset + 3 * CHUNK)
                );
                let (e, f, g, h) = tokio::join!(
                    read_at!(offset + 4 * CHUNK),
                    read_at!(offset + 5 * CHUNK),
                    read_at!(offset + 6 * CHUNK),
                    read_at!(offset + 7 * CHUNK)
                );
                [a, b, c, d, e, f, g, h]
                    .into_iter()
                    .map(|r| r.expect("read").len() as u64)
                    .sum()
            }
            16 => {
                let (a, b, c, d) = tokio::join!(
                    read_at!(offset),
                    read_at!(offset + CHUNK),
                    read_at!(offset + 2 * CHUNK),
                    read_at!(offset + 3 * CHUNK)
                );
                let (e, f, g, h) = tokio::join!(
                    read_at!(offset + 4 * CHUNK),
                    read_at!(offset + 5 * CHUNK),
                    read_at!(offset + 6 * CHUNK),
                    read_at!(offset + 7 * CHUNK)
                );
                let (i, j, k, l) = tokio::join!(
                    read_at!(offset + 8 * CHUNK),
                    read_at!(offset + 9 * CHUNK),
                    read_at!(offset + 10 * CHUNK),
                    read_at!(offset + 11 * CHUNK)
                );
                let (m, n, o, p) = tokio::join!(
                    read_at!(offset + 12 * CHUNK),
                    read_at!(offset + 13 * CHUNK),
                    read_at!(offset + 14 * CHUNK),
                    read_at!(offset + 15 * CHUNK)
                );
                [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p]
                    .into_iter()
                    .map(|r| r.expect("read").len() as u64)
                    .sum()
            }
            _ => unreachable!(),
        };
        if total == 0 {
            break;
        }
        done += total;
        offset += CHUNK * lanes;
    }
    let secs = started.elapsed().as_secs_f64();
    println!(
        "  raw read  lanes={lanes:<2} {:>8.1} MiB/s  ({secs:.2}s)",
        rate(done, secs)
    );
    rate(done, secs)
}

#[tokio::main]
async fn main() {
    let host = env("SF_SMB_HOST");
    let share = env("SF_SMB_SHARE");
    let user = std::env::var("SF_SMB_USER").unwrap_or_default();
    let pass = std::env::var("SF_SMB_PASS").unwrap_or_default();
    let rel = env("SF_SMB_FILE");

    let auth = if user.is_empty() {
        SmbAuth::guest()
    } else {
        SmbAuth::new(user, pass)
    };
    let backend = Arc::new(
        SmbBackend::connect(&host, &share, None, auth)
            .await
            .expect("connect"),
    );
    let root = backend.root_id();
    let id = format!("{root}/{rel}");
    let entry = backend.stat(&id).await.expect("stat");
    println!(
        "file: {id}  ({:.1} MiB)",
        entry.size as f64 / 1024.0 / 1024.0
    );

    // Warm the connection/handle once.
    backend.read_range(&id, 0, 4096).await.expect("warmup");

    // Probe: how much does one READ request actually return, and how long
    // does the round trip take? A short return means the loop inside
    // `read_range` issues several sequential READs per chunk.
    for len in [64 * 1024usize, 256 * 1024, MIB, 4 * MIB] {
        let started = Instant::now();
        let got = backend.read_range(&id, 0, len).await.expect("probe").len();
        let ms = started.elapsed().as_secs_f64() * 1000.0;
        println!(
            "  probe len={:>7} → {:>7} bytes in {:>6.2} ms  ({:>6.1} MiB/s)",
            len,
            got,
            ms,
            got as f64 / 1024.0 / 1024.0 / (ms / 1000.0)
        );
    }

    raw_read(&backend, &id, entry.size, 1).await;
    raw_read(&backend, &id, entry.size, 2).await;
    raw_read(&backend, &id, entry.size, 4).await;
    raw_read(&backend, &id, entry.size, 8).await;
    raw_read(&backend, &id, entry.size, 16).await;

    let dest = env("SF_BENCH_DEST");
    std::fs::create_dir_all(&dest).expect("dest dir");
    let vfs = Arc::new({
        let vfs = Vfs::with_local_root(&dest).expect("local root");
        vfs.mount_at(&root, backend.clone());
        vfs
    });

    let started = Instant::now();
    let handle = Arc::new(TransferHandle::new("bench", CancelToken::new()));
    run(
        vfs.clone(),
        vec![id.clone()],
        vfs.local_root().to_string(),
        CopyOptions {
            chunk_size: MIB,
            conflict: ConflictPolicy::Overwrite,
            recursive: true,
            ..Default::default()
        },
        handle.clone(),
    )
    .await;
    let secs = started.elapsed().as_secs_f64();
    let snap = handle.snapshot();
    let state = snap.state;
    println!(
        "  engine copy → {dest}: {:>8.1} MiB/s  ({secs:.2}s, state {state:?})",
        rate(snap.bytes_done, secs),
    );
}
