//! VCP message types, encode/decode and coordinate conversions (`docs/protocol/vcp.md`).
//!
//! Pure: no I/O and no platform-specific code (ARC-002). Every decoder is bounds-checked and
//! returns an error instead of panicking on malformed input (PR-005).
#![forbid(unsafe_code)]

mod clock;
mod control;
mod endpoint;
mod fresh;
mod message;
mod pairing;
mod wire;

pub use clock::{
    CLOCK_OUTSTANDING, CLOCK_REPLY_TIMEOUT_NS, CLOCK_WINDOW, ClockEstimate, ClockEstimator,
    ClockReject,
};
pub use control::{
    ControlError, ControlErrorMsg, ControlMessage, Hello, MAX_CONTROL_PAYLOAD, PairChallenge,
    PairProof, SRP_PUBLIC_LEN, SessionChallenge, control_type,
};
pub use endpoint::{
    DropReason, Endpoint, HEADER_LEN, MAGIC, MAX_DATAGRAM, PROTOCOL_VERSION, Role, SealError,
    TAG_LEN,
};
pub use fresh::{EpochWatcher, SeqFilter};
pub use message::{
    Clock, ClockSample, ControlState, Message, PayloadError, Pose, Status, msg_type,
};
pub use pairing::{
    HostPairing, PairError, PendingPair, SessionHandshake, SessionKeys, device_pair,
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
