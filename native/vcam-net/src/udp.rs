//! UDP receiver thread with latest-sample slots and per-source stats (task 1.2.1; NET-002,
//! FR-BL-002/004, NFR-REL-002).
//!
//! The thread owns the socket. No datagram is accepted until the session owner installs a
//! host-role [`Endpoint`]. Authentication and latest-sample updates share the session lock,
//! so replaced or revoked keys cannot repopulate a cleared slot.

use std::collections::VecDeque;
use std::io;
use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use vcam_protocol::{ControlState, DropReason, Endpoint, MAX_DATAGRAM, Message, Pose, SeqFilter};

/// How often the thread checks for `stop` while idle (NFR-REL-002: stop within 1 s).
const POLL: Duration = Duration::from_millis(50);
/// Window for pose rate and loss.
const WINDOW: Duration = Duration::from_secs(1);
/// vcp.md §8: end a session after 10 s without an authenticated device datagram.
const IDLE_TIMEOUT: Duration = Duration::from_secs(10);

/// The newest accepted pose, when it arrived, and from where.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PoseSample {
    pub pose: Pose,
    pub received_at: Instant,
    pub source: SocketAddr,
}

/// The newest accepted `CONTROL_STATE` (by `state_seq`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ControlSample {
    pub state: ControlState,
    pub received_at: Instant,
    pub source: SocketAddr,
}

/// Dropped datagrams by vcp.md §4.3 step (and §6 payload checks).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DropCounts {
    pub size: u64,
    pub magic: u64,
    pub version: u64,
    pub length: u64,
    pub session: u64,
    pub tag: u64,
    pub unknown_type: u64,
    pub payload: u64,
}

impl DropCounts {
    fn count(&mut self, reason: DropReason) {
        let slot = match reason {
            DropReason::Size => &mut self.size,
            DropReason::Magic => &mut self.magic,
            DropReason::Version => &mut self.version,
            DropReason::Length => &mut self.length,
            DropReason::Session => &mut self.session,
            DropReason::Tag => &mut self.tag,
            DropReason::UnknownType => &mut self.unknown_type,
            DropReason::Payload(_) => &mut self.payload,
        };
        *slot += 1;
    }

    #[must_use]
    pub fn total(&self) -> u64 {
        self.size
            + self.magic
            + self.version
            + self.length
            + self.session
            + self.tag
            + self.unknown_type
            + self.payload
    }
}

/// A snapshot for the N-panel (FR-BL-004).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ReceiverStats {
    pub session_id: Option<u32>,
    /// Age of the last authenticated datagram (None before the first one).
    pub last_datagram_age: Option<Duration>,
    /// Poses accepted into the slot (newer than every previous one).
    pub poses_applied: u64,
    /// Authenticated poses dropped because their seq wasn't newer (reordered or replayed).
    pub poses_stale: u64,
    pub dropped: DropCounts,
    /// Accepted poses per second over the last second.
    pub rate_hz: f64,
    /// Fraction of poses missing over the last second, from gaps in `seq` (0 when < 2 samples).
    pub loss: f64,
    /// Time since the newest accepted pose arrived.
    pub last_pose_age: Option<Duration>,
    /// Source of the most recent authenticated datagram: where the host sends replies (vcp.md §3).
    pub source: Option<SocketAddr>,
}

struct ActiveSession {
    endpoint: Endpoint,
    started_at: Instant,
    last_received: Option<Instant>,
}

#[derive(Default)]
struct State {
    active: Option<ActiveSession>,
    pose: Option<PoseSample>,
    control: Option<ControlSample>,
    pose_filter: SeqFilter,
    control_filter: SeqFilter,
    /// (arrival, seq) of accepted poses within `WINDOW`.
    window: VecDeque<(Instant, u32)>,
    stats: ReceiverStats,
}

impl State {
    fn expire(&mut self, now: Instant) {
        if self.active.as_ref().is_some_and(|s| {
            now.saturating_duration_since(s.last_received.unwrap_or(s.started_at)) >= IDLE_TIMEOUT
        }) {
            *self = Self::default();
        }
    }

    fn handle(&mut self, bytes: &[u8], from: SocketAddr, now: Instant) {
        self.expire(now);
        let Some(active) = self.active.as_mut() else {
            self.stats.dropped.session += 1;
            return;
        };
        let msg = match active.endpoint.open(bytes) {
            Ok(msg) => msg,
            Err(reason) => {
                self.stats.dropped.count(reason);
                return;
            }
        };
        active.last_received = Some(now);
        self.stats.source = Some(from);
        match msg {
            Message::Pose(pose) => {
                if self.pose_filter.accept(pose.seq) {
                    self.pose = Some(PoseSample {
                        pose,
                        received_at: now,
                        source: from,
                    });
                    self.stats.poses_applied += 1;
                    self.window.push_back((now, pose.seq));
                } else {
                    self.stats.poses_stale += 1;
                }
            }
            Message::ControlState(state) => {
                if self.control_filter.accept(state.state_seq) {
                    self.control = Some(ControlSample {
                        state,
                        received_at: now,
                        source: from,
                    });
                }
            }
            // CLOCK replies are handled by the clock task (1.2.4); a host never receives STATUS.
            Message::Clock(_) | Message::Status(_) => {}
        }
    }

