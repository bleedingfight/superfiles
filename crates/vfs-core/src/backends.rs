#[cfg(feature = "box")]
pub mod boxdrive;
#[cfg(any(
    feature = "gdrive",
    feature = "dropbox",
    feature = "onedrive",
    feature = "box"
))]
mod cloud;
#[cfg(feature = "dropbox")]
pub mod dropbox;
#[cfg(feature = "gdrive")]
pub mod google_drive;
pub mod local;
#[cfg(feature = "onedrive")]
pub mod onedrive;
#[cfg(feature = "pan115")]
pub mod pan115;
#[cfg(feature = "s3")]
pub mod s3;
#[cfg(feature = "sftp")]
pub mod sftp;
#[cfg(feature = "smb")]
pub mod smb;
#[cfg(feature = "webdav")]
pub mod webdav;

#[cfg(feature = "box")]
pub use boxdrive::BoxBackend;
#[cfg(feature = "dropbox")]
pub use dropbox::DropboxBackend;
#[cfg(feature = "gdrive")]
pub use google_drive::GoogleDriveBackend;
pub use local::LocalBackend;
#[cfg(feature = "onedrive")]
pub use onedrive::OneDriveBackend;
#[cfg(feature = "pan115")]
pub use pan115::Pan115Backend;
#[cfg(feature = "s3")]
pub use s3::S3Backend;
#[cfg(feature = "sftp")]
pub use sftp::{SftpAuth, SftpBackend};
#[cfg(feature = "smb")]
pub use smb::{SmbAuth, SmbBackend};
#[cfg(feature = "webdav")]
pub use webdav::{WebdavAuth, WebdavBackend};
