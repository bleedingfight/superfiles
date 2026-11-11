//! On-device zip archiving with (done, total) source-byte progress.
//!
//! Layout: a blocking-pool producer thread runs the `zip` crate (its writer
//! API is synchronous) and streams archive bytes through a bounded channel to
//! an async writer task, so the pool's backpressure keeps memory flat no
//! matter how large the archive grows. Source bytes are read through the vfs
//! in [`CHUNK`] pieces driven by `Handle::block_on` — legal because the
//! producer runs on the blocking pool, not an async worker.

use std::io::{self, Write};
use std::sync::Arc;

use tokio::runtime::Handle;
use vfs_core::{Entry, Vfs, VfsError};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

/// Source read + archive write granularity.
pub const CHUNK: usize = 256 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZipMethod {
    /// 仅打包不压缩（最快，原样体积）。
    Store,
    /// Deflate 压缩（默认）。
    Deflate,
}

impl From<ZipMethod> for CompressionMethod {
    fn from(method: ZipMethod) -> Self {
        match method {
            ZipMethod::Store => CompressionMethod::Stored,
            ZipMethod::Deflate => CompressionMethod::Deflated,
        }
    }
}

/// Zip `sources` (files or directories, walked recursively) into
/// `dest_dir/name` (a `.zip` suffix is appended when missing; an existing
/// file is auto-renamed away with a `-N` suffix before creation).
///
/// `progress(done, total)` fires after every read chunk and once more with
/// `(total, total)` on success. Returns the created archive entry.
pub async fn compress_zip(
    vfs: Arc<Vfs>,
    sources: Vec<String>,
    dest_dir: String,
    name: String,
    method: ZipMethod,
    handle: Handle,
    progress: impl Fn(u64, u64) + Send + Sync + 'static,
) -> Result<Entry, VfsError> {
    let files = collect_files(&vfs, &sources).await?;
    if files.is_empty() {
        return Err(VfsError::Unsupported("nothing compressible".into()));
    }
    let total: u64 = files.iter().map(|f| f.entry.size).sum();
    // 全部源为 0 字节也照常产出合法的空 zip。
    let dest = create_unique(&vfs, &dest_dir, &with_zip_ext(&name)).await?;

    let (tx, mut rx) = tokio::sync::mpsc::channel::<Vec<u8>>(8);
    let write_vfs = vfs.clone();
    let write_id = dest.id.clone();
    let writer = tokio::spawn(async move {
        let mut offset = 0u64;
        while let Some(chunk) = rx.recv().await {
            write_vfs.write_range(&write_id, offset, &chunk).await?;
            offset += chunk.len() as u64;
        }
        Ok::<u64, VfsError>(offset)
    });

    let read_vfs = vfs.clone();
    let progress = Arc::new(progress);
    let progress_in = progress.clone();
    let producer = tokio::task::spawn_blocking(move || -> Result<(), VfsError> {
        struct ChannelSink {
            tx: tokio::sync::mpsc::Sender<Vec<u8>>,
        }
        impl Write for ChannelSink {
            fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
                self.tx
                    .blocking_send(buf.to_vec())
                    .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "zip writer gone"))?;
                Ok(buf.len())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }

        let mut zip = ZipWriter::new_stream(ChannelSink { tx });
        let options = SimpleFileOptions::default().compression_method(method.into());
        for file in &files {
            zip.start_file(file.archive_name.clone(), options)
                .map_err(|e| VfsError::Unsupported(format!("zip start: {e}")))?;
            let mut offset = 0u64;
            while offset < file.entry.size {
                let chunk = handle.block_on(read_vfs.read_range(&file.entry.id, offset, CHUNK))?;
                if chunk.is_empty() {
                    break;
                }
                zip.write_all(&chunk)
                    .map_err(|e| VfsError::Unsupported(format!("zip write: {e}")))?;
                offset += chunk.len() as u64;
                progress_in(offset_total(&files, file.index, offset), total);
            }
        }
        let sink = zip
            .finish()
            .map_err(|e| VfsError::Unsupported(format!("zip finish: {e}")))?;
        drop(sink); // close the channel so the writer drains and exits
        Ok(())
    });

    let (produced, written) = tokio::join!(producer, writer);
    produced
        .map_err(|e| VfsError::Unsupported(format!("zip task join: {e}")))
        .and_then(|r| r)?;
    written.map_err(|e| VfsError::Unsupported(format!("vfs writer join: {e}")))??;
    progress(total, total);
    vfs.stat(&dest.id).await
}

struct PlanItem {
    index: usize,
    entry: Entry,
    archive_name: String,
}

