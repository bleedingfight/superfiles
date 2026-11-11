//! LocalSend-compatible LAN transfer.
//!
//! Why this crate exists separately from `sfiles-stream` (the browser share
//! server): LocalSend mandates **HTTPS with a self-signed certificate**, a
//! multicast discovery loop and a bidirectional session API. Keeping it in its
//! own crate lets Android, iOS and HarmonyOS share the exact same protocol and
//! lets the TLS/inference footprint stay optional.

mod cert;
mod client;
mod error;
mod http;
mod protocol;
mod server;

pub use client::{DiscoveredPeer, LocalSendClient};
pub use cert::Identity;
pub use error::{Error, Result};
pub use protocol::{DeviceInfo, DeviceType, Files, PreparedFile, PrepareUpload};
pub use server::{LocalSendConfig, LocalSendService};

/// Default TCP/UDP port from the LocalSend specification.
pub const DEFAULT_PORT: u16 = 53317;
/// LocalSend's default multicast group (224.0.0.0/24 for Android compatibility).
pub const MULTICAST_GROUP: std::net::Ipv4Addr = std::net::Ipv4Addr::new(224, 0, 0, 167);
