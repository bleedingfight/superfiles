//! Local smoke test against `rclone serve s3` (S3-compatible).
//!
//!   rclone serve s3 --addr 127.0.0.1:9100 --auth-key testkey,testsecret /tmp/opencode/s3data
//!   cargo run -p vfs-core --example s3_smoke

use vfs_core::backends::S3Backend;
use vfs_core::Backend;

#[tokio::main]
async fn main() {
    let backend = S3Backend::new(
        std::env::var("S3_ENDPOINT").unwrap_or_else(|_| "http://127.0.0.1:9100".into()),
        "us-east-1".into(),
        "testbucket".into(),
        "testkey".into(),
        "testsecret".into(),
        None,
        true,
    );

    println!(
        "list root: {:?}",
        backend.list("s3://").await.map(|v| v.len())
    );
    println!(
        "mkdir: {:?}",
        backend.create_dir("s3://", "demo").await.map(|e| e.name)
    );

    let data = b"hello s3";
    backend
        .write_range("s3://demo/hello.txt", 0, data)
        .await
        .expect("spool write");
    backend
        .truncate("s3://demo/hello.txt", data.len() as u64)
        .await
        .expect("upload");

    println!(
        "list demo: {:?}",
        backend
            .list("s3://demo")
            .await
            .map(|v| v.into_iter().map(|e| (e.name, e.size)).collect::<Vec<_>>())
    );

    let bytes = backend
        .read_range("s3://demo/hello.txt", 0, 100)
        .await
        .expect("download");
    println!("read: {:?}", String::from_utf8_lossy(&bytes));

    println!(
        "rename: {:?}",
        backend
            .rename("s3://demo/hello.txt", "hi.txt")
            .await
            .map(|e| e.name)
    );
    println!("remove: {:?}", backend.remove("s3://demo", true).await);
    println!(
        "final list: {:?}",
        backend.list("s3://").await.map(|v| v.len())
    );
}
