//! Bridging platform owned file descriptors into the Rust core.
//!
//! This is the single most important performance rule in the project:
//! **file bytes never cross the FFI boundary**. iOS hands us an
//! `NSFileHandle.fileDescriptor`, Android hands us a `ParcelFileDescriptor`
//! (detached) or a plain `FileOutputStream.fd`; the core then does the I/O
//! directly.
//!
//! `ManuallyDrop<File>` is used so the descriptor is **not** closed when the
//! wrapper drops: ownership stays with the caller (Swift/Kotlin), which keeps
//! the contract simple and avoids double-close crashes.

use std::io::{Read, Write};

#[cfg(unix)]
fn borrowed(fd: i32) -> std::mem::ManuallyDrop<std::fs::File> {
    use std::os::fd::FromRawFd;
    // SAFETY: the caller guarantees `fd` stays valid for the duration of the
    // call (Swift/Kotlin keep the owning handle alive across the FFI call).
    std::mem::ManuallyDrop::new(unsafe { std::fs::File::from_raw_fd(fd) })
}

/// Write `data` to a caller owned file descriptor.
#[cfg(unix)]
pub fn write_all(fd: i32, data: &[u8]) -> std::io::Result<()> {
    let mut file = borrowed(fd);
    file.write_all(data)
}

/// Read up to `buf.len()` bytes from a caller owned file descriptor.
#[cfg(unix)]
pub fn read_some(fd: i32, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut file = borrowed(fd);
    file.read(buf)
}

#[cfg(not(unix))]
pub fn write_all(_fd: i32, _data: &[u8]) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "raw fd bridging is only implemented for unix targets",
    ))
}

#[cfg(not(unix))]
pub fn read_some(_fd: i32, _buf: &mut [u8]) -> std::io::Result<usize> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "raw fd bridging is only implemented for unix targets",
    ))
}
