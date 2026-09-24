//! VCP message types, encode/decode and coordinate conversions.
//!
//! Pure: no I/O and no platform-specific code (ARC-002).
#![forbid(unsafe_code)]

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
