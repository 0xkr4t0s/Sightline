//! UDP receiver thread with latest-sample slots and per-source stats (task 1.2.1; NET-002,
//! FR-BL-002/004, NFR-REL-002), and the host's viewfinder video sender (task 2.2c1;
//! NET-VID-001/004).
//!
//! The thread shares the socket with its receiver; a [`VideoSender`] holds it only weakly, so
//! stopping the receiver still closes it. No datagram is accepted until the session owner installs a
//! host-role [`Endpoint`]. Authentication and latest-sample updates share the session lock,
//! so replaced or revoked keys cannot repopulate a cleared slot.

use std::collections::VecDeque;
use std::io;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use mio::net::UdpSocket;
use mio::{Events, Interest, Poll, Token};

use vcam_protocol::{
    Clock, ClockEstimate, ClockEstimator, ControlState, DropReason, Endpoint, MAX_DATAGRAM,
    Message, Pose, SeqFilter, Status, VideoFragment, VideoFrameInfo, fragment_frame,
};

use crate::smooth::{PoseFilter, Smoothing};

/// How often the thread checks for `stop` while idle (NFR-REL-002: stop within 1 s).
const POLL: Duration = Duration::from_millis(50);
/// Window for pose rate and loss.
const WINDOW: Duration = Duration::from_secs(1);
/// vcp.md §8: end a session after 10 s without an authenticated device datagram.
const IDLE_TIMEOUT: Duration = Duration::from_secs(10);

const STATUS_INTERVAL: Duration = Duration::from_millis(500);
const CLOCK_INTERVAL: Duration = Duration::from_secs(1);
/// A frame whose fragments can't all be handed to the socket within this time is abandoned:
/// a newer frame is on its way, and the device drops incomplete frames anyway.
const VIDEO_SEND_BUDGET: Duration = Duration::from_millis(50);
/// Pause before retrying a fragment the socket refused as `WouldBlock` (full send buffer).
const VIDEO_RETRY: Duration = Duration::from_micros(200);

/// State actually applied by the host, not merely received over UDP (vcp.md §6.4).
/// Publish after Blender's main-thread apply step; the network worker owns sequence/flags.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostStatus {
    pub applied_pose_seq: u32,
    pub control_ack: u32,
    pub error_code: u16,
    /// None means no camera bound; Some names the driven object (at most 63 UTF-8 bytes).
    pub camera_name: Option<String>,
}

impl Default for HostStatus {
    fn default() -> Self {
        Self {
            applied_pose_seq: 0,
            control_ack: 0,
            error_code: 1, // no camera until the application binds one
            camera_name: None,
        }
    }
}

impl HostStatus {
    fn into_message(self, status_seq: u32) -> Message<'static> {
        Message::Status(Status {
            status_seq,
            applied_pose_seq: self.applied_pose_seq,
            control_ack: self.control_ack,
            error_code: self.error_code,
            flags: 1 | (u8::from(self.camera_name.is_some()) << 1),
            camera_name: self.camera_name.unwrap_or_default(),
        })
    }
}

/// The newest accepted pose, when it arrived, and from where.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PoseSample {
    /// Exactly as received: always kept for recording (FR-BL-006).
    pub pose: Pose,
    /// What to apply: `pose` after smoothing, or equal to `pose` when smoothing is off.
    pub smoothed: Pose,
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
    /// Clock offset/jitter from this session's `CLOCK` exchanges (NET-003); None before the
    /// first accepted reply. Map `Pose::capture_time_ns` with `ClockEstimate::host_time_ns`
    /// onto the host clock read by `UdpReceiver::host_clock_ns`.
    pub clock: Option<ClockEstimate>,
    /// Authenticated `CLOCK` replies not used: unmatched, expired or impossible (vcp.md §6.3).
    pub clock_rejected: u64,
    /// Viewfinder frames whose every fragment was sent this session (vcp.md §6.5).
    pub video_frames_sent: u64,
    pub video_fragments_sent: u64,
    /// Frames given up part-way this session: a socket error, or not sent within 50 ms.
    pub video_frames_failed: u64,
}

struct ActiveSession {
    endpoint: Endpoint,
    started_at: Instant,
    last_received: Option<Instant>,
    status: Message<'static>,
    status_dirty: bool,
    last_status: Option<Instant>,
    last_clock: Option<Instant>,
    clock: ClockEstimator,
    /// Last `VIDEO_FRAGMENT` `frame_id` used in this session (0 before the first frame).
    video_frame_id: u32,
}

