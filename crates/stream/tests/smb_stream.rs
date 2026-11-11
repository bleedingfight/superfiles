// Cross-feature integration: SMB backend served over the loopback HTTP streamer.
// Exercises the exact code path a video player would use against a NAS share.
use std::sync::Arc;
use vfs_core::backends::{SmbAuth, SmbBackend};
use vfs_core::{Backend, Vfs};

#[tokio::test]
async fn stream_smb_file_over_loopback() {
    let Ok(host) = std::env::var("SF_TEST_SMB_HOST") else {
        return;
    };
    let share = std::env::var("SF_TEST_SMB_SHARE").unwrap();
    let user = std::env::var("SF_TEST_SMB_USER").unwrap();
    let pass = std::env::var("SF_TEST_SMB_PASS").unwrap();

    let backend = SmbBackend::connect(&host, &share, None, SmbAuth::new(user, pass))
        .await
        .unwrap();
    let root = backend.root_id();
    let payload: Vec<u8> = (0..1_000_000u32).map(|i| (i % 251) as u8).collect();
    backend.create_file(&root, "stream-probe.mkv").await.ok();
    backend
        .write_range(&format!("{root}/stream-probe.mkv"), 0, &payload)
        .await
        .unwrap();

    let vfs = Arc::new(Vfs::new());
    vfs.mount(Arc::new(backend));
    let server = sfiles_stream::StreamServer::start(vfs.clone())
        .await
        .unwrap();
    let url = server.url_for(&format!("{root}/stream-probe.mkv"));

    let client = reqwest::Client::new();
    let resp = client
        .get(&url)
        .header("Range", "bytes=500000-500499")
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 206);
    assert_eq!(
        resp.headers()["content-range"],
        "bytes 500000-500499/1000000"
    );
    let body = resp.bytes().await.unwrap();
    assert_eq!(&body[..], &payload[500000..500500]);

    server.shutdown().await;
    vfs.remove(&format!("{root}/stream-probe.mkv"), false)
        .await
        .unwrap();
}
