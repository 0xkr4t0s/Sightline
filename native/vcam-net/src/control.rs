//! TCP control server: `HELLO`, pairing with a 6-digit code, and session setup (task 1.2.2a;
//! docs/protocol/vcp.md §9–§11; FR-UX-002, NFR-SEC-001, NET-004, NFR-REL-002).
//!
//! A listener thread accepts connections and serves each on its own thread. Results reach the
//! caller as [`ControlEvent`]s through a non-blocking queue (C-2). Pairing keys live behind a
//! [`PairingStore`]; [`crate::FileStore`] persists them in the caller's config directory.

use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use vcam_protocol::{
    ControlError, ControlErrorMsg, ControlMessage, Endpoint, HEADER_LEN, Hello, HostPairing,
    PROTOCOL_VERSION, PairError, Role, SessionChallenge, SessionHandshake,
};

use crate::discovery::{self, Discovery};
use crate::{ControlSample, HostStatus, PoseSample, ReceiverStats, UdpReceiver, VideoSender};

const POLL: Duration = Duration::from_millis(50);
/// How long a connection refused with `ERROR` keeps draining input before closing.
const ERROR_LINGER: Duration = Duration::from_secs(1);

/// A device paired with this host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairedDevice {
    pub device_id: [u8; 16],
    pub device_name: String,
    /// The pairing key `PK` (vcp.md §9.3).
    pub pk: [u8; 32],
}

/// Where pairing keys are kept (NFR-SEC-001).
pub trait PairingStore: Send {
    fn get(&self, device_id: &[u8; 16]) -> Option<PairedDevice>;
    /// Commit the pairing before returning success; an error must leave the old pairing intact.
    fn put(&mut self, device: PairedDevice) -> io::Result<()>;
}

/// Explicitly ephemeral store for tests and callers that do not need remembered pairings.
#[derive(Debug, Default)]
pub struct MemoryStore(HashMap<[u8; 16], PairedDevice>);

impl PairingStore for MemoryStore {
    fn get(&self, device_id: &[u8; 16]) -> Option<PairedDevice> {
        self.0.get(device_id).cloned()
    }