#[derive(Default)]
struct State {
    active: Option<ActiveSession>,
    pose: Option<PoseSample>,
    control: Option<ControlSample>,
    pose_filter: SeqFilter,
    control_filter: SeqFilter,
    /// Per-receiver setting; survives session changes (see `reset`).
    smoothing: Option<Smoothing>,
    /// Per-session filter state.
    pose_smoother: PoseFilter,
    /// (arrival, seq) of accepted poses within `WINDOW`.
    window: VecDeque<(Instant, u32)>,
    stats: ReceiverStats,
}

impl State {
    /// Clears everything session-related but keeps the smoothing setting.
    fn reset(&mut self) {
        *self = Self {
            smoothing: self.smoothing,
            ..Self::default()
        };
    }

    fn expire(&mut self, now: Instant) {
        if self.active.as_ref().is_some_and(|s| {
            now.saturating_duration_since(s.last_received.unwrap_or(s.started_at)) >= IDLE_TIMEOUT
        }) {
            self.reset();
        }
    }

    fn handle(&mut self, bytes: &[u8], from: SocketAddr, now: Instant, host_ns: u64) {
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
                    let smoothed = match &self.smoothing {
                        Some(params) => self.pose_smoother.apply(&pose, params),
                        None => pose,
                    };
                    self.pose = Some(PoseSample {
                        pose,
                        smoothed,
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
            Message::Clock(Clock::Reply { t1, t2, t3 }) => {
                if active.clock.reply(t1, t2, t3, host_ns).is_err() {
                    self.stats.clock_rejected += 1;
                }
            }
            // The endpoint drops device requests and host-only types (§4.3.7).
            Message::Clock(Clock::Request { .. })
            | Message::Status(_)
            | Message::VideoFragment(_) => {}
        }
    }

    /// Called with the session lock held through send_to: revocation cannot race publication.
    fn send_due(&mut self, socket: &UdpSocket, out: &mut Vec<u8>, epoch: Instant) {
        let now = Instant::now();
        self.expire(now);
        let (Some(active), Some(source)) = (self.active.as_mut(), self.stats.source) else {
            return;
        };
        if active.status_dirty
            || active
                .last_status
                .is_none_or(|t| now.duration_since(t) >= STATUS_INTERVAL)
        {
            if let Message::Status(status) = &mut active.status {
                let Some(next) = status.status_seq.checked_add(1) else {
                    // Never wrap to a sequence the device would discard as stale.
                    self.reset();
                    return;
                };
                status.status_seq = next;
            }
            if !send(socket, &active.endpoint, &active.status, source, out)
                && let Message::Status(status) = &mut active.status
            {
                status.status_seq -= 1;
            }
            active.status_dirty = false;
            active.last_status = Some(now);
        }
        if active
            .last_clock
            .is_none_or(|t| now.duration_since(t) >= CLOCK_INTERVAL)
        {
            let t1 = host_clock(epoch);
            // Only a request that actually left the socket may be answered.
            if send(
                socket,
                &active.endpoint,
                &Message::Clock(Clock::Request { t1 }),
                source,
                out,
            ) {
                active.clock.request(t1);
            }
            active.last_clock = Some(now);
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
        s.clock = self.active.as_ref().and_then(|s| s.clock.estimate());
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
    /// Shared with the thread; dropped in `stop` under the state lock (see `VideoSender::step`).
    socket: Option<Arc<UdpSocket>>,
    local_addr: SocketAddr,
    epoch: Instant,
}

impl UdpReceiver {
    /// Binds `bind` and starts an idle receiver with no session keys.
    pub fn start(bind: SocketAddr) -> io::Result<Self> {
        // Readiness polling, not SO_RCVTIMEO: on Windows a blocking recv that times out while a
        // datagram arrives can silently lose that datagram (seen as ~2% loss under CPU load).
        let mut socket = UdpSocket::bind(bind)?;
        let poll = Poll::new()?;
        poll.registry()
            .register(&mut socket, Token(0), Interest::READABLE)?;
        let local_addr = socket.local_addr()?;
        let socket = Arc::new(socket);
        let state = Arc::new(Mutex::new(State::default()));
        let epoch = Instant::now();
        let stop = Arc::new(AtomicBool::new(false));
        let thread = std::thread::Builder::new()
            .name("vcam-udp-rx".into())
            .spawn({
                let (state, stop, socket) =
                    (Arc::clone(&state), Arc::clone(&stop), Arc::clone(&socket));
                move || receive_loop(&socket, poll, &state, &stop, epoch)
            })?;
        Ok(Self {
            state,
            stop,
            thread: Some(thread),
            socket: Some(socket),
            local_addr,
            epoch,
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
                status: HostStatus::default().into_message(0),
                status_dirty: true,
                last_status: None,
                last_clock: None,
                clock: ClockEstimator::default(),
                video_frame_id: 0,
            }),
            smoothing: state.smoothing,
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
            state.reset();
        }
    }

    pub(crate) fn is_active(&self, session_id: u32) -> bool {
        lock(&self.state)
            .active
            .as_ref()
            .is_some_and(|s| s.endpoint.session_id() == session_id)
    }

    /// Publish applied host state for this session; stale callers cannot update a replacement.
    /// Changes are sent on the next worker poll (at most 50 ms when idle), then at 2 Hz.
    /// Receiving POSE/CONTROL_STATE alone never advances the acknowledgements.
    pub fn update_status(&self, session_id: u32, status: HostStatus) -> io::Result<()> {
        if status
            .camera_name
            .as_ref()
            .is_some_and(|name| name.len() > Status::MAX_NAME)
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "camera name exceeds 63 UTF-8 bytes",
            ));
        }
        let mut state = lock(&self.state);
        let active = state
            .active
            .as_mut()
            .filter(|s| s.endpoint.session_id() == session_id)
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotConnected, "session is no longer active")
            })?;
        let seq = match &active.status {
            Message::Status(status) => status.status_seq,
            _ => unreachable!("session status is always STATUS"),
        };
        let message = status.into_message(seq);
        if active.status != message {
            active.status = message;
            active.status_dirty = true;
        }
        Ok(())
    }

    /// Turns pose smoothing on (`Some`) or off (`None`) for this and later sessions
    /// (FR-BL-006). Raw poses are always kept in `PoseSample::pose`. Changing it restarts the
    /// filter at the next pose. Invalid parameters are `InvalidInput`.
    pub fn set_smoothing(&self, smoothing: Option<Smoothing>) -> io::Result<()> {
        if let Some(s) = &smoothing {
            s.validate()?;
        }
        let mut state = lock(&self.state);
        state.smoothing = smoothing;
        state.pose_smoother = PoseFilter::default();
        Ok(())
    }

    #[must_use]
    pub fn smoothing(&self) -> Option<Smoothing> {
        lock(&self.state).smoothing
    }

    #[must_use]
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// The host clock of vcp.md §2 (monotonic ns since this receiver started): the clock of
    /// `CLOCK` `t1`/`t4`, onto which `ClockEstimate::host_time_ns` maps device times.
    #[must_use]
    pub fn host_clock_ns(&self) -> u64 {
        host_clock(self.epoch)
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

    /// A sender for viewfinder frames over this receiver's socket and session (task 2.2c1).
    #[must_use]
    pub fn video_sender(&self) -> VideoSender {
        VideoSender {
            state: Arc::downgrade(&self.state),
            socket: self.socket.as_ref().map_or_else(Weak::new, Arc::downgrade),
            out: Vec::with_capacity(MAX_DATAGRAM),
        }
    }

    /// Stops the thread and closes the socket. Idempotent; returns once the thread has exited.
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            // The thread never panics by construction; if it somehow did, there's nothing to
            // recover here and the socket is closed either way.
            let _ = thread.join();
        }
        // Under the state lock, so a `VideoSender` never keeps the socket open past `stop`.
        let mut state = lock(&self.state);
        self.socket = None;
        state.reset();
    }
}

