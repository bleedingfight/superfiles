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

#[test]
fn nearby_share_lifecycle() {
    let root = temp_dir("share");
    let core = SuperFiles::open(root.to_string_lossy().into_owned(), None).unwrap();
    let file = core
        .create_file(core.root_id(), "photo.jpg".into())
        .unwrap();
    core.write_bytes(file.id.clone(), 0, vec![1u8; 1024])
        .unwrap();

    // 目录不可分享（提示先压缩）；空列表报错。
    assert!(matches!(
        core.start_share(vec![]).unwrap_err(),
        superfiles::SfError::InvalidName { .. }
    ));
    assert!(matches!(
        core.start_share(vec![core.root_id()]).unwrap_err(),
        superfiles::SfError::Unsupported { .. }
    ));

    // 正常启动 → 链接是局域网 http + token 路径；再次启动替换且可显式关闭。
    let info = core.start_share(vec![file.id]).unwrap();
    assert_eq!(info.file_count, 1);
    assert!(
        info.url.starts_with("http://") && info.url.ends_with('/'),
        "url={}",
        info.url
    );
    let info2 = core.start_share(vec![]).err(); // 替换前先报错：空列表不动旧会话
    assert!(info2.is_some());
    assert!(core.stop_share());
    assert!(!core.stop_share()); // 幂等

    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn list_writes_through_to_the_offline_cache() {
    let root = temp_dir("offline-cache");
    let db_dir = temp_dir("offline-cache-db");
    let db = db_dir.join("index.sqlite");
    let core = SuperFiles::open(
        root.to_string_lossy().into_owned(),
        Some(db.to_string_lossy().into_owned()),
    )
    .unwrap();
    let root_id = core.root_id();

    // 无缓存时：空列表 + 无时间戳。
    let cold = core.list_cached(root_id.clone());
    assert!(cold.entries.is_empty());
    assert!(cold.listed_at_ms.is_none());

    let docs = core.create_dir(root_id.clone(), "Docs".into()).unwrap();
    core.create_file(docs.id.clone(), "a.txt".into()).unwrap();
    core.create_file(docs.id.clone(), "b.txt".into()).unwrap();
    let live = core.list(docs.id.clone()).unwrap();
    assert_eq!(live.len(), 2);

    // list() 成功即写入缓存：子项 + 更新时间。
    let cached = core.list_cached(docs.id.clone());
    assert_eq!(cached.entries.len(), 2);
    assert!(cached.listed_at_ms.is_some());

    // 删除与索引联动：删除返回时索引行已经没了，缓存里也立刻消失
    // （不再需要等下一次实时列举做对账）。
    core.remove(docs.id.clone() + "/a.txt", false).unwrap();
    assert_eq!(core.list_cached(docs.id.clone()).entries.len(), 1);
    core.list(docs.id.clone()).unwrap();
    assert_eq!(core.list_cached(docs.id.clone()).entries.len(), 1);

    // 无索引的内核：list_cached 安全返回空（离线浏览不可用）。
    let no_index =
        SuperFiles::open(temp_dir("no-index").to_string_lossy().into_owned(), None).unwrap();
    assert!(no_index.list_cached(no_index.root_id()).entries.is_empty());

    std::fs::remove_dir_all(&root).ok();
    std::fs::remove_dir_all(&db_dir).ok();
}

#[test]
fn mounts_and_stream_url_flow() {
    let root = temp_dir("mounts");
    let core = SuperFiles::open(root.to_string_lossy().into_owned(), None).unwrap();

    // Two webdav mounts coexist under one scheme (prefix dispatch).
    core.mount_webdav(
        "NAS 书房".into(),
        "https://nas.local:5006/dav".into(),
        "alice".into(),
        "s3cret".into(),
    )
    .unwrap();
    core.mount_webdav(
        "NAS 客厅".into(),
        "https://192.168.1.10:5007/dav".into(),
        String::new(),
        String::new(),
    )
    .unwrap();
    let mounts = core.mounts();
    assert_eq!(mounts.len(), 2);
    assert!(mounts.iter().any(|m| m.label == "NAS 书房"));
    assert!(mounts.iter().all(|m| m.scheme == "webdav"));
    let root_a = mounts
        .iter()
        .find(|m| m.label == "NAS 书房")
        .unwrap()
        .root_id
        .clone();

    // Duplicate mount of the same root replaces silently.
    core.mount_webdav(
        "NAS 书房-2".into(),
        "https://nas.local:5006/dav".into(),
        String::new(),
        String::new(),
    )
    .unwrap();
    assert_eq!(core.mounts().len(), 2);

    assert!(core.unmount(root_a));
    assert_eq!(core.mounts().len(), 1);
    assert!(!core.unmount("webdav://ghost.local/".into()));

    // Stream URL: lazily-started loopback server serves any can_seek entry.
    let file = core.create_file(core.root_id(), "clip.mp4".into()).unwrap();
    core.write_bytes(file.id.clone(), 0, vec![7u8; 4096])
        .unwrap();
    let url = core.stream_url(file.id.clone()).unwrap();
    assert!(url.starts_with("http://127.0.0.1:"));

    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn resume_flow_through_the_ffi() {
    let root = temp_dir("resume");
    let db_dir = temp_dir("resume-db");
    let db = db_dir.join("index.sqlite");
    let core = SuperFiles::open(
        root.to_string_lossy().into_owned(),
        Some(db.to_string_lossy().into_owned()),
    )
    .unwrap();

    // Source: 768 KiB + 13 B of patterned data so a misaligned resume sticks
    // out. Destination dir holds the partial copy the "crashed" run left.
    let size = 768 * 1024 + 13;
    let data: Vec<u8> = (0..size).map(|i| (i % 251) as u8).collect();
    let src_dir = core.create_dir(core.root_id(), "src".into()).unwrap();
    let dst_dir = core.create_dir(core.root_id(), "dst".into()).unwrap();
    let source = core
        .create_file(src_dir.id.clone(), "big.bin".into())
        .unwrap();
    core.write_bytes(source.id.clone(), 0, data.clone())
        .unwrap();

    let checkpoint = 300 * 1024u64;
    let partial = core
        .create_file(dst_dir.id.clone(), "big.bin".into())
        .unwrap();
    core.write_bytes(partial.id.clone(), 0, data[..checkpoint as usize].to_vec())
        .unwrap();

    // Simulate the crashed previous run: a `running` row with a per-file
    // offset checkpoint, written through a second Index on the same db.
    let index = sfiles_index::Index::open(&db).unwrap();
    let mut stored = sfiles_index::StoredTransfer::new_running(
        "t-crashed",
        vec![source.id.clone()],
        dst_dir.id.clone(),
        1,
        data.len() as u64,
    );
    stored.bytes_done = checkpoint;
    stored.file_offsets = vec![sfiles_index::FileOffset {
        source_id: source.id.clone(),
        size: data.len() as u64,
        offset: checkpoint,
    }];
    index.save_transfer(&stored).unwrap();

    // The restart: the row surfaces as a pending transfer.
    let pending = core.pending_transfers().unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].id, "t-crashed");
    assert_eq!(pending[0].bytes_done, checkpoint);
    assert_eq!(pending[0].bytes_total, data.len() as u64);
    assert_eq!(pending[0].dest_dir, dst_dir.id);

    core.resume_transfer("t-crashed".into()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let snapshot = core.transfer_snapshot("t-crashed".into()).unwrap();
        if snapshot.state != superfiles::TransferState::Queued
            && snapshot.state != superfiles::TransferState::Running
        {
            assert_eq!(snapshot.state, superfiles::TransferState::Completed);
            // Progress continued from the checkpoint instead of restarting.
            assert_eq!(snapshot.bytes_total, data.len() as u64);
            assert_eq!(snapshot.bytes_done, data.len() as u64);
            assert_eq!(snapshot.files_done, 1);
            break;
        }
        assert!(Instant::now() < deadline, "resume timed out: {snapshot:?}");
        std::thread::sleep(Duration::from_millis(10));
    }

    // Byte-exact destination: prefix kept, remainder appended.
    let copied = core
        .read_bytes(partial.id.clone(), 0, data.len() as u32)
        .unwrap();
    assert_eq!(copied, data);

    // Completed rows are not pending anymore; the id is still tracked as a
    // finished live transfer, and forgetting clears both sides.
    assert!(core.pending_transfers().unwrap().is_empty());
    assert!(matches!(
        core.resume_transfer("t-crashed".into()).unwrap_err(),
        superfiles::SfError::NotFound { .. }
    ));
    assert!(matches!(
        core.resume_transfer("ghost".into()).unwrap_err(),
        superfiles::SfError::NotFound { .. }
    ));
    core.forget_transfer("t-crashed".into());
    core.forget_transfer("t-crashed".into()); // idempotent
    assert!(core.transfer_snapshot("t-crashed".into()).is_none());

    // A fresh copy through start_copy is journaled too: it must not show up
    // as pending while it runs, and not after it completes.
    let fresh = core
        .start_copy(
            vec![source.id.clone()],
            dst_dir.id.clone(),
            superfiles::ConflictPolicy::Overwrite,
        )
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let snapshot = core.transfer_snapshot(fresh.clone()).unwrap();
        assert!(core.pending_transfers().unwrap().is_empty());
        if snapshot.state == superfiles::TransferState::Completed {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "journaled copy timed out: {snapshot:?}"
        );
        std::thread::sleep(Duration::from_millis(10));
    }

    std::fs::remove_dir_all(&root).ok();
    std::fs::remove_dir_all(&db_dir).ok();
}

