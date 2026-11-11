//! Does a background transfer starve foreground calls?
//!
//! Mimics the FFI facade: one multi-thread runtime (worker count from
//! `SF_WORKERS`), a copy spawned onto it, and `vfs.list()`/`stat()` driven via
//! `block_on` from the caller thread — exactly the shape of a UI call while a
//! transfer runs.
//!
//! ```bash
//! SF_WORKERS=2 SF_SMB_HOST=... SF_SMB_SHARE=... SF_SMB_USER=... \
//! SF_SMB_PASS=... SF_SMB_FILE=Videos/audio_logics.mov \
//!   cargo run -q -p sfiles-engine --release --example interference_bench
//! ```

use std::sync::Arc;
use std::time::{Duration, Instant};

use sfiles_engine::{run_resumable, ConflictPolicy, CopyOptions, TransferHandle};
use sfiles_index::Index;
use vfs_core::backends::{SmbAuth, SmbBackend};
use vfs_core::{Backend, CancelToken, Vfs};

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} not set"))
}

fn pct(values: &mut [Duration], p: f64) -> f64 {
    values.sort();
    let idx = ((values.len() as f64 - 1.0) * p).round() as usize;
    values[idx].as_secs_f64() * 1000.0
}

fn main() {
    let workers: usize = std::env::var("SF_WORKERS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(2);
    let host = env("SF_SMB_HOST");
    let share = env("SF_SMB_SHARE");
    let user = std::env::var("SF_SMB_USER").unwrap_or_default();
    let pass = std::env::var("SF_SMB_PASS").unwrap_or_default();
    let rel = env("SF_SMB_FILE");

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(workers)
        .thread_name("sf-test-core")
        .enable_all()
        .build()
        .unwrap();

    let backend = rt
        .block_on(SmbBackend::connect(
            &host,
            &share,
            None,
            if user.is_empty() {
                SmbAuth::guest()
            } else {
                SmbAuth::new(user, pass)
            },
        ))
        .expect("connect");
    let root = backend.root_id();
    let file_id = format!("{root}/{rel}");

    let dest = std::env::temp_dir().join(format!("sf-interf-{workers}"));
    std::fs::create_dir_all(&dest).unwrap();
    let vfs = Arc::new({
        let vfs = Vfs::with_local_root(&dest).unwrap();
        vfs.mount_at(&root, Arc::new(backend));
        vfs
    });

    let mut baseline = Vec::new();
    for _ in 0..5 {
        let t = Instant::now();
        let _ = rt.block_on(vfs.list(&root)).expect("list");
        baseline.push(t.elapsed());
    }

    let index = Arc::new(Index::open(dest.join("bench.sqlite")).unwrap());
    let handle = Arc::new(TransferHandle::new("bench", CancelToken::new()));
    rt.spawn(run_resumable(
        vfs.clone(),
        vec![file_id.clone()],
        vfs.local_root().to_string(),
        CopyOptions {
            conflict: ConflictPolicy::Overwrite,
            ..Default::default()
        },
        handle.clone(),
        index,
        None,
    ));

    std::thread::sleep(Duration::from_millis(300));
    let mut during = Vec::new();
    for _ in 0..25 {
        let t = Instant::now();
        let _ = rt.block_on(vfs.list(&root)).expect("list");
        during.push(t.elapsed());
        std::thread::sleep(Duration::from_millis(80));
    }
    let snap = handle.snapshot();
    println!(
        "workers={workers}  list baseline p50={:.1}ms max={:.1}ms | during copy p50={:.1}ms p95={:.1}ms max={:.1}ms  (copy {:.0} MiB done)",
        pct(&mut baseline.clone(), 0.5),
        pct(&mut baseline, 1.0),
        pct(&mut during.clone(), 0.5),
        pct(&mut during.clone(), 0.95),
        pct(&mut during, 1.0),
        snap.bytes_done as f64 / 1024.0 / 1024.0,
    );
}