impl Drop for UdpReceiver {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Fields of one encoded viewfinder frame that every fragment repeats (vcp.md §6.5). The
/// sender numbers the frames: `frame_id` starts at 1 in each session.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VideoFrameMeta {
    /// Host clock ([`UdpReceiver::host_clock_ns`]) when Blender drew the frame.
    pub render_time_ns: u64,
    /// `POSE.seq` on the camera when the frame was drawn (0 = none).
    pub pose_seq: u32,
    /// [`VideoFragment::CODEC_JPEG`] in Stage A.
    pub codec: u8,
    /// [`VideoFragment::COLOR_SRGB_REC709`].
    pub color: u8,
    /// JPEG quality 1–100, for display; 0 = not stated.
    pub quality: u8,
}

/// A frame [`VideoSender::send`] handed to the socket in full.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VideoSent {
    pub session_id: u32,
    pub frame_id: u32,
    pub fragments: usize,
}

enum Step {
    Sent,
    /// The socket's send buffer is full.
    Busy,
    /// The session changed or ended, or the receiver stopped.
    Gone,
    Failed(io::Error),
}

fn not_connected() -> io::Error {
    io::Error::new(
        io::ErrorKind::NotConnected,
        "no device session to send video to",
    )
}

/// Sends encoded frames as `VIDEO_FRAGMENT`s over a [`UdpReceiver`]'s socket (task 2.2c1;
/// NET-VID-001/004). Made by [`UdpReceiver::video_sender`]; use it from one sender thread.
/// It holds only weak references: once the receiver stops, sends fail with `NotConnected`.
pub struct VideoSender {
    state: Weak<Mutex<State>>,
    socket: Weak<UdpSocket>,
    out: Vec<u8>,
}

