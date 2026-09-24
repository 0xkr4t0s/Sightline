//! PyO3 bindings exposed to the Blender extension as `vcam_native` (ARC-001/002).

use pyo3::prelude::*;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Native core of the VCam Blender extension.
#[pymodule]
mod vcam_native {
    use pyo3::prelude::*;

    /// Version of the Rust native module.
    #[pyfunction]
    fn version() -> &'static str {
        super::VERSION
    }
}

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
