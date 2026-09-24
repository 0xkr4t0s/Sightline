//! VCP message types, encode/decode and coordinate conversions (`docs/protocol/vcp.md`).
//!
//! Pure: no I/O and no platform-specific code (ARC-002). Every decoder is bounds-checked and
//! returns an error instead of panicking on malformed input (PR-005).
#![forbid(unsafe_code)]

mod endpoint;
mod fresh;
mod message;
mod wire;

pub use endpoint::{
    DropReason, Endpoint, HEADER_LEN, MAGIC, MAX_DATAGRAM, PROTOCOL_VERSION, Role, SealError,
    TAG_LEN,
};
pub use fresh::{EpochWatcher, SeqFilter};
pub use message::{
    Clock, ClockSample, ControlState, Message, PayloadError, Pose, Status, msg_type,
};

/// Version of the Rust workspace, shared by every `vcam-*` crate.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(test)]
mod tests {
    use super::VERSION;

    #[test]
    fn version_is_semver_triple() {
        let parts: Vec<u32> = VERSION.split('.').map(|p| p.parse().unwrap()).collect();
        assert_eq!(parts.len(), 3, "{VERSION}");
    }
}
