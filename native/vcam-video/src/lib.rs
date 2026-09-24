//! JPEG and H.264 encoders behind one trait (ARC-002). Platform encoder
//! backends are the only modules here allowed to opt in to `unsafe` (NFR-QA-004).

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(test)]
mod tests {
    #[test]
    fn shares_workspace_version() {
        assert_eq!(super::VERSION, vcam_protocol::VERSION);
    }
}