/// 文件系统写操作与索引必须联动：删掉文件后立刻搜不到，改名后旧名字立刻消失。
#[test]
fn mutations_update_the_index_immediately() {
    let root = temp_dir("mutate");
    let db_dir = temp_dir("mutate-db");
    let db = db_dir.join("index.sqlite");
    let core: Arc<SuperFiles> = SuperFiles::open(
        root.to_string_lossy().into_owned(),
        Some(db.to_string_lossy().into_owned()),
    )
    .unwrap();
    let root_id = core.root_id();

    // 建文件即入索引（不需要再跑一次 index_dir）
    let file = core
        .create_file(root_id.clone(), "hello.jpg".into())
        .unwrap();
    assert!(
        core.search("hello".into(), 10)
            .unwrap()
            .iter()
            .any(|e| e.id == file.id),
        "newly created file should be searchable immediately"
    );
    assert!(core.index_prefix_count(root_id.clone()) >= 1);

    // 改名：旧名字立刻搜不到，新名字立刻能搜到
    let renamed = core.rename(file.id.clone(), "world.jpg".into()).unwrap();
    assert!(
        core.search("hello".into(), 10).unwrap().is_empty(),
        "old name must disappear right after rename"
    );
    assert!(!core.search("world".into(), 10).unwrap().is_empty());

    // 删除：返回前索引行就没了
    core.remove(renamed.id.clone(), false).unwrap();
    assert!(
        core.search("world".into(), 10).unwrap().is_empty(),
        "deleted file must not be searchable"
    );
    assert_eq!(core.index_prefix_count(root_id.clone()), 0);

    std::fs::remove_dir_all(&root).ok();
    std::fs::remove_dir_all(&db_dir).ok();
}
