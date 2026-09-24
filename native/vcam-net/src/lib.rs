//! Sockets, mDNS discovery, pairing, clock sync and fragment reassembly (ARC-002).
//! Runs its I/O on its own threads, never on Blender's main thread.

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(test)]
mod tests {
    #[test]
    fn shares_workspace_version() {
        assert_eq!(super::VERSION, vcam_protocol::VERSION);
    }
}
