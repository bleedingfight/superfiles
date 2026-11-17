//! Live engine->SMB upload matrix (skipped unless a share is configured).
//!
//! ```bash
//! SF_TEST_SMB_HOST=127.0.0.1:4456 SF_TEST_SMB_SHARE=test \
//! SF_TEST_SMB_USER=sfuser SF_TEST_SMB_PASS=sfpass123 \
//!   cargo test -p sfiles-engine --test copy_to_smb_live -- --nocapture
//! ```
//!
//! Regression guard for the "copied to Samba but the file won't open"
//! report: every size boundary (0 / chunk / chunk+1 / multi-chunk tail)
//! must land byte-identical, and the final size must equal the source size.

use std::sync::Arc;

use sfiles_engine::{run, ConflictPolicy, CopyOptions, TransferHandle, TransferState};
use vfs_core::backends::{SmbAuth, SmbBackend};
use vfs_core::{CancelToken, Vfs};

fn config() -> Option<(String, String, SmbAuth, Option<u16>)> {
    let host_port = std::env::var("SF_TEST_SMB_HOST").ok()?;
    let share = std::env::var("SF_TEST_SMB_SHARE").ok()?;
    let (host, port) = match host_port.rsplit_once(':') {
        Some((h, p)) => (h.to_string(), p.parse::<u16>().ok()),
        None => (host_port, None),
    };
    let auth = match (
        std::env::var("SF_TEST_SMB_USER").ok(),
        std::env::var("SF_TEST_SMB_PASS").ok(),
    ) {
        (Some(u), Some(p)) => SmbAuth::new(u, p),
        _ => SmbAuth::guest(),
    };
    Some((host, share, auth, port))
}

/// Deterministic, non-repeating-enough payload (xorshift).
fn payload(len: usize, seed: u64) -> Vec<u8> {
    let mut x = seed | 1;
    let mut out = Vec::with_capacity(len);
    for _ in 0..len {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        out.push((x >> 24) as u8);
    }
    out
}

#[tokio::test]
async fn engine_copy_to_smb_is_byte_identical() {
    let Some((host, share, auth, port)) = config() else {
        eprintln!("SF_TEST_SMB_HOST/SHARE not set; skipping engine->SMB live run");
        return;
    };

    let local = tempfile::tempdir().unwrap();
    let vfs = Arc::new(Vfs::with_local_root(local.path()).unwrap());
    let local_root = vfs.local_root().to_string();

    let smb = SmbBackend::connect(&host, &share, port, auth)
        .await
        .unwrap();
    let smb_root = smb.root_id();
    vfs.mount(Arc::new(smb));

    let tag = format!(
        "sfiles-engine-it-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis()
    );
    let dest = Vfs::join(&smb_root, &tag);
    vfs.create_dir(&smb_root, &tag).await.unwrap();

    const MIB: usize = 1024 * 1024;
    let cases = [
        ("empty.bin", 0usize),
        ("one.bin", 1),
        ("exact.bin", MIB),
        ("plus-one.bin", MIB + 1),
        ("tail.bin", 3 * MIB + 12345),
        ("multi.bin", 11 * MIB + 7),
    ];

    for (idx, (name, size)) in cases.iter().enumerate() {
        let data = payload(*size, idx as u64 + 1);
        let src = Vfs::join(&local_root, name);
        vfs.write_range(&src, 0, &data).await.unwrap();

        let handle = Arc::new(TransferHandle::new(
            format!("live-{idx}"),
            CancelToken::new(),
        ));
        run(
            vfs.clone(),
            vec![src],
            dest.clone(),
            CopyOptions {
                conflict: ConflictPolicy::Overwrite,
                ..Default::default()
            },
            handle.clone(),
        )
        .await;

        let snap = handle.snapshot();
        assert_eq!(
            snap.state,
            TransferState::Completed,
            "{name}: transfer did not complete: {snap:?}"
        );

        let dst = Vfs::join(&dest, name);
        let stat = vfs.stat(&dst).await.unwrap();
        assert_eq!(stat.size, *size as u64, "{name}: wrong size on SMB");

        // Read the whole file back and compare — a size-only check would
        // miss a misplaced prefetched block (correct length, wrong bytes).
        let mut offset = 0usize;
        while offset < data.len() {
            let want = (data.len() - offset).min(MIB);
            let got = vfs.read_range(&dst, offset as u64, want).await.unwrap();
            assert_eq!(
                got.len(),
                want,
                "{name}: short read at offset {offset}/{size}"
            );
            assert_eq!(
                &got[..],
                &data[offset..offset + want],
                "{name}: byte mismatch at offset {offset}"
            );
            offset += want;
        }
        eprintln!("-- {name} ({size} bytes): PASS");
    }

    // Cleanup is best-effort: a failed assert must not mask the real error.
    let _ = vfs.remove(&dest, true).await;
    eprintln!("== engine->SMB matrix PASS");
}

