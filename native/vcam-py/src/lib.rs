//! PyO3 bindings exposed to the Blender extension as `vcam_native` (ARC-001/002).
//!
//! C-2: every call returns promptly on Blender's main thread. Networking runs on `vcam-net`'s
//! own threads; results come back through latest-sample slots and a non-blocking event queue.
//! Calls that may block (bind, DNS-SD, shutdown joins) release the GIL. NFR-REL-001: a Rust
//! panic never reaches Python as `PanicException` (a `BaseException`); it becomes
//! [`NativeError`], a `RuntimeError` that add-on code can catch.

use std::panic::{AssertUnwindSafe, catch_unwind};

use pyo3::prelude::*;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pyo3::create_exception!(
    vcam_native,
    NativeError,
    pyo3::exceptions::PyRuntimeError,
    "An internal error (Rust panic) inside vcam_native. Stop the session and report it."
);

/// Runs `f`, turning a panic into [`NativeError`] with the panic message.
fn guard<T>(f: impl FnOnce() -> PyResult<T>) -> PyResult<T> {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or_else(|payload| {
        let message = payload
            .downcast_ref::<&str>()
            .map(|s| (*s).to_owned())
            .or_else(|| payload.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "unknown panic".to_owned());
        Err(NativeError::new_err(format!("native panic: {message}")))
    })
}

/// Native core of the VCam Blender extension.
#[pymodule]
mod vcam_native {
    use std::net::{IpAddr, SocketAddr};
    use std::path::PathBuf;
    use std::sync::{Mutex, MutexGuard, PoisonError};

    use pyo3::exceptions::{PyRuntimeError, PyValueError};
    use pyo3::prelude::*;
    use pyo3::types::PyDict;
    use vcam_net::{ControlEvent, ControlServer, FileStore, HostStatus, ServerConfig};

    use super::guard;

