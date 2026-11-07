use std::sync::Arc;
use std::time::{Duration, Instant};

use superfiles::SuperFiles;

fn temp_dir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "superfiles-ffi-{tag}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn browse_copy_and_search_through_the_ffi_facade() {
    let root = temp_dir("facade");
    let db_dir = temp_dir("facade-db");
    let db = db_dir.join("index.sqlite");
    let core: Arc<SuperFiles> = SuperFiles::open(
        root.to_string_lossy().into_owned(),
        Some(db.to_string_lossy().into_owned()),
    )
    .unwrap();

    let root_id = core.root_id();
    assert!(!root_id.is_empty());

    let docs = core.create_dir(root_id.clone(), "Docs".into()).unwrap();
    assert_eq!(core.list(root_id.clone()).unwrap().len(), 1);

    let file = core
        .create_file(docs.id.clone(), "notes.txt".into())
        .unwrap();
    core.write_bytes(file.id.clone(), 0, b"super files".to_vec())
        .unwrap();
    assert_eq!(core.read_bytes(file.id.clone(), 6, 5).unwrap(), b"files");

    // Copy through the async transfer engine and poll like a mobile UI would.
    let transfer = core
        .start_copy(
            vec![file.id.clone()],
            root_id.clone(),
            superfiles::ConflictPolicy::Rename,
        )
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let snapshot = core.transfer_snapshot(transfer.clone()).unwrap();
        if matches!(
            snapshot.state,
            superfiles::TransferState::Completed
                | superfiles::TransferState::Failed
                | superfiles::TransferState::Cancelled
        ) {
            assert_eq!(snapshot.state, superfiles::TransferState::Completed);
            assert_eq!(snapshot.bytes_done, 11);
            break;
        }
        assert!(
            Instant::now() < deadline,
            "transfer timed out: {snapshot:?}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }

    let indexed = core.index_dir(root_id.clone()).unwrap();
    assert!(indexed >= 2);
    let hits = core.search("notes".into(), 10).unwrap();
    assert!(!hits.is_empty());

    let caps = core.capabilities(root_id).unwrap();
    assert!(caps.can_write);

    std::fs::remove_dir_all(&root).ok();
    std::fs::remove_dir_all(&db_dir).ok();
}

#[test]
fn unsupported_scheme_is_reported() {
    let root = temp_dir("errors");
    let core = SuperFiles::open(root.to_string_lossy().into_owned(), None).unwrap();
    let err = core.list("smb://nas/share".into()).unwrap_err();
    assert!(matches!(err, superfiles::SfError::Unsupported { .. }));
    assert!(core.search("x".into(), 10).is_err());
    std::fs::remove_dir_all(&root).ok();
}
