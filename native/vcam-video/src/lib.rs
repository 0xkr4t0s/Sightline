//! JPEG and H.264 encoders behind one trait (ARC-002), and the latest-frame slot that feeds
//! them ([`frame`]). Platform encoder backends are the only modules here allowed to opt in to
//! `unsafe` (NFR-QA-004).

pub mod frame;

pub use frame::{Frame, FrameColorSpace, FrameError, FrameMeta, FrameSlot};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(test)]
mod tests {
    #[test]
    fn shares_workspace_version() {
        assert_eq!(super::VERSION, vcam_protocol::VERSION);
    }
}