    fn put(&mut self, device: PairedDevice) -> io::Result<()> {
        self.0.insert(device.device_id, device);
        Ok(())
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ServerConfig {
    /// Random per host install (vcp.md §9.3).
    pub host_id: [u8; 16],
    /// UDP bind port on the TCP bind address; 0 chooses a free port, advertised in SESSION_CHALLENGE.
    pub udp_port: u16,
    /// vcp.md §9.4: a code is valid for 5 minutes...
    pub code_lifetime: Duration,
    /// ...and for 3 failed proofs.
    pub max_failures: u32,
    /// A connection must finish `HELLO` → pairing/session within this time.
    pub handshake_timeout: Duration,
}

impl ServerConfig {
    #[must_use]
    pub fn new(host_id: [u8; 16], udp_port: u16) -> Self {
        Self {
            host_id,
            udp_port,
            code_lifetime: Duration::from_secs(5 * 60),
            max_failures: 3,
            handshake_timeout: Duration::from_secs(10),
        }
    }
}

/// What happened on the control channel, in order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ControlEvent {
    Paired {
        device_id: [u8; 16],
        device_name: String,
    },
    /// Persistence failed: no PAIR_ACCEPT was sent and the connection is closed.
    PairingStorageFailed { device_id: [u8; 16], error: String },
    /// The authenticated session now owns UDP reception; samples are available on the server.
    SessionStarted {
        device_id: [u8; 16],
        device_name: String,
        peer: SocketAddr,
        session_id: u32,
    },
    /// The session's TCP connection closed (or a newer session replaced it).
    SessionEnded {
        device_id: [u8; 16],
        session_id: u32,
    },
}

struct PairingWindow {
    code: String,
    expires: Instant,
    failures: u32,
}

struct Inner {
    store: Box<dyn PairingStore>,
    pairing: Option<PairingWindow>,
    pairing_busy: bool,
    last_session_id: u32,
    /// Identifies the current owner so replaced connections cannot revoke its UDP state.
    /// Checked even if two concurrent handshakes happen to choose the same wire session ID.
    session_generation: u64,
}

struct Shared {
    inner: Mutex<Inner>,
    config: ServerConfig,
    stop: AtomicBool,
    udp: Mutex<UdpReceiver>,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn udp(&self) -> MutexGuard<'_, UdpReceiver> {
        self.udp.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The TCP control server. Dropping it stops all threads and closes all sockets.
pub struct ControlServer {
    shared: Arc<Shared>,
    events: Receiver<ControlEvent>,
    listener: Option<JoinHandle<()>>,
    local_addr: SocketAddr,
    discovery: Option<Discovery>,
}

impl ControlServer {
    pub fn start(
        bind: SocketAddr,
        mut config: ServerConfig,
        store: Box<dyn PairingStore>,
    ) -> io::Result<Self> {
        let listener = TcpListener::bind(bind)?;
        listener.set_nonblocking(true)?;
        let local_addr = listener.local_addr()?;
        let udp = UdpReceiver::start(SocketAddr::new(bind.ip(), config.udp_port))?;
        config.udp_port = udp.local_addr().port();
        let shared = Arc::new(Shared {
            inner: Mutex::new(Inner {
                store,
                pairing: None,
                pairing_busy: false,
                last_session_id: 0,
                session_generation: 0,
            }),
            config,
            stop: AtomicBool::new(false),
            udp: Mutex::new(udp),
        });
        let (tx, events) = mpsc::channel();
        let thread = std::thread::Builder::new()
            .name("vcam-ctl-accept".into())
            .spawn({
                let shared = Arc::clone(&shared);
                move || accept_loop(&listener, &shared, &tx)
            })?;
        Ok(Self {
            shared,
            events,
            listener: Some(thread),
            local_addr,
            discovery: None,
        })
    }

    #[must_use]
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    #[must_use]
    pub fn udp_addr(&self) -> SocketAddr {
        self.shared.udp().local_addr()
    }

    /// Enable DNS-SD while listening, or update the machine/blend names already advertised.
    /// Ports come from the bound sockets. Empty blend denotes an unsaved file.
    /// TXT entries must fit DNS-SD's 255-byte limit including key and '='; invalid input
    /// leaves existing records unchanged. Later daemon errors are available via discovery_error.
    pub fn advertise(&mut self, host: &str, blend: &str) -> io::Result<()> {
        if self.shared.stop.load(Ordering::Acquire) {
            return Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "server stopped",
            ));
        }
        let services = discovery::services(
            self.shared.config.host_id,
            self.local_addr(),
            self.udp_addr(),
            host,
            blend,
        )?;
        if let Some(discovery) = &self.discovery {
            discovery.publish(services)
        } else {
            self.discovery = Some(Discovery::start(services)?);
            Ok(())
        }
    }

    /// Next asynchronous DNS-SD socket/interface error, if any. Never blocks.
    pub fn discovery_error(&self) -> Option<String> {
        self.discovery.as_ref().and_then(Discovery::error)
    }

    #[must_use]
    pub fn latest_pose(&self) -> Option<PoseSample> {
        self.shared.udp().latest_pose()
    }

    #[must_use]
    pub fn latest_control(&self) -> Option<ControlSample> {
        self.shared.udp().latest_control()
    }

    #[must_use]
    pub fn stats(&self) -> ReceiverStats {
        self.shared.udp().stats()
    }

    /// Host clock (ns) that `stats().clock` maps device capture times onto (NET-003).
    #[must_use]
    pub fn host_clock_ns(&self) -> u64 {
        self.shared.udp().host_clock_ns()
    }

    /// Pose smoothing on/off for this and later sessions (FR-BL-006); raw poses are kept.
    pub fn set_smoothing(&self, smoothing: Option<crate::Smoothing>) -> io::Result<()> {
        self.shared.udp().set_smoothing(smoothing)
    }

