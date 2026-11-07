//! Live-server compatibility matrix runner (docs/03-vfs-api.md §6 checklist).
//!
//! Skipped silently unless a server is configured:
//!
//! ```bash
//! SF_TEST_WEBDAV_URL=http://127.0.0.1:8080 \
//! SF_TEST_WEBDAV_USER=test SF_TEST_WEBDAV_PASS=test \
//!   cargo test -p vfs-core --test webdav_live -- --nocapture
//! ```
//!
//! Phase A (browsing / whole-file ops) must pass on every server. Phase B
//! (partial writes) is reported as a capability: plain mod_dav is expected to
//! fail it with `Unsupported`, SabreDAV servers must pass it. Everything
//! happens inside a unique `sfiles-it-*` folder which is deleted afterwards.

#![cfg(feature = "webdav")]

use std::time::{SystemTime, UNIX_EPOCH};

use vfs_core::backends::{WebdavAuth, WebdavBackend};
use vfs_core::{Backend, EntryKind, VfsError};

fn config() -> Option<(String, WebdavAuth)> {
    let url = std::env::var("SF_TEST_WEBDAV_URL").ok()?;
    let auth = match (
        std::env::var("SF_TEST_WEBDAV_USER").ok(),
        std::env::var("SF_TEST_WEBDAV_PASS").ok(),
    ) {
        (Some(username), Some(password)) => WebdavAuth::Basic { username, password },
        _ => WebdavAuth::None,
    };
    Some((url, auth))
}

#[tokio::test]
async fn live_roundtrip() {
    let Some((url, auth)) = config() else {
        eprintln!("SF_TEST_WEBDAV_URL not set; skipping live matrix run");
        return;
    };
    let backend = WebdavBackend::new(&url, auth).unwrap();
    let root = backend.root_id();
    let tag = format!(
        "sfiles-it-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis()
    );
    eprintln!("== server: {url}");
    eprintln!("== workdir: {tag}");

    let base_id = format!("{root}{tag}");
    let result = run(&backend, &root, &tag).await;
    let _ = backend.remove(&base_id, true).await; // best-effort cleanup

    if let Err(haul) = result {
        panic!("MATRIX FAIL [{url}]: {haul}");
    }
    eprintln!("== MATRIX PASS [{url}]");
}

async fn run(backend: &WebdavBackend, root: &str, tag: &str) -> vfs_core::Result<()> {
    phase_a(backend, root, tag).await?;
    eprintln!("-- phase A (browse, percent names, whole-file CRUD, guarded delete): PASS");

    match phase_b(backend, root, tag).await {
        Ok(()) => eprintln!("-- phase B (chunked / partial writes / overwrite+truncate): PASS"),
        Err(VfsError::Unsupported(msg)) => {
            eprintln!("-- phase B: server reports no partial-write support ({msg})");
            eprintln!("-- phase B: handled as a capability limit, no data corrupted: OK");
        }
        Err(other) => return Err(other),
    }
    Ok(())
}

/// Universal operations every RFC 4918 server must survive.
async fn phase_a(backend: &WebdavBackend, root: &str, tag: &str) -> vfs_core::Result<()> {
    let base = backend.create_dir(root, tag).await?;
    let tricky = backend.create_dir(&base.id, "我的 photos 100%").await?;
    assert_eq!(tricky.kind, EntryKind::Directory);

    let file = backend.create_file(&tricky.id, "cat (1).jpg").await?;
    let mut payload = Vec::new();
    for i in 0..300_000u32 {
        payload.push((i % 251) as u8);
    }
    backend.write_range(&file.id, 0, &payload).await?;
    let stat = backend.stat(&file.id).await?;
    assert_eq!(
        stat.size,
        payload.len() as u64,
        "size after whole-file write"
    );
    assert_eq!(
        backend.read_range(&file.id, 250, 4).await?,
        &payload[250..254]
    );
    assert_eq!(
        backend.read_range(&file.id, 300_000, 4).await?,
        Vec::<u8>::new()
    );

    let renamed = backend.rename(&file.id, "cat (2).jpg").await?;
    assert_eq!(renamed.name, "cat (2).jpg");
    let listed = backend.list(&tricky.id).await?;
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].size, payload.len() as u64);
    assert!(listed[0].mime.is_some(), "mime from server or extension");

    // Non-recursive remove must refuse a non-empty collection.
    assert!(backend.remove(&tricky.id, false).await.is_err());
    backend.remove(&tricky.id, true).await?;
    assert_eq!(backend.list(&base.id).await?.len(), 0);
    Ok(())
}

/// Partial-write dialects: SabreDAV passes, plain mod_dav fails loud & clear.
async fn phase_b(backend: &WebdavBackend, root: &str, tag: &str) -> vfs_core::Result<()> {
    let base = backend
        .create_dir(&format!("{root}{tag}"), "phaseb")
        .await?;
    let base_id = base.id.clone();

    let file = backend.create_file(&base_id, "chunked.bin").await?;
    let chunks: Vec<Vec<u8>> = (0..5u8).map(|n| vec![n; 10_000]).collect();
    let mut offset = 0u64;
    for chunk in &chunks {
        backend.write_range(&file.id, offset, chunk).await?; // <- Unsupported probe point
        offset += chunk.len() as u64;
    }
    assert_eq!(backend.stat(&file.id).await?.size, offset);
    assert_eq!(
        backend.read_range(&file.id, 40_000, 10_000).await?,
        vec![4u8; 10_000]
    );

    // POSIX middle write keeps the tail.
    backend.write_range(&file.id, 5_000, b"STITCH").await?;
    let probe = backend.read_range(&file.id, 4_998, 12).await?;
    assert_eq!(&probe[..2], &[0u8; 2]);
    assert_eq!(&probe[2..8], b"STITCH");
    assert_eq!(&probe[8..], &[0u8; 4]);

    // Engine overwrite flow: smaller content, then shrink leftover.
    backend.write_range(&file.id, 0, &vec![9u8; 1_000]).await?;
    backend.truncate(&file.id, 1_000).await?;
    assert_eq!(backend.stat(&file.id).await?.size, 1_000);
    assert_eq!(
        backend.read_range(&file.id, 0, 1_100).await?,
        vec![9u8; 1_000]
    );

    backend.remove(&file.id, false).await?;
    backend.remove(&base_id, true).await?;
    Ok(())
}
