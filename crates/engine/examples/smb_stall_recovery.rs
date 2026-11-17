//! 一次性诊断工具：模拟「线路中途冻结」验证 SMB 传输的挂死/恢复行为。
//!
//! 用法（socat 作为可控线路）：
//!   socat TCP-LISTEN:1447,fork,reuseaddr TCP:127.0.0.1:1446 &
//!   SOC_PID=$!
//!   kill -STOP $SOC_PID                # 掐线（连接通、响应冻住）
//!   cargo run --release -p sfiles-engine --example smb_stall_recovery -- \
//!     127.0.0.1:1447 test root sf-livetest-9
//!   # ~60s 后 kill -CONT $SOC_PID（第一次 receive 超时、重试已建好新连接），
//!   # 观察传输是否续跑至 Completed —— 这就是超时→重连→续传的恢复链证明。
use std::sync::Arc;
use std::time::{Duration, Instant};

use sfiles_engine::{run, ConflictPolicy, CopyOptions, TransferHandle, TransferState};
use vfs_core::backends::{SmbAuth, SmbBackend};
use vfs_core::{CancelToken, Vfs};

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let host_port = args.next().unwrap_or_else(|| "127.0.0.1:1447".into());
    let share = args.next().unwrap_or_else(|| "test".into());
    let user = args.next().unwrap_or_else(|| "root".into());
    let pass = args.next().unwrap_or_else(|| "sf-livetest-9".into());
    let (host, port) = match host_port.rsplit_once(':') {
        Some((h, p)) => (h.to_string(), p.parse::<u16>().ok()),
        None => (host_port, None),
    };

    let local = tempfile::tempdir().unwrap();
    let vfs = Arc::new(Vfs::with_local_root(local.path()).unwrap());
    let smb = SmbBackend::connect(&host, &share, port, SmbAuth::new(user, pass))
        .await
        .expect("connect");
    let smb_root = smb.root_id();
    vfs.mount(Arc::new(smb));

    // 1 GiB 源：只看字节进度与最终状态（内容校验交给 live 矩阵负责）。
    let root = vfs.local_root().to_string();
    let src = format!("{root}/big.bin");
    const MIB: usize = 1024 * 1024;
    let data = vec![0x5au8; 1024 * MIB];
    vfs.write_range(&src, 0, &data).await.unwrap();
    drop(data);

    let dest = vfs.create_dir(&smb_root, "repro").await.unwrap();
    let handle = Arc::new(TransferHandle::new("stall-repro", CancelToken::new()));
    let started = Instant::now();

    let watcher = {
        let handle = handle.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(2)).await;
                let s = handle.snapshot();
                println!(
                    "[{:>4}s] state={:?} done={}MiB/1024MiB",
                    started.elapsed().as_secs(),
                    s.state,
                    s.bytes_done / MIB as u64
                );
                if !matches!(s.state, TransferState::Queued | TransferState::Running) {
                    break;
                }
            }
        })
    };

    run(
        vfs,
        vec![src],
        dest.id,
        CopyOptions {
            conflict: ConflictPolicy::Overwrite,
            ..Default::default()
        },
        handle.clone(),
    )
    .await;

    watcher.abort();
    let snap = handle.snapshot();
    println!(
        "== final: {:?} in {:.1}s (err={:?})",
        snap.state,
        started.elapsed().as_secs_f64(),
        snap.error
    );
    if snap.state != TransferState::Completed {
        std::process::exit(2);
    }
}