    #[pymodule_export]
    use super::NativeError;

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
            return Err(PyValueError::new_err("frame buffer must be C-contiguous"));
        };
        let sum = bytes.iter().map(|b| u64::from(b.get())).sum();
        Ok((bytes.len(), sum))
    }

    /// Test hook for the FFI panic boundary (NFR-REL-001): always raises `NativeError`.
    #[pyfunction]
    fn _panic_probe() -> PyResult<()> {
        guard(|| panic!("panic probe"))
    }

    /// One host session: TCP control server, UDP pose receiver and (optionally) DNS-SD.
    ///
    /// Create with `Session.start(...)`; call `stop()` from `unregister()`. Every method other
    /// than `stop()`/`running()` raises `RuntimeError` after stop.
    #[pyclass(module = "vcam_native", frozen)]
    struct Session {
        server: Mutex<Option<ControlServer>>,
    }

    /// Like PyO3's `io::Error` conversion, except caller mistakes (`InvalidInput`) are
    /// `ValueError` instead of `OSError`.
    fn io_err(e: std::io::Error) -> PyErr {
        if e.kind() == std::io::ErrorKind::InvalidInput {
            PyValueError::new_err(e.to_string())
        } else {
            e.into()
        }
    }

    fn stopped() -> PyErr {
        PyRuntimeError::new_err("session is stopped")
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    impl Session {
        fn lock(&self) -> MutexGuard<'_, Option<ControlServer>> {
            self.server.lock().unwrap_or_else(PoisonError::into_inner)
        }

        fn with<T>(&self, f: impl FnOnce(&mut ControlServer) -> PyResult<T>) -> PyResult<T> {
            guard(|| f(self.lock().as_mut().ok_or_else(stopped)?))
        }
    }

    #[pymethods]
    impl Session {
        /// Binds TCP `port` (0 = any free port) on `bind` and a UDP port (`udp_port`, 0 = any)
        /// on the same address, and starts the network threads. Pairings are stored under
        /// `config_dir`; `host_id` is 16 random bytes kept per install (vcp.md §9.3).
        #[staticmethod]
        #[pyo3(signature = (port, config_dir, host_id, bind = "0.0.0.0", udp_port = 0))]
        fn start(
            py: Python<'_>,
            port: u16,
            config_dir: PathBuf,
            host_id: &[u8],
            bind: &str,
            udp_port: u16,
        ) -> PyResult<Self> {
            guard(|| {
                let host_id: [u8; 16] = host_id
                    .try_into()
                    .map_err(|_| PyValueError::new_err("host_id must be exactly 16 bytes"))?;
                let ip: IpAddr = bind
                    .parse()
                    .map_err(|_| PyValueError::new_err(format!("invalid bind address {bind:?}")))?;
                let server = py
                    .detach(|| {
                        let store = FileStore::open(&config_dir)?;
                        ControlServer::start(
                            SocketAddr::new(ip, port),
                            ServerConfig::new(host_id, udp_port),
                            Box::new(store),
                        )
                    })
                    .map_err(io_err)?;
                Ok(Self {
                    server: Mutex::new(Some(server)),
                })
            })
        }

        /// Stops every thread, closes both sockets and withdraws DNS-SD (NFR-REL-002).
        /// Idempotent. Raises `OSError` only if DNS-SD withdrawal failed; the sockets are
        /// closed and the threads joined either way.
        fn stop(&self, py: Python<'_>) -> PyResult<()> {
            guard(|| {
                let Some(mut server) = self.lock().take() else {
                    return Ok(());
                };
                py.detach(move || server.stop()).map_err(io_err)?;
                Ok(())
            })
        }

        fn running(&self) -> bool {
            self.lock().is_some()
        }

        /// The bound TCP control port.
        fn port(&self) -> PyResult<u16> {
            self.with(|s| Ok(s.local_addr().port()))
        }

        /// The bound UDP port (sent to the device in `SESSION_CHALLENGE`).
        fn udp_port(&self) -> PyResult<u16> {
            self.with(|s| Ok(s.udp_addr().port()))
        }

        /// Starts or updates DNS-SD with this machine name and `.blend` name ("" if unsaved).
        /// Only queues registrations (the daemon thread does the network I/O), so it keeps the
        /// GIL: releasing it while holding the session lock could deadlock another caller.
        fn advertise(&self, host: &str, blend: &str) -> PyResult<()> {
            self.with(|s| s.advertise(host, blend).map_err(io_err))
        }

        /// The next asynchronous DNS-SD error message, or None.
        fn discovery_error(&self) -> PyResult<Option<String>> {
            self.with(|s| Ok(s.discovery_error()))
        }

        /// Opens pairing with a fresh 6-digit code and returns it (vcp.md §9.4).
        fn enable_pairing(&self) -> PyResult<String> {
            self.with(|s| s.enable_pairing().map_err(io_err))
        }

        fn disable_pairing(&self) -> PyResult<()> {
            self.with(|s| {
                s.disable_pairing();
                Ok(())
            })
        }

        /// The current pairing code, or None when pairing is closed or the code expired.
        fn pairing_code(&self) -> PyResult<Option<String>> {
            self.with(|s| Ok(s.pairing_code()))
        }

        /// The next control-channel event as a dict, or None. Never blocks.
        fn poll_event<'py>(&self, py: Python<'py>) -> PyResult<Option<Bound<'py, PyDict>>> {
            let Some(event) = self.with(|s| Ok(s.try_event()))? else {
                return Ok(None);
            };
            let d = PyDict::new(py);
            match event {
                ControlEvent::Paired {
                    device_id,
                    device_name,
                } => {
                    d.set_item("type", "paired")?;
                    d.set_item("device_id", hex(&device_id))?;
                    d.set_item("device_name", device_name)?;
                }
                ControlEvent::PairingStorageFailed { device_id, error } => {
                    d.set_item("type", "pairing_storage_failed")?;
                    d.set_item("device_id", hex(&device_id))?;
                    d.set_item("error", error)?;
                }
                ControlEvent::SessionStarted {
                    device_id,
                    device_name,
                    peer,
                    session_id,
                } => {
                    d.set_item("type", "session_started")?;
                    d.set_item("device_id", hex(&device_id))?;
                    d.set_item("device_name", device_name)?;
                    d.set_item("peer", peer.to_string())?;
                    d.set_item("session_id", session_id)?;
                }
                ControlEvent::SessionEnded {
                    device_id,
                    session_id,
                } => {
                    d.set_item("type", "session_ended")?;
                    d.set_item("device_id", hex(&device_id))?;
                    d.set_item("session_id", session_id)?;
                }
            }
            Ok(Some(d))
        }

        /// The newest pose (highest `seq`) as a dict, or None. Canonical axes (vcp.md §7),
        /// quaternion `(x, y, z, w)`, `age_s` since it arrived.
        fn latest_pose<'py>(&self, py: Python<'py>) -> PyResult<Option<Bound<'py, PyDict>>> {
            let Some(sample) = self.with(|s| Ok(s.latest_pose()))? else {
                return Ok(None);
            };
            let p = sample.pose;
            let d = PyDict::new(py);
            d.set_item("seq", p.seq)?;
            d.set_item("capture_time_ns", p.capture_time_ns)?;
            d.set_item("position", p.position_m)?;
            d.set_item("orientation", p.orientation)?;
            d.set_item("tracking_state", p.tracking_state)?;
            d.set_item("flags", p.flags)?;
            d.set_item("age_s", sample.received_at.elapsed().as_secs_f64())?;
            Ok(Some(d))
        }

        /// Receiver statistics for the N-panel (FR-BL-004) as a dict. `clock` is None until
        /// the first accepted `CLOCK` reply (NET-003).
        fn stats<'py>(&self, py: Python<'py>) -> PyResult<Bound<'py, PyDict>> {
            let s = self.with(|s| Ok(s.stats()))?;
            let d = PyDict::new(py);
            d.set_item("session_id", s.session_id)?;
            d.set_item(
                "last_datagram_age_s",
                s.last_datagram_age.map(|a| a.as_secs_f64()),
            )?;
            d.set_item("poses_applied", s.poses_applied)?;
            d.set_item("poses_stale", s.poses_stale)?;
            d.set_item("dropped", s.dropped.total())?;
            d.set_item("rate_hz", s.rate_hz)?;
            d.set_item("loss", s.loss)?;
            d.set_item("last_pose_age_s", s.last_pose_age.map(|a| a.as_secs_f64()))?;
            d.set_item("source", s.source.map(|a| a.to_string()))?;
            let clock = match s.clock {
                Some(c) => {
                    let c_dict = PyDict::new(py);
                    c_dict.set_item("offset_ns", c.offset_ns)?;
                    c_dict.set_item("delay_ns", c.delay_ns)?;
                    c_dict.set_item("jitter_ns", c.jitter_ns)?;
                    c_dict.set_item("samples", c.samples)?;
                    Some(c_dict)
                }
                None => None,
            };
            d.set_item("clock", clock)?;
            d.set_item("clock_rejected", s.clock_rejected)?;
            Ok(d)
        }

        /// The host clock (ns) that `stats()["clock"]["offset_ns"]` relates device capture
        /// times to: `host_time = capture_time_ns - offset_ns`.
        fn host_clock_ns(&self) -> PyResult<u64> {
            self.with(|s| Ok(s.host_clock_ns()))
        }

        /// Publishes the state Blender actually applied for `session_id` (vcp.md §6.4).
        #[pyo3(signature = (session_id, applied_pose_seq, control_ack, error_code, camera_name = None))]
        fn update_status(
            &self,
            session_id: u32,
            applied_pose_seq: u32,
            control_ack: u32,
            error_code: u16,
            camera_name: Option<String>,
        ) -> PyResult<()> {
            self.with(|s| {
                s.update_status(
                    session_id,
                    HostStatus {
                        applied_pose_seq,
                        control_ack,
                        error_code,
                        camera_name,
                    },
                )
                .map_err(io_err)
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use pyo3::PyResult;

    use super::guard;

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

    #[test]
    fn guard_turns_panics_into_errors_and_passes_results_through() {
        assert_eq!(guard(|| PyResult::Ok(7)).ok(), Some(7));
        assert!(guard(|| -> PyResult<()> { panic!("boom") }).is_err());
    }
}