    #[must_use]
    pub fn smoothing(&self) -> Option<crate::Smoothing> {
        self.shared.udp().smoothing()
    }

    /// Publish state applied by Blender for the current session (not just received samples).
    pub fn update_status(&self, session_id: u32, status: HostStatus) -> io::Result<()> {
        self.shared.udp().update_status(session_id, status)
    }

    /// A sender for encoded viewfinder frames to the current device session (task 2.2c1).
    /// It follows session changes and fails with `NotConnected` after `stop`.
    #[must_use]
    pub fn video_sender(&self) -> VideoSender {
        self.shared.udp().video_sender()
    }

    /// Starts (or restarts) pairing with a fresh code, valid for one success, 3 failures, or
    /// `code_lifetime` (vcp.md §9.4). Returns the code to show in the N-panel.
    pub fn enable_pairing(&self) -> io::Result<String> {
        let code = random_code()?;
        self.shared.lock().pairing = Some(PairingWindow {
            code: code.clone(),
            expires: Instant::now() + self.shared.config.code_lifetime,
            failures: 0,
        });
        Ok(code)
    }

    pub fn disable_pairing(&self) {
        self.shared.lock().pairing = None;
    }

    /// The current code, or `None` if pairing is off, used up, or expired.
    #[must_use]
    pub fn pairing_code(&self) -> Option<String> {
        let mut inner = self.shared.lock();
        expire(&mut inner);
        inner.pairing.as_ref().map(|p| p.code.clone())
    }

    /// Next event, if any. Never blocks.
    #[must_use]
    pub fn try_event(&self) -> Option<ControlEvent> {
        self.events.try_recv().ok()
    }

    /// Stops all sockets/workers and withdraws DNS-SD. Idempotent.
    /// Returns DNS-SD shutdown errors after still stopping TCP/UDP; call again to retry.
    pub fn stop(&mut self) -> io::Result<()> {
        self.shared.stop.store(true, Ordering::Release);
        self.shared.udp().stop();
        if let Some(thread) = self.listener.take() {
            let _ = thread.join();
        }
        if let Some(discovery) = &mut self.discovery {
            discovery.stop()?;
        }
        self.discovery = None;
        Ok(())
    }
}