impl VideoSender {
    /// Splits `data` into fragments and sends them in index order to the device's latest
    /// authenticated source, sealed with the session keys (vcp.md §6.5). Fragments are never
    /// retransmitted. The session lock is held per fragment, not per frame, so pose handling
    /// waits for at most one `send_to`; a session change or stop ends the frame at once.
    ///
    /// # Errors
    /// `NotConnected` when there is no session with an authenticated source, the session
    /// changed part-way, or the receiver stopped; `InvalidInput` for an empty frame, one over
    /// 4 MiB, or an unknown codec/colour; `TimedOut` if the socket stayed full for 50 ms;
    /// other socket errors as returned. `TimedOut` and socket errors count in
    /// [`ReceiverStats::video_frames_failed`].
    pub fn send(&mut self, meta: VideoFrameMeta, data: &[u8]) -> io::Result<VideoSent> {
        let started = Instant::now();
        let (session_id, frame_id, fragments) = begin(&self.state, meta, data)?;
        let count = fragments.len();
        for (i, frag) in fragments.enumerate() {
            loop {
                match self.step(session_id, &frag, i + 1 == count) {
                    Step::Sent => break,
                    Step::Busy if started.elapsed() < VIDEO_SEND_BUDGET => {
                        std::thread::sleep(VIDEO_RETRY);
                    }
                    Step::Busy => return Err(self.fail(session_id, io::ErrorKind::TimedOut.into())),
                    Step::Gone => return Err(not_connected()),
                    Step::Failed(e) => return Err(self.fail(session_id, e)),
                }
            }
        }
        Ok(VideoSent {
            session_id,
            frame_id,
            fragments: count,
        })
    }

    fn step(&mut self, session_id: u32, frag: &VideoFragment<'_>, last: bool) -> Step {
        let Some(shared) = self.state.upgrade() else {
            return Step::Gone;
        };
        let mut state = lock(&shared);
        // Upgraded under the lock that `UdpReceiver::stop` drops its socket under, and released
        // before it: the socket never outlives `stop`.
        let Some(socket) = self.socket.upgrade() else {
            return Step::Gone;
        };
        let (Some(active), Some(dest)) = (state.active.as_ref(), state.stats.source) else {
            return Step::Gone;
        };
        if active.endpoint.session_id() != session_id {
            return Step::Gone;
        }
        self.out.clear();
        if let Err(e) = active
            .endpoint
            .seal(&Message::VideoFragment(*frag), &mut self.out)
        {
            return Step::Failed(io::Error::new(io::ErrorKind::InvalidData, format!("{e:?}")));
        }
        match socket.send_to(&self.out, dest) {
            Ok(n) if n == self.out.len() => {
                state.stats.video_fragments_sent += 1;
                if last {
                    state.stats.video_frames_sent += 1;
                }
                Step::Sent
            }
            Ok(_) => Step::Failed(io::ErrorKind::WriteZero.into()),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => Step::Busy,
            Err(e) => Step::Failed(e),
        }
    }

