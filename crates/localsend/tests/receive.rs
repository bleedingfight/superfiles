use std::sync::Arc;

use sfiles_localsend::{
    DeviceInfo, DeviceType, DiscoveredPeer, Identity, LocalSendClient, LocalSendConfig,
    LocalSendService,
};
use vfs_core::Vfs;

fn client_info() -> DeviceInfo {
    DeviceInfo {
        alias: "sender".into(),
        version: "2.2".into(),
        device_model: Some("test".into()),
        device_type: Some("desktop".into()),
        fingerprint: "0".repeat(64),
        port: 0,
        protocol: "https".into(),
        download: false,
        announce: None,
    }
}

#[tokio::test]
async fn receives_files_over_pinned_tls() {
    let root = tempfile::tempdir().unwrap();
    let store = tempfile::tempdir().unwrap();
    let sender_store = tempfile::tempdir().unwrap();
    let sender = Identity::load_or_create(sender_store.path(), "sender").unwrap();
    let vfs = Arc::new(Vfs::with_local_root(root.path()).unwrap());

    let service = LocalSendService::start(
        vfs.clone(),
        LocalSendConfig {
            alias: "receiver".into(),
            device_model: "pixel".into(),
            device_type: DeviceType::Mobile,
            port: 0,
            store_dir: store.path().to_path_buf(),
            dest_dir: vfs.local_root().to_string(),
            pin: None,
            enable_discovery: false,
            idle_timeout_secs: 0,
        },
    )
    .await
    .unwrap();

    let info = service.info();
    let peer = DiscoveredPeer {
        alias: "receiver".into(),
        ip: "127.0.0.1".parse().unwrap(),
        port: service.port(),
        fingerprint: info.fingerprint.clone(),
        device_type: "mobile".into(),
        last_seen_ms: 0,
    };

    // Register handshake (self-signed cert accepted only because it is pinned).
    let registered = LocalSendClient::register(
        peer.ip,
        peer.port,
        &client_info(),
        &sender,
        peer.fingerprint_bytes(),
    )
    .await
    .unwrap();
    assert_eq!(registered.alias, "receiver");

    // Wrong pin must be rejected.
    let wrong = DiscoveredPeer {
        fingerprint: "f".repeat(64),
        ..peer.clone()
    };
    assert!(LocalSendClient::register(
        wrong.ip,
        wrong.port,
        &client_info(),
        &sender,
        wrong.fingerprint_bytes(),
    )
    .await
    .is_err());

    // Source file lives in a sibling directory so the received name is clean.
    let src = vfs.create_dir(vfs.local_root(), "src").await.unwrap();
    let file = vfs.create_file(&src.id, "hello.txt").await.unwrap();
    vfs.write_range(&file.id, 0, b"hello localsend")
        .await
        .unwrap();

    LocalSendClient::send(&vfs, &client_info(), &sender, &peer, vec![file.id.clone()])
        .await
        .unwrap();

    let received = vfs
        .stat(&Vfs::join(vfs.local_root(), "hello.txt"))
        .await
        .unwrap();
    let bytes = vfs.read_range(&received.id, 0, 64).await.unwrap();
    assert_eq!(&bytes, b"hello localsend");

    service.stop().await;
}