    fn snapshot(&mut self, now: Instant) -> ReceiverStats {
        while self
            .window
            .front()
            .is_some_and(|&(t, _)| now.saturating_duration_since(t) > WINDOW)
        {
            self.window.pop_front();
        }
        let mut s = self.stats.clone();
        s.session_id = self.active.as_ref().map(|s| s.endpoint.session_id());
        s.last_datagram_age = self
            .active
            .as_ref()
            .and_then(|s| s.last_received)
            .map(|t| now.saturating_duration_since(t));
        s.rate_hz = self.window.len() as f64 / WINDOW.as_secs_f64();
        s.loss = match (self.window.front(), self.window.back()) {
            (Some(&(_, first)), Some(&(_, last))) if self.window.len() >= 2 => {
                let expected = f64::from(last.saturating_sub(first)) + 1.0;
                (1.0 - self.window.len() as f64 / expected).max(0.0)
            }
            _ => 0.0,
        };
        s.last_pose_age = self
            .pose
            .map(|p| now.saturating_duration_since(p.received_at));
        s
    }
}

fn lock(state: &Mutex<State>) -> MutexGuard<'_, State> {
    let mut guard = state.lock().unwrap_or_else(PoisonError::into_inner);
    guard.expire(Instant::now());
    guard
}

/// Owns a UDP socket and a receiver thread. Dropping it stops the thread and closes the socket.
pub struct UdpReceiver {
    state: Arc<Mutex<State>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    local_addr: SocketAddr,
}

impl UdpReceiver {
    /// Binds `bind` and starts an idle receiver with no session keys.
    pub fn start(bind: SocketAddr) -> io::Result<Self> {
        let socket = UdpSocket::bind(bind)?;
        socket.set_read_timeout(Some(POLL))?;
        let local_addr = socket.local_addr()?;
        let state = Arc::new(Mutex::new(State::default()));
        let stop = Arc::new(AtomicBool::new(false));
        let thread = std::thread::Builder::new()
            .name("vcam-udp-rx".into())
            .spawn({
                let (state, stop) = (Arc::clone(&state), Arc::clone(&stop));
                move || receive_loop(&socket, &state, &stop)
            })?;
        Ok(Self {
            state,
            stop,
            thread: Some(thread),
            local_addr,
        })
    }

    /// Atomically replace keys and clear all prior samples, filters, source and stats.
    /// Only the authenticated session owner should call this; `endpoint` must have host role.
    pub fn set_session(&self, endpoint: Endpoint) -> io::Result<()> {
        let mut state = lock(&self.state);
        if self.stop.load(Ordering::Acquire) {
            return Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "receiver stopped",
            ));
        }
        *state = State {
            active: Some(ActiveSession {
                endpoint,
                started_at: Instant::now(),
                last_received: None,
            }),
            ..State::default()
        };
        Ok(())
    }

    /// Revoke this session without clearing a newer replacement.
    pub fn clear_session(&self, session_id: u32) {
        let mut state = lock(&self.state);
        if state
            .active
            .as_ref()
            .is_some_and(|s| s.endpoint.session_id() == session_id)
        {
            *state = State::default();
        }
    }

    pub(crate) fn is_active(&self, session_id: u32) -> bool {
        lock(&self.state)
            .active
            .as_ref()
            .is_some_and(|s| s.endpoint.session_id() == session_id)
    }

    #[must_use]
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// The newest pose (highest `seq`) accepted so far (NET-002).
    #[must_use]
    pub fn latest_pose(&self) -> Option<PoseSample> {
        lock(&self.state).pose
    }

    /// The newest `CONTROL_STATE` (highest `state_seq`) accepted so far.
    #[must_use]
    pub fn latest_control(&self) -> Option<ControlSample> {
        lock(&self.state).control
    }

    #[must_use]
    pub fn stats(&self) -> ReceiverStats {
        lock(&self.state).snapshot(Instant::now())
    }

    /// Stops the thread and closes the socket. Idempotent; returns once the thread has exited.
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            // The thread never panics by construction; if it somehow did, there's nothing to
            // recover here and the socket is closed either way.
            let _ = thread.join();
        }
        *lock(&self.state) = State::default();
    }
}

impl Drop for UdpReceiver {
    fn drop(&mut self) {
        self.stop();
    }
}

fn receive_loop(socket: &UdpSocket, state: &Mutex<State>, stop: &AtomicBool) {
    // One byte more than the largest valid datagram, so oversize datagrams are seen as oversize
    // instead of being silently truncated to a valid length.
    let mut buf = [0u8; MAX_DATAGRAM + 1];
    while !stop.load(Ordering::Acquire) {
        match socket.recv_from(&mut buf) {
            Ok((n, from)) => {
                lock(state).handle(buf.get(..n).unwrap_or_default(), from, Instant::now());
            }
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                drop(lock(state))
            } // expire on idle polls too
            // Windows reports a datagram larger than the buffer as an error (WSAEMSGSIZE)
            // instead of truncating it like macOS/Linux; it is still an oversize datagram.
            Err(e) if is_oversize(&e) => lock(state).stats.dropped.size += 1,
            // Transient errors (for example ICMP port unreachable surfacing on Windows as
            // ConnectionReset) must not end the thread; back off briefly and keep listening.
            Err(_) => {
                std::thread::sleep(POLL);
                drop(lock(state));
            }
        }
    }
}

/// `WSAEMSGSIZE`: on Windows, `recv_from` fails this way for a datagram larger than the buffer.
fn is_oversize(e: &io::Error) -> bool {
    const WSAEMSGSIZE: i32 = 10040;
    cfg!(windows) && e.raw_os_error() == Some(WSAEMSGSIZE)
}
