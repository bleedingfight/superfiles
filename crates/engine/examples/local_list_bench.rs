//! Measures where `list()` time goes for a local directory: readdir+stat vs
//! the index writes the FFI does on every listing (upsert + prune + timestamp).
//!
//! `cargo run -q -p sfiles-engine --release --example local_list_bench -- 5000`

use std::time::Instant;

use sfiles_index::Index;
use vfs_core::{Backend, Vfs};

#[tokio::main]
async fn main() {
    let n: usize = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(5000);
    let dir = tempfile::tempdir().expect("dir");
    for i in 0..n {
        std::fs::write(
            dir.path().join(format!("测试文件_{i:05}_山屿品牌.jpg")),
            b"x",
        )
        .expect("write");
    }
    let vfs = Vfs::with_local_root(dir.path()).expect("vfs");
    let root = vfs.local_root().to_string();

    let t = Instant::now();
    let entries = vfs.list(&root).await.expect("list");
    println!("vfs.list           {n:>6} entries  {:>8.2} ms", t.elapsed().as_secs_f64() * 1e3);

    let dbdir = tempfile::tempdir().expect("db");
    let index = Index::open(dbdir.path().join("bench.sqlite")).expect("index");
    let keep: Vec<String> = entries.iter().map(|e| e.id.clone()).collect();

    for pass in 0..2 {
        let t = Instant::now();
        index.upsert_all(&entries).expect("upsert");
        let upsert = t.elapsed().as_secs_f64() * 1e3;
        let t = Instant::now();
        index.prune_children(&root, &keep).expect("prune");
        let prune = t.elapsed().as_secs_f64() * 1e3;
        let t = Instant::now();
        index.record_listing(&root, 1).expect("record");
        let record = t.elapsed().as_secs_f64() * 1e3;
        println!(
            "index pass {pass}      upsert {upsert:>7.2} + prune {prune:>6.2} + record {record:>6.2} = {:>7.2} ms",
            upsert + prune + record
        );
    }
}