/// Bytes already consumed from earlier files + `offset` of the current one.
fn offset_total(files: &[PlanItem], index: usize, offset: u64) -> u64 {
    files[..index].iter().map(|f| f.entry.size).sum::<u64>() + offset
}

async fn collect_files(vfs: &Vfs, sources: &[String]) -> Result<Vec<PlanItem>, VfsError> {
    let mut out = Vec::new();
    for source in sources {
        let entry = vfs.stat(source).await?;
        if entry.is_dir() {
            walk(vfs, &entry.id, &entry.name, &mut out).await?;
        } else {
            out.push(PlanItem {
                index: out.len(),
                archive_name: entry.name.clone(),
                entry,
            });
        }
    }
    Ok(out)
}

async fn walk(vfs: &Vfs, id: &str, prefix: &str, out: &mut Vec<PlanItem>) -> Result<(), VfsError> {
    for child in vfs.list(id).await? {
        let path = format!("{prefix}/{}", child.name);
        if child.is_dir() {
            Box::pin(walk(vfs, &child.id, &path, out)).await?;
        } else {
            out.push(PlanItem {
                index: out.len(),
                archive_name: path,
                entry: child,
            });
        }
    }
    Ok(())
}

fn with_zip_ext(name: &str) -> String {
    if name.to_ascii_lowercase().ends_with(".zip") {
        name.to_string()
    } else {
        format!("{name}.zip")
    }
}

async fn create_unique(vfs: &Vfs, dir: &str, name: &str) -> Result<Entry, VfsError> {
    match vfs.create_file(dir, name).await {
        Ok(entry) => Ok(entry),
        Err(VfsError::AlreadyExists(_)) => {
            let (stem, ext) = name
                .rfind('.')
                .map_or((name, ""), |dot| (&name[..dot], &name[dot..]));
            for n in 1..100 {
                let candidate = format!("{stem}-{n}{ext}");
                match vfs.create_file(dir, &candidate).await {
                    Ok(entry) => return Ok(entry),
                    Err(VfsError::AlreadyExists(_)) => continue,
                    Err(err) => return Err(err),
                }
            }
            Err(VfsError::AlreadyExists(name.to_string()))
        }
        Err(err) => Err(err),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;

    #[tokio::test]
    async fn zips_a_tree_with_progress() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("storage");
        fs::create_dir_all(root.join("docs")).unwrap();
        fs::write(root.join("docs/a.txt"), b"hello world".repeat(4096)).unwrap();
        fs::write(root.join("b.txt"), b"b".repeat(10)).unwrap();

        let vfs = Arc::new(Vfs::with_local_root(&root).unwrap());
        let root_id = vfs.local_root().to_string();
        let last = Arc::new(AtomicU64::new(0));
        let last2 = last.clone();

        let entry = compress_zip(
            vfs.clone(),
            vec![root_id.clone()],
            root_id.clone(),
            "打包".into(),
            ZipMethod::Deflate,
            Handle::current(),
            move |done, _total| last2.store(done, Ordering::SeqCst),
        )
        .await
        .unwrap();

        assert_eq!(entry.name, "打包.zip");
        // 进度收尾必为精确总字节数（11B × 4096 + 10B）
        assert_eq!(last.load(Ordering::SeqCst), 11 * 4096 + 10);

        let archive = fs::read(root.join("打包.zip")).unwrap();
        let mut zr = zip::ZipArchive::new(io::Cursor::new(archive)).unwrap();
        let names: Vec<String> = (0..zr.len())
            .map(|i| zr.by_index(i).unwrap().name().unwrap().to_string())
            .collect();
        // 整树根目录入包时条目带根目录前缀（如 storage/b.txt）
        let by_suffix = |suffix: &str| {
            names
                .iter()
                .any(|n| n == suffix || n.ends_with(&format!("/{suffix}")))
        };
        assert!(by_suffix("b.txt"), "entries: {names:?}");
        assert!(by_suffix("docs/a.txt"), "entries: {names:?}");

        // 内容还原校验
        let a_name = names
            .iter()
            .find(|n| n.ends_with("docs/a.txt"))
            .unwrap()
            .clone();
        let mut text = String::new();
        io::Read::read_to_string(&mut zr.by_name(&a_name).unwrap(), &mut text).unwrap();
        assert_eq!(text, "hello world".repeat(4096));

        // 再压一次同名单文件 → 自动改名 -1
        let again = compress_zip(
            vfs,
            vec![Vfs::join(&root_id, "b.txt")],
            root_id,
            "打包".into(),
            ZipMethod::Store,
            Handle::current(),
            move |_, _| {},
        )
        .await
        .unwrap();
        assert_eq!(again.name, "打包-1.zip");
    }
}
