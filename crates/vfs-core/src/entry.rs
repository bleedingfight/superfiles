use std::time::SystemTime;

/// Kind of filesystem object. Mapped 1:1 into Swift/Kotlin enums by UniFFI.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryKind {
    File,
    Directory,
    Symlink,
    Special,
}

/// A single filesystem entry.
///
/// `id` is the only thing callers pass back to the core. It is either an
/// absolute local path or a backend qualified URI such as
/// `smb://nas/share/movie.mkv`.
#[derive(Debug, Clone)]
pub struct Entry {
    pub id: String,
    pub parent: Option<String>,
    pub name: String,
    pub kind: EntryKind,
    pub size: u64,
    /// Milliseconds since Unix epoch. `None` when the backend cannot report it.
    pub modified_ms: Option<i64>,
    pub mime: Option<String>,
    pub hidden: bool,
    pub readonly: bool,
}

impl Entry {
    pub fn is_dir(&self) -> bool {
        self.kind == EntryKind::Directory
    }
}

/// Convert a `SystemTime` into epoch milliseconds, tolerating clocks before 1970.
pub fn mtime_ms(time: Option<SystemTime>) -> Option<i64> {
    let time = time?;
    match time.duration_since(SystemTime::UNIX_EPOCH) {
        Ok(d) => Some(d.as_millis() as i64),
        Err(e) => Some(-(e.duration().as_millis() as i64)),
    }
}

/// Best effort MIME guess from the file name extension.
///
/// Deliberately tiny: only formats that drive UI decisions (thumbnail vs icon vs
/// media player) are listed. Anything else returns `None` and the UI falls back
/// to a generic icon.
pub fn guess_mime(name: &str) -> Option<String> {
    let ext = name.rsplit_once('.')?.1.to_ascii_lowercase();
    let mime = match ext.as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "heic" => "image/heic",
        "svg" => "image/svg+xml",
        "mp4" | "m4v" => "video/mp4",
        "mkv" => "video/x-matroska",
        "mov" => "video/quicktime",
        "webm" => "video/webm",
        "avi" => "video/x-msvideo",
        "mp3" => "audio/mpeg",
        "flac" => "audio/flac",
        "wav" => "audio/wav",
        "m4a" => "audio/mp4",
        "pdf" => "application/pdf",
        "txt" | "log" => "text/plain",
        "md" => "text/markdown",
        "json" => "application/json",
        "zip" => "application/zip",
        "7z" => "application/x-7z-compressed",
        "rar" => "application/vnd.rar",
        "apk" => "application/vnd.android.package-archive",
        "srt" | "ass" | "vtt" => "text/plain",
        _ => return None,
    };
    Some(mime.to_string())
}