impl Drop for ControlServer {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

fn expire(inner: &mut Inner) {
    if inner
        .pairing
        .as_ref()
        .is_some_and(|p| Instant::now() >= p.expires)
    {
        inner.pairing = None;
    }
}

fn random<const N: usize>() -> io::Result<[u8; N]> {
    let mut out = [0u8; N];
    getrandom::fill(&mut out).map_err(io::Error::other)?;
    Ok(out)
}

/// Uniform 000000–999999: rejection-sample a u32 below the largest multiple of 1,000,000.
fn random_code() -> io::Result<String> {
    const LIMIT: u32 = 4_294_000_000;
    loop {
        let n = u32::from_le_bytes(random()?);
        if n < LIMIT {
            return Ok(format!("{:06}", n % 1_000_000));
        }
    }
}

fn accept_loop(listener: &TcpListener, shared: &Arc<Shared>, events: &Sender<ControlEvent>) {
    let mut connections: Vec<JoinHandle<()>> = Vec::new();
    while !shared.stop.load(Ordering::Acquire) {
        match listener.accept() {
            Ok((stream, peer)) => {
                let (shared, events) = (Arc::clone(shared), events.clone());
                let spawned = std::thread::Builder::new()
                    .name("vcam-ctl-conn".into())
                    .spawn(move || {
                        let mut conn = Conn {
                            stream,
                            peer,
                            shared: &shared,
                            events: &events,
                            active_session: None,
                        };
                        conn.serve();
                    });
                if let Ok(handle) = spawned {
                    connections.push(handle);
                }
                connections.retain(|h| !h.is_finished());
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => std::thread::sleep(POLL),
            Err(_) => std::thread::sleep(POLL),
        }
    }
    for handle in connections {
        let _ = handle.join();
    }
}

/// Why a connection ended.
enum End {
    /// Peer closed, timed out, the server is stopping, or an I/O error: just close.
    Close,
    /// Send `ERROR code`, then close.
    Error(u16, &'static str),
}

impl From<io::Error> for End {
    fn from(_: io::Error) -> Self {
        End::Close
    }
}

impl From<ControlError> for End {
    fn from(e: ControlError) -> Self {
        match e {
            ControlError::Version => {
                End::Error(ControlErrorMsg::UNSUPPORTED_VERSION, "unsupported version")
            }
            _ => End::Error(ControlErrorMsg::MALFORMED, "malformed message"),
        }
    }
}

struct Conn<'a> {
    stream: TcpStream,
    peer: SocketAddr,
    shared: &'a Shared,
    events: &'a Sender<ControlEvent>,
    active_session: Option<(u64, u32)>, // generation and session ID
}

impl Conn<'_> {
    fn serve(&mut self) {
        if self.stream.set_read_timeout(Some(POLL)).is_err()
            || self.stream.set_write_timeout(Some(POLL)).is_err()
            || self.stream.set_nodelay(true).is_err()
        {
            return;
        }
        if let Err(End::Error(code, message)) = self.run() {
            let msg = ControlMessage::Error(ControlErrorMsg {
                code,
                message: message.to_owned(),
            });
            if let Ok(frame) = msg.encode()
                && self.stream.write_all(&frame).is_ok()
            {
                self.linger_close();
            }
        }
        let _ = self.stream.shutdown(std::net::Shutdown::Both);
    }

    /// Sends FIN after an `ERROR`, then discards what the peer still sends until it
    /// closes (bounded by `ERROR_LINGER`). Closing with unread input makes the stack
    /// send RST, and Windows then drops the `ERROR` the peer hasn't read yet.
    fn linger_close(&mut self) {
        if self.stream.shutdown(std::net::Shutdown::Write).is_err() {
            return;
        }
        let deadline = Instant::now() + ERROR_LINGER;
        let mut sink = [0u8; 512];
        while !self.shared.stop.load(Ordering::Acquire) && Instant::now() < deadline {
            match self.stream.read(&mut sink) {
                Ok(0) => return,
                Ok(_) => {}
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::WouldBlock
                            | io::ErrorKind::TimedOut
                            | io::ErrorKind::Interrupted
                    ) => {}
                Err(_) => return,
            }
        }
    }

    fn run(&mut self) -> Result<(), End> {
        let deadline = Instant::now() + self.shared.config.handshake_timeout;
        let mut hello = self.expect_hello(Some(deadline))?;
        if hello.mode == Hello::MODE_PAIR {
            self.pair(&hello, deadline)?;
            // After PAIR_ACCEPT the device starts a session on the same connection (§9.3).
            hello = self.expect_hello(Some(deadline))?;
        }
        if hello.mode != Hello::MODE_SESSION {
            return Err(End::Error(ControlErrorMsg::MALFORMED, "unknown HELLO mode"));
        }
        self.session(&hello, deadline)
    }

    fn expect_hello(&mut self, deadline: Option<Instant>) -> Result<Hello, End> {
        match self.read(deadline)? {
            ControlMessage::Hello(h)
                if h.proto_min <= PROTOCOL_VERSION && PROTOCOL_VERSION <= h.proto_max =>
            {
                Ok(h)
            }
            ControlMessage::Hello(_) => Err(End::Error(
                ControlErrorMsg::UNSUPPORTED_VERSION,
                "no common version",
            )),
            _ => Err(End::Error(ControlErrorMsg::MALFORMED, "expected HELLO")),
        }
    }

