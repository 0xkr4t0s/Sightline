//! Sockets, mDNS discovery, pairing, clock sync and fragment reassembly (ARC-002).
//! Runs its I/O on its own threads, never on Blender's main thread.

mod adapt;
mod control;
mod discovery;
mod smooth;
mod store;
mod udp;

pub use adapt::{
    AdaptChange, AdaptReason, AdaptStats, IntervalLoss, M2P_LIMIT_MS, QUALITY_FLOOR, QUALITY_STEP,
    StreamLevel, VideoAdapter,
};
pub use control::{
    ControlEvent, ControlServer, MemoryStore, PairedDevice, PairingStore, ServerConfig,
};
pub use smooth::{OneEuro, Smoothing};
pub use store::FileStore;
pub use udp::{
    ControlSample, DropCounts, HostStatus, PoseSample, ReceiverStats, UdpReceiver, VideoFrameMeta,
    VideoSender, VideoSent,
};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(test)]
mod tests {
    #[test]
    fn shares_workspace_version() {
        assert_eq!(super::VERSION, vcam_protocol::VERSION);
    }
}
