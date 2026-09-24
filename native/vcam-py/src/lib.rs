//! PyO3 bindings exposed to the Blender extension as `vcam_native` (ARC-001/002).
//! The PyO3 module itself is added in task 0.1.4.

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(test)]
mod tests {
    #[test]
    fn member_crates_share_one_version() {
        for v in [
            vcam_protocol::VERSION,
            vcam_net::VERSION,
            vcam_video::VERSION,
        ] {
            assert_eq!(super::VERSION, v);
        }
    }
}
