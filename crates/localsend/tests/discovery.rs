use std::sync::Arc;
use std::time::Duration;

use sfiles_localsend::{DeviceType, LocalSendConfig, LocalSendService};
use vfs_core::Vfs;

async fn service(tag: &str) -> (LocalSendService, tempfile::TempDir) {
    let root = tempfile::tempdir().unwrap();
    let store = tempfile::tempdir().unwrap();
    let vfs = Arc::new(Vfs::with_local_root(root.path()).unwrap());
    let service = LocalSendService::start(
        vfs,
        LocalSendConfig {
            alias: tag.into(),
            device_model: "test".into(),
            device_type: DeviceType::Desktop,
            port: 0,
            store_dir: store.path().to_path_buf(),
            dest_dir: root.path().to_string_lossy().into_owned(),
            pin: None,
            enable_discovery: true,
            idle_timeout_secs: 0,
        },
    )
    .await
    .unwrap();
    // Keep the root alive for the duration of the test.
    (service, root)
}

#[tokio::test]
async fn multicast_discovers_both_services() {
    let (a, _root_a) = service("alpha").await;
    let (b, _root_b) = service("beta").await;

    // Announcements fire immediately and every 5s; allow one exchange.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
    loop {
        let a_peers = a.peers().await;
        let b_peers = b.peers().await;
        if !a_peers.is_empty() && !b_peers.is_empty() {
            assert!(a_peers.iter().any(|p| p.alias == "beta"));
            assert!(b_peers.iter().any(|p| p.alias == "alpha"));
            break;
        }
        if tokio::time::Instant::now() >= deadline {
            panic!(
                "discovery timeout: a={:?} b={:?}",
                a_peers.iter().map(|p| &p.alias).collect::<Vec<_>>(),
                b_peers.iter().map(|p| &p.alias).collect::<Vec<_>>()
            );
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }

    a.stop().await;
    b.stop().await;
}