    fn pair(&mut self, hello: &Hello, deadline: Instant) -> Result<(), End> {
        let code = {
            let mut inner = self.shared.lock();
            expire(&mut inner);
            let Some(window) = inner.pairing.as_ref() else {
                return Err(End::Error(
                    ControlErrorMsg::PAIRING_DISABLED,
                    "pairing disabled or code expired",
                ));
            };
            let code = window.code.clone();
            if inner.pairing_busy {
                return Err(End::Error(
                    ControlErrorMsg::BUSY,
                    "another pairing is in progress",
                ));
            }
            inner.pairing_busy = true;
            code
        };
        let result = self.pair_with(hello, &code, deadline);
        let mut inner = self.shared.lock();
        inner.pairing_busy = false;
        match result {
            Ok((device, m2)) => {
                if let Err(error) = inner.store.put(device.clone()) {
                    drop(inner);
                    let _ = self.events.send(ControlEvent::PairingStorageFailed {
                        device_id: device.device_id,
                        error: error.to_string(),
                    });
                    // v1 has no storage-error wire code. Close without acknowledging.
                    return Err(End::Close);
                }
                inner.pairing = None; // single use after the pairing is committed (§9.4)
                drop(inner);
                let _ = self.events.send(ControlEvent::Paired {
                    device_id: device.device_id,
                    device_name: device.device_name,
                });
                self.write(&ControlMessage::PairAccept { m2 })
            }
            Err(PairFailure::Proof) => {
                if let Some(w) = inner.pairing.as_mut() {
                    w.failures += 1;
                    if w.failures >= self.shared.config.max_failures {
                        inner.pairing = None;
                    }
                }
                Err(End::Error(ControlErrorMsg::PROOF_FAILED, "proof failed"))
            }
            Err(PairFailure::End(end)) => Err(end),
        }
    }

    fn pair_with(
        &mut self,
        hello: &Hello,
        code: &str,
        deadline: Instant,
    ) -> Result<(PairedDevice, [u8; 32]), PairFailure> {
        let host = HostPairing::new(
            code,
            hello,
            self.shared.config.host_id,
            random()?,
            &random()?,
        )
        .map_err(|_| End::Error(ControlErrorMsg::MALFORMED, "cannot start pairing"))?;
        self.write(&ControlMessage::PairChallenge(host.challenge().clone()))?;
        let ControlMessage::PairProof(proof) = self.read(Some(deadline))? else {
            return Err(End::Error(ControlErrorMsg::MALFORMED, "expected PAIR_PROOF").into());
        };
        let (m2, pk) = match host.verify(&proof) {
            Ok(v) => v,
            // Illegal SRP values are an attack or a broken client: count them like a bad proof.
            Err(PairError::BadProof | PairError::IllegalValue) => return Err(PairFailure::Proof),
            Err(PairError::BadCode | PairError::Encode(_)) => {
                return Err(End::Error(ControlErrorMsg::MALFORMED, "cannot verify").into());
            }
        };
        Ok((
            PairedDevice {
                device_id: hello.device_id,
                device_name: hello.device_name.clone(),
                pk,
            },
            m2,
        ))
    }

