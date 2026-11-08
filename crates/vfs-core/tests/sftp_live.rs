//! Live-server compatibility matrix runner for SFTP (docs/03-vfs-api.md §6).
//!
//! Skipped silently unless a server is configured:
//!
//! ```bash
//! SF_TEST_SFTP_HOST=127.0.0.1 SF_TEST_SFTP_PORT=2222 \
//! SF_TEST_SFTP_USER=test SF_TEST_SFTP_PASS=test123 \
//!   cargo test -p vfs-core --test sftp_live --features sftp -- --nocapture
//! ```
//!
//! SFTP has *native* random reads/writes and SETSTAT.fsize, so both phases
//! must pass on every server. Everything runs inside a unique `sfiles-it-*`
//! folder under the login home (the mount root).

#![cfg(feature = "sftp")]

use std::time::{SystemTime, UNIX_EPOCH};

use vfs_core::backends::{SftpAuth, SftpBackend};
use vfs_core::{Backend, EntryKind};

fn config() -> Option<(String, u16, SftpAuth)> {
    let host = std::env::var("SF_TEST_SFTP_HOST").ok()?;
    let port = std::env::var("SF_TEST_SFTP_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(22);
    let user = std::env::var("SF_TEST_SFTP_USER").unwrap_or_else(|_| "test".into());
    let auth = match (
        std::env::var("SF_TEST_SFTP_PASS").ok(),
        std::env::var("SF_TEST_SFTP_KEY").ok(),
    ) {
        (_, Some(pem)) => {
            SftpAuth::private_key(user, pem, std::env::var("SF_TEST_SFTP_KEY_PASS").ok())
        }
        (Some(pass), None) => SftpAuth::password(user, pass),
        (None, None) => SftpAuth::password(user, ""),
    };
    Some((host, port, auth))
}

#[tokio::test]
async fn live_roundtrip() {
    let _ = env_logger::try_init();
    let Some((host, port, auth)) = config() else {
        eprintln!("SF_TEST_SFTP_HOST not set; skipping live matrix run");
        return;
    };
    let backend = SftpBackend::connect(&host, port, auth).await.unwrap();
    let root = backend.root_id();
    let tag = format!(
        "sfiles-it-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis()
    );
    eprintln!("== server: {root}  workdir: {tag}");

    let base_id = format!("{root}/{tag}");
    let result = run(&backend, &root, &tag).await;
    let _ = backend.remove(&base_id, true).await; // best-effort cleanup

    if let Err(e) = result {
        panic!("MATRIX FAIL [{root}]: {e}");
    }
    eprintln!("== MATRIX PASS [{root}]");
}

async fn run(backend: &SftpBackend, root: &str, tag: &str) -> vfs_core::Result<()> {
    // 1. Browsing + illegal names + entry metadata (incl. unicode, spaces).
    let base = backend.create_dir(root, tag).await?;
    let tricky = backend.create_dir(&base.id, "我的 photos 100%").await?;
    assert_eq!(tricky.kind, EntryKind::Directory);
    assert!(backend.create_dir(&base.id, "bad/name").await.is_err());

    let file = backend.create_file(&tricky.id, "cat (1).jpg").await?;
    let payload: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
    backend.write_range(&file.id, 0, &payload).await?;
    let stat = backend.stat(&file.id).await?;
    assert_eq!(stat.size, payload.len() as u64);
    assert!(stat.modified_ms.is_some(), "mtime from the wire");
    assert_eq!(
        backend.read_range(&file.id, 250, 4).await?,
        &payload[250..254]
    );
    assert_eq!(
        backend.read_range(&file.id, 300_000, 4).await?,
        Vec::<u8>::new()
    );
    eprintln!("-- phase A (browse, metadata, whole-file CRUD): PASS");

    // 2. Native random writes: chunked upload + POSIX middle write.
    let chunked = backend.create_file(&tricky.id, "chunked.bin").await?;
    for n in 0..5u8 {
        backend
            .write_range(&chunked.id, n as u64 * 10_000, &vec![n; 10_000])
            .await?;
    }
    assert_eq!(backend.stat(&chunked.id).await?.size, 50_000);
    assert_eq!(
        backend.read_range(&chunked.id, 40_000, 10_000).await?,
        vec![4u8; 10_000]
    );
    backend.write_range(&chunked.id, 5_000, b"STITCH").await?;
    let probe = backend.read_range(&chunked.id, 4_998, 12).await?;
    assert_eq!(&probe[..2], &[0u8; 2]);
    assert_eq!(&probe[2..8], b"STITCH");
    assert_eq!(&probe[8..], &[0u8; 4]);

    // 3. Engine overwrite flow: shrink via native SETSTAT.fsize.
    backend.write_range(&file.id, 0, &vec![9u8; 1_000]).await?;
    backend.truncate(&file.id, 1_000).await?;
    assert_eq!(backend.stat(&file.id).await?.size, 1_000);
    assert_eq!(
        backend.read_range(&file.id, 0, 1_100).await?,
        vec![9u8; 1_000]
    );

    // 4. Rename (name only), remove guards, recursive delete.
    let renamed = backend.rename(&chunked.id, "renamed.bin").await?;
    assert_eq!(renamed.name, "renamed.bin");
    assert_eq!(backend.list(&tricky.id).await?.len(), 2);
    assert!(backend.remove(&tricky.id, false).await.is_err());
    backend.remove(&tricky.id, true).await?;
    assert_eq!(backend.list(&base.id).await?.len(), 0);
    eprintln!("-- phase B (native random write/truncate/rename/remove): PASS");
    Ok(())
}
