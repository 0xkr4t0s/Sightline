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

    /// Spike S-1 probe (private; replaced by the encoder hand-off in task 2.1).
    ///
    /// Reads every byte of a C-contiguous `uint8` frame (e.g. the `gpu.types.Buffer`
    /// from `GPUOffScreen.texture_color.read()`) through the buffer protocol, without
    /// copying it. Returns `(byte_count, byte_sum)`.
    #[pyfunction]
    fn _frame_probe(py: Python<'_>, frame: pyo3::buffer::PyBuffer<u8>) -> PyResult<(usize, u64)> {
        let Some(bytes) = frame.as_slice(py) else {
            return Err(pyo3::exceptions::PyValueError::new_err(
                "frame buffer must be C-contiguous",
            ));
        };
        let sum = bytes.iter().map(|b| u64::from(b.get())).sum();
        Ok((bytes.len(), sum))
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
