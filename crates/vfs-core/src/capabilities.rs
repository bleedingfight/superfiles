/// What a backend can actually do.
///
/// UI must drive button state from this instead of assuming "SMB can't do X".
/// Exposed to Swift/Kotlin as a record so both platforms read the same flags.
#[derive(Debug, Clone, Copy)]
pub struct Capabilities {
    pub can_list: bool,
    pub can_read: bool,
    pub can_write: bool,
    pub can_create: bool,
    pub can_rename: bool,
    pub can_delete: bool,
    /// Supports reading from an arbitrary offset (required for range playback).
    pub can_seek: bool,
    /// Supports writing at an arbitrary offset (required for resumable uploads).
    pub can_random_write: bool,
    /// Emits change notifications (local `FSEvents`/`inotify`, SMB notify, ...).
    pub can_watch: bool,
    /// Can generate thumbnails natively, without downloading the whole file.
    pub native_thumbnails: bool,
}

impl Capabilities {
    /// Read-only browsing: SMB guest shares, WebDAV with read-only tokens, ...
    pub const READ_ONLY: Capabilities = Capabilities {
        can_list: true,
        can_read: true,
        can_write: false,
        can_create: false,
        can_rename: false,
        can_delete: false,
        can_seek: true,
        can_random_write: false,
        can_watch: false,
        native_thumbnails: false,
    };

    /// Full local filesystem access.
    pub const READ_WRITE: Capabilities = Capabilities {
        can_list: true,
        can_read: true,
        can_write: true,
        can_create: true,
        can_rename: true,
        can_delete: true,
        can_seek: true,
        can_random_write: true,
        can_watch: true,
        native_thumbnails: false,
    };

    /// Browsing plus downloads (most HTTP based cloud drives before write scope).
    pub const DOWNLOAD_ONLY: Capabilities = Capabilities {
        can_list: true,
        can_read: true,
        can_write: false,
        can_create: false,
        can_rename: false,
        can_delete: false,
        can_seek: true,
        can_random_write: false,
        can_watch: false,
        native_thumbnails: false,
    };
}