/// Same share on both sides: writes to the destination invalidate the SMB
/// read cache that holds the *source* handle, so this exercises the
/// read-cache/transfer interaction (ADR-relevant for "share a file that
/// lives on the NAS").
#[tokio::test]
async fn engine_copy_within_smb_is_byte_identical() {
    let Some((host, share, auth, port)) = config() else {
        eprintln!("SF_TEST_SMB_HOST/SHARE not set; skipping SMB->SMB live run");
        return;
    };

    let vfs = Arc::new(Vfs::new());
    let smb = SmbBackend::connect(&host, &share, port, auth)
        .await
        .unwrap();
    let root = smb.root_id();
    vfs.mount(Arc::new(smb));

    let tag = format!(
        "sfiles-engine-smb-smb-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis()
    );
    let base = vfs.create_dir(&root, &tag).await.unwrap();
    let src_dir = vfs.create_dir(&base.id, "src").await.unwrap();
    let dst_dir = vfs.create_dir(&base.id, "dst").await.unwrap();

    const MIB: usize = 1024 * 1024;
    let data = payload(7 * MIB + 4321, 4242);
    let src = Vfs::join(&src_dir.id, "movie.bin");
    vfs.write_range(&src, 0, &data).await.unwrap();

    let handle = Arc::new(TransferHandle::new("smb-smb", CancelToken::new()));
    run(
        vfs.clone(),
        vec![src],
        dst_dir.id.clone(),
        CopyOptions {
            conflict: ConflictPolicy::Overwrite,
            ..Default::default()
        },
        handle.clone(),
    )
    .await;
    assert_eq!(
        handle.snapshot().state,
        TransferState::Completed,
        "SMB->SMB transfer failed: {:?}",
        handle.snapshot()
    );

    let dst = Vfs::join(&dst_dir.id, "movie.bin");
    assert_eq!(vfs.stat(&dst).await.unwrap().size, data.len() as u64);
    let mut offset = 0usize;
    while offset < data.len() {
        let want = (data.len() - offset).min(MIB);
        let got = vfs.read_range(&dst, offset as u64, want).await.unwrap();
        assert_eq!(&got[..], &data[offset..offset + want], "mismatch @{offset}");
        offset += want;
    }

    let _ = vfs.remove(&base.id, true).await;
    eprintln!("== SMB->SMB matrix PASS");
}

/// The system-share intake path writes 256 KiB chunks into an already
/// created file (no engine, no final truncate). Guard that it lands intact.
#[tokio::test]
async fn streaming_chunks_into_smb_file_is_byte_identical() {
    let Some((host, share, auth, port)) = config() else {
        eprintln!("SF_TEST_SMB_HOST/SHARE not set; skipping SMB chunked-write run");
        return;
    };

    let vfs = Arc::new(Vfs::new());
    let smb = SmbBackend::connect(&host, &share, port, auth)
        .await
        .unwrap();
    let root = smb.root_id();
    vfs.mount(Arc::new(smb));

    let tag = format!(
        "sfiles-engine-chunk-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis()
    );
    let base = vfs.create_dir(&root, &tag).await.unwrap();

    let data = payload(5 * 1024 * 1024 + 777, 99);
    let file = vfs.create_file(&base.id, "intake.bin").await.unwrap();
    let mut offset = 0usize;
    while offset < data.len() {
        let n = (data.len() - offset).min(256 * 1024);
        vfs.write_range(&file.id, offset as u64, &data[offset..offset + n])
            .await
            .unwrap();
        offset += n;
    }
    assert_eq!(
        vfs.stat(&file.id).await.unwrap().size,
        data.len() as u64,
        "chunked writes must extend the file to the exact size"
    );
    let got = vfs.read_range(&file.id, 0, data.len()).await.unwrap();
    assert_eq!(got, data);

    let _ = vfs.remove(&base.id, true).await;
    eprintln!("== SMB chunked-write matrix PASS");
}