    fn session(&mut self, hello: &Hello, deadline: Instant) -> Result<(), End> {
        let Some(device) = self.shared.lock().store.get(&hello.device_id) else {
            return Err(End::Error(ControlErrorMsg::NOT_PAIRED, "device not paired"));
        };
        let session_id = {
            let last = self.shared.lock().last_session_id;
            loop {
                let id = u32::from_le_bytes(random()?);
                if id != 0 && id != last {
                    break id;
                }
            }
        };
        let challenge = SessionChallenge {
            host_id: self.shared.config.host_id,
            nonce_h: random()?,
            session_id,
            udp_port: self.shared.config.udp_port,
        };
        let hs = SessionHandshake::new(&device.pk, hello, &challenge)
            .map_err(|_| End::Error(ControlErrorMsg::MALFORMED, "bad HELLO"))?;
        self.write(&ControlMessage::SessionChallenge(challenge))?;
        let ControlMessage::SessionProof { proof: proof_d } = self.read(Some(deadline))? else {
            return Err(End::Error(
                ControlErrorMsg::MALFORMED,
                "expected SESSION_PROOF",
            ));
        };
        if !hs.verify_device_proof(&proof_d) {
            return Err(End::Error(
                ControlErrorMsg::PROOF_FAILED,
                "session proof failed",
            ));
        }
        let (Some(proof_h), Some(keys)) = (hs.host_proof(&proof_d), hs.keys()) else {
            return Err(End::Close);
        };
        let endpoint = Endpoint::new(Role::Host, keys.session_id, &keys.k_d2h, &keys.k_h2d)
            .ok_or(End::Close)?;
        let accept = ControlMessage::SessionAccept { proof: proof_h }.encode()?;
        let generation = {
            let mut inner = self.shared.lock();
            if self.shared.stop.load(Ordering::Acquire) {
                return Err(End::Close);
            }
            inner.last_session_id = session_id;
            inner.session_generation += 1;
            self.shared.udp().set_session(endpoint)?;
            // Serialize activation and acceptance so an older handshake cannot overwrite a
            // newer accepted session. Socket writes have a bounded timeout.
            if self.stream.write_all(&accept).is_err() {
                self.shared.udp().clear_session(session_id);
                return Err(End::Close);
            }
            let _ = self.events.send(ControlEvent::SessionStarted {
                device_id: device.device_id,
                device_name: device.device_name,
                peer: self.peer,
                session_id,
            });
            inner.session_generation
        };
        self.active_session = Some((generation, session_id));
        // v1 defines no messages after session setup: hold the connection until it closes.
        let end = loop {
            match self.read(None) {
                Ok(_) => {}
                Err(end) => break end,
            }
        };
        {
            let inner = self.shared.lock();
            if inner.session_generation == generation {
                self.shared.udp().clear_session(session_id);
            }
            let _ = self.events.send(ControlEvent::SessionEnded {
                device_id: device.device_id,
                session_id,
            });
        }
        self.active_session = None;
        match end {
            End::Error(..) => Err(end),
            End::Close => Ok(()),
        }
    }

    fn write(&mut self, msg: &ControlMessage) -> Result<(), End> {
        let frame = msg.encode().map_err(|_| End::Close)?;
        self.stream.write_all(&frame)?;
        Ok(())
    }

    /// Reads one frame. `End::Close` on EOF, stop, deadline, or I/O error.
    fn read(&mut self, deadline: Option<Instant>) -> Result<ControlMessage, End> {
        let mut header = [0u8; HEADER_LEN];
        self.read_exact(&mut header, deadline)?;
        let total = ControlMessage::frame_len(&header)?;
        let mut frame = vec![0u8; total];
        frame[..HEADER_LEN].copy_from_slice(&header);
        self.read_exact(&mut frame[HEADER_LEN..], deadline)?;
        Ok(ControlMessage::decode(&frame)?)
    }

    fn read_exact(&mut self, mut buf: &mut [u8], deadline: Option<Instant>) -> Result<(), End> {
        while !buf.is_empty() {
            if self.shared.stop.load(Ordering::Acquire)
                || deadline.is_some_and(|d| Instant::now() >= d)
            {
                return Err(End::Close);
            }
            if let Some((generation, session_id)) = self.active_session {
                let inner = self.shared.lock();
                if inner.session_generation != generation
                    || !self.shared.udp().is_active(session_id)
                {
                    return Err(End::Close);
                }
            }
            match self.stream.read(buf) {
                Ok(0) => return Err(End::Close),
                Ok(n) => buf = &mut buf[n..],
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) => {}
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => return Err(End::Close),
            }
        }
        Ok(())
    }
}

enum PairFailure {
    /// `M1` did not verify (counts toward the 3-failure limit).
    Proof,
    End(End),
}

impl From<End> for PairFailure {
    fn from(end: End) -> Self {
        PairFailure::End(end)
    }
}

impl From<io::Error> for PairFailure {
    fn from(_: io::Error) -> Self {
        PairFailure::End(End::Close)
    }
}