    /// Counts a frame given up part-way, if its session is still the active one.
    fn fail(&self, session_id: u32, e: io::Error) -> io::Error {
        if let Some(shared) = self.state.upgrade() {
            let mut state = lock(&shared);
            if state
                .active
                .as_ref()
                .is_some_and(|s| s.endpoint.session_id() == session_id)
            {
                state.stats.video_frames_failed += 1;
            }
        }
        e
    }
}

/// Numbers the frame in the active session and validates it; returns its fragments.
fn begin<'d>(
    state: &Weak<Mutex<State>>,
    meta: VideoFrameMeta,
    data: &'d [u8],
) -> io::Result<(
    u32,
    u32,
    impl ExactSizeIterator<Item = VideoFragment<'d>> + use<'d>,
)> {
    let shared = state.upgrade().ok_or_else(not_connected)?;
    let mut state = lock(&shared);
    let has_source = state.stats.source.is_some();
    let active = state
        .active
        .as_mut()
        .filter(|_| has_source)
        .ok_or_else(not_connected)?;
    let frame_id = active.video_frame_id.checked_add(1).ok_or_else(|| {
        io::Error::other("VIDEO_FRAGMENT frame_id exhausted; the device must start a new session")
    })?;
    let info = VideoFrameInfo {
        frame_id,
        render_time_ns: meta.render_time_ns,
        pose_seq: meta.pose_seq,
        codec: meta.codec,
        color: meta.color,
        quality: meta.quality,
        flags: 0,
    };
    let fragments = fragment_frame(info, data).map_err(|e| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("invalid video frame: {e:?}"),
        )
    })?;
    active.video_frame_id = frame_id;
    Ok((active.endpoint.session_id(), frame_id, fragments))
}

fn host_clock(epoch: Instant) -> u64 {
    u64::try_from(epoch.elapsed().as_nanos()).unwrap_or(u64::MAX)
}

fn receive_loop(
    socket: &UdpSocket,
    mut poll: Poll,
    state: &Mutex<State>,
    stop: &AtomicBool,
    epoch: Instant,
) {
    // One byte more than the largest valid datagram, so oversize datagrams are seen as oversize
    // instead of being silently truncated to a valid length.
    let mut buf = [0u8; MAX_DATAGRAM + 1];
    let mut out = Vec::with_capacity(MAX_DATAGRAM);
    let mut events = Events::with_capacity(4);
    while !stop.load(Ordering::Acquire) {
        // Wakes on readiness or after POLL (stop checks, idle expiry, due sends).
        if let Err(e) = poll.poll(&mut events, Some(POLL))
            && e.kind() != io::ErrorKind::Interrupted
        {
            std::thread::sleep(POLL);
        }
        // Drain until WouldBlock: readiness is edge-triggered on some platforms. Draining after
        // every wake (not only on events) also retries promptly after a transient error.
        loop {
            match socket.recv_from(&mut buf) {
                Ok((n, from)) => {
                    let host_ns = host_clock(epoch);
                    lock(state).handle(
                        buf.get(..n).unwrap_or_default(),
                        from,
                        Instant::now(),
                        host_ns,
                    );
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                // Windows reports a datagram larger than the buffer as an error (WSAEMSGSIZE)
                // instead of truncating it like macOS/Linux; it is still an oversize datagram.
                Err(e) if is_oversize(&e) => lock(state).stats.dropped.size += 1,
                // Transient errors (for example ICMP port unreachable surfacing on Windows as
                // ConnectionReset) must not end the thread; retry on the next wake.
                Err(_) => break,
            }
        }
        if !stop.load(Ordering::Acquire) {
            // Also expires an idle session (via `lock`).
            lock(state).send_due(socket, &mut out, epoch);
        }
    }
}

fn send(
    socket: &UdpSocket,
    endpoint: &Endpoint,
    message: &Message,
    source: SocketAddr,
    out: &mut Vec<u8>,
) -> bool {
    out.clear();
    endpoint.seal(message, out).is_ok() && socket.send_to(out, source).is_ok_and(|n| n == out.len())
}

/// `WSAEMSGSIZE`: on Windows, `recv_from` fails this way for a datagram larger than the buffer.
fn is_oversize(e: &io::Error) -> bool {
    const WSAEMSGSIZE: i32 = 10040;
    cfg!(windows) && e.raw_os_error() == Some(WSAEMSGSIZE)
}
