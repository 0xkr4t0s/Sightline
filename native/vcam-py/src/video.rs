//! Stage A viewfinder pipeline behind `vcam_native.Session.start_video` (task 2.2c2a;
//! NET-VID-001, NET-VID-004).
//!
//! Two threads, neither touching Python: [`JpegWorker`] encodes the newest frame of the
//! renderer's [`FrameSlot`], and `vcam-video-send` hands the newest encoded frame to the
//! session's [`VideoSender`], which splits it into `VIDEO_FRAGMENT`s (vcp.md §6.5). Both hand-offs
//! are newest-wins, so a slow stage skips frames instead of queueing them. Until a device
//! session has an authenticated UDP source, frames are counted as unsent and dropped.
//!
//! The sender thread also runs NET-VID-005 (task 2.2d2b): one [`VideoAdapter`] per device
//! session learns of every frame the sender finished and of the device's newest
//! `VIDEO_REPORT`, and the encoder uses the quality of the adapter's level. A new device
//! session starts again at the user's quality. The level's resolution step is only reported;
//! the renderer applies it.

use std::io;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use vcam_net::{AdaptStats, StreamLevel, VideoAdapter, VideoFrameMeta, VideoSender, VideoSent};
use vcam_protocol::{VideoFragment, VideoReport};
use vcam_video::{EncodeError, EncodedFrame, FrameColorSpace, FrameSlot, JpegWorker};

/// How long the sender sleeps between stop-flag checks when no frame arrives. Stopping wakes
/// it at once, so this only bounds a missed wake-up.
const IDLE_WAIT: Duration = Duration::from_millis(500);

/// The newest frame handed to the socket in full.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LastSent {
    /// `frame_id` of the source frame in the [`FrameSlot`].
    pub source_frame_id: u64,
    /// `frame_id` on the wire (1, 2, … per device session).
    pub wire_frame_id: u32,
    pub session_id: u32,
    pub pose_seq: u32,
    pub render_time_ns: u64,
    pub width: u32,
    pub height: u32,
    pub quality: u8,
    pub jpeg_bytes: usize,
    pub fragments: usize,
    pub encode_ns: u64,
    pub send_ns: u64,
}

/// NET-VID-005 state of the current device session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AdaptInfo {
    pub session_id: u32,
    /// Level, loss totals, the last report's interval and the last change.
    pub stats: AdaptStats,
    /// The device's newest `VIDEO_REPORT` fed to the adapter (vcp.md §6.6), or None.
    pub report: Option<VideoReport>,
}

/// Counters of a [`VideoPipeline`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VideoStats {
    pub encoded: u64,
    pub encode_failed: u64,
    /// Encoded frames the sender never took (replaced by a newer one).
    pub encoded_skipped: u64,
    pub sent: u64,
    /// Dropped because no device session had an authenticated source (`NotConnected`).
    pub unsent: u64,
    /// Given up for any other reason (full socket for 50 ms, socket error, …).
    pub send_failed: u64,
    /// The quality the encoder uses now (the adapter's level; 0 once stopped).
    pub quality: u8,
    /// The quality the user chose.
    pub user_quality: u8,
    /// None until a frame reaches a device session, and again once it ends.
    pub adapt: Option<AdaptInfo>,
    pub last_sent: Option<LastSent>,
    pub last_error: Option<String>,
}

/// NET-VID-005 for one stream: one [`VideoAdapter`] per device session.
#[derive(Debug)]
struct Adaptation {
    /// The user's quality.
    quality: u8,
    max_resolution_drop: u8,
    /// The current device session and its adapter.
    session: Option<(u32, VideoAdapter)>,
    /// The newest report fed to that adapter.
    report: Option<VideoReport>,
}

impl Adaptation {
    fn level(&self) -> StreamLevel {
        self.session.as_ref().map_or(
            StreamLevel {
                quality: self.quality,
                resolution_drop: 0,
            },
            |(_, adapter)| adapter.level(),
        )
    }

    /// The adapter of `session_id`; a fresh one at the user's quality if the session changed.
    fn adapter(&mut self, session_id: u32) -> io::Result<&mut VideoAdapter> {
        let current = match self.session.take() {
            Some(current) if current.0 == session_id => current,
            _ => {
                self.report = None;
                (
                    session_id,
                    VideoAdapter::new(self.quality, self.max_resolution_drop)?,
                )
            }
        };
        Ok(&mut self.session.insert(current).1)
    }

    fn sent(&mut self, sent: VideoSent) -> io::Result<()> {
        self.adapter(sent.session_id)?.frame_sent(sent.frame_id);
        Ok(())
    }

    fn report(&mut self, session_id: u32, report: VideoReport) -> io::Result<()> {
        self.adapter(session_id)?.report(&report);
        self.report = Some(report);
        Ok(())
    }

    fn end_session(&mut self) {
        self.session = None;
        self.report = None;
    }

    fn set_quality(&mut self, quality: u8) -> Result<(), EncodeError> {
        if let Some((_, adapter)) = &mut self.session {
            adapter
                .set_quality(quality)
                .map_err(|_| EncodeError::Quality(quality))?;
        } else if !(1..=100).contains(&quality) {
            return Err(EncodeError::Quality(quality));
        }
        self.quality = quality;
        Ok(())
    }

    fn info(&self) -> Option<AdaptInfo> {
        self.session
            .as_ref()
            .map(|(session_id, adapter)| AdaptInfo {
                session_id: *session_id,
                stats: adapter.stats(),
                report: self.report,
            })
    }
}

#[derive(Debug)]
struct Shared {
    stop: AtomicBool,
    sent: AtomicU64,
    unsent: AtomicU64,
    failed: AtomicU64,
    last: Mutex<(Option<LastSent>, Option<String>)>,
    /// Locked while the encoder's quality is set from it, so user and adapter changes apply
    /// in order.
    adapt: Mutex<Adaptation>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Encoder and sender threads for one stream. Stops on [`VideoPipeline::stop`] or drop.
pub struct VideoPipeline {
    worker: Option<Arc<JpegWorker>>,
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

impl VideoPipeline {
    /// Starts encoding frames from `frames` at `quality` (1–100) and sending them with `sender`.
    /// The adapter may lower the resolution by up to `max_resolution_drop` steps (0 = never).
    ///
    /// # Errors
    /// [`EncodeError`] for a bad quality or if a thread cannot start.
    pub fn start(
        frames: Arc<FrameSlot>,
        quality: u8,
        max_resolution_drop: u8,
        sender: VideoSender,
    ) -> Result<Self, EncodeError> {
        let worker = Arc::new(JpegWorker::start(frames, quality)?);
        let shared = Arc::new(Shared {
            stop: AtomicBool::new(false),
            sent: AtomicU64::new(0),
            unsent: AtomicU64::new(0),
            failed: AtomicU64::new(0),
            last: Mutex::new((None, None)),
            adapt: Mutex::new(Adaptation {
                quality,
                max_resolution_drop,
                session: None,
                report: None,
            }),
        });
        let thread = std::thread::Builder::new()
            .name("vcam-video-send".into())
            .spawn({
                let worker = worker.clone();
                let shared = shared.clone();
                move || run(&worker, &shared, sender)
            })
            .map_err(EncodeError::Spawn)?;
        Ok(Self {
            worker: Some(worker),
            shared,
            thread: Some(thread),
        })
    }

    /// Sets the user's JPEG quality (NET-VID-001). The encoder follows it from the next frame
    /// unless the adapter has lowered the stream (NET-VID-005); then the stream stays lowered,
    /// never above the new quality, and recovers towards it.
    ///
    /// # Errors
    /// [`EncodeError::Quality`] outside 1–100; the quality is unchanged.
    pub fn set_quality(&self, quality: u8) -> Result<(), EncodeError> {
        let mut adapt = lock(&self.shared.adapt);
        adapt.set_quality(quality)?;
        match &self.worker {
            Some(worker) => worker.set_quality(adapt.level().quality),
            None => Ok(()),
        }
    }

    #[must_use]
    pub fn stats(&self) -> VideoStats {
        let (encoder, quality, skipped) = self.worker.as_ref().map_or((None, 0, 0), |w| {
            (Some(w.stats()), w.quality(), w.output().replaced())
        });
        let (user_quality, adapt) = {
            let adapt = lock(&self.shared.adapt);
            (adapt.quality, adapt.info())
        };
        let last = lock(&self.shared.last);
        VideoStats {
            encoded: encoder.map_or(0, |s| s.encoded),
            encode_failed: encoder.map_or(0, |s| s.failed),
            encoded_skipped: skipped,
            sent: self.shared.sent.load(Ordering::Relaxed),
            unsent: self.shared.unsent.load(Ordering::Relaxed),
            send_failed: self.shared.failed.load(Ordering::Relaxed),
            quality,
            user_quality,
            adapt,
            last_sent: last.0,
            last_error: last.1.clone(),
        }
    }

    /// Stops and joins both threads (sender first, then encoder). Idempotent.
    pub fn stop(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
        if let Some(worker) = &self.worker {
            worker.output().wake();
        }
        if let Some(thread) = self.thread.take() {
            // The sender never panics by construction; either way its clone of the worker is
            // gone once it has exited.
            let _ = thread.join();
        }
        // The last reference: dropping it stops and joins the encoder thread.
        self.worker = None;
    }
}

impl Drop for VideoPipeline {
    fn drop(&mut self) {
        self.stop();
    }
}

fn wire_color(color: FrameColorSpace) -> u8 {
    match color {
        FrameColorSpace::SrgbRec709 => VideoFragment::COLOR_SRGB_REC709,
    }
}

fn nanos(d: Duration) -> u64 {
    u64::try_from(d.as_nanos()).unwrap_or(u64::MAX)
}

/// What became of one encoded frame.
enum Outcome {
    Sent(VideoSent),
    /// No device session with an authenticated source (or it changed part-way).
    NoSession,
    Failed,
}

fn run(worker: &JpegWorker, shared: &Shared, mut sender: VideoSender) {
    while !shared.stop.load(Ordering::Acquire) {
        let outcome = worker.output().wait_take(IDLE_WAIT).map(|frame| {
            let outcome = send(&mut sender, shared, &frame);
            worker.output().recycle(frame.jpeg);
            outcome
        });
        // Polled after every frame and every idle wait, so reports are taken while the
        // stream stalls too.
        let report = sender.video_report();
        let error = {
            let mut adapt = lock(&shared.adapt);
            let fed = match outcome {
                Some(Outcome::Sent(sent)) => adapt.sent(sent),
                Some(Outcome::NoSession) => {
                    adapt.end_session();
                    Ok(())
                }
                Some(Outcome::Failed) | None => Ok(()),
            }
            .and_then(|()| report.map_or(Ok(()), |(id, report)| adapt.report(id, report)));
            let applied = worker.set_quality(adapt.level().quality);
            fed.err()
                .map(|e| e.to_string())
                .or_else(|| applied.err().map(|e| e.to_string()))
        };
        if let Some(e) = error {
            lock(&shared.last).1 = Some(e);
        }
    }
}

fn send(sender: &mut VideoSender, shared: &Shared, frame: &EncodedFrame) -> Outcome {
    let meta = VideoFrameMeta {
        render_time_ns: frame.meta.render_time_ns,
        pose_seq: frame.meta.pose_seq,
        codec: VideoFragment::CODEC_JPEG,
        color: wire_color(frame.meta.color_space),
        quality: frame.quality,
    };
    let started = Instant::now();
    let result = sender.send(meta, &frame.jpeg);
    let send_ns = nanos(started.elapsed());
    let mut last = lock(&shared.last);
    match result {
        Ok(sent) => {
            shared.sent.fetch_add(1, Ordering::Relaxed);
            last.0 = Some(LastSent {
                source_frame_id: frame.frame_id,
                wire_frame_id: sent.frame_id,
                session_id: sent.session_id,
                pose_seq: frame.meta.pose_seq,
                render_time_ns: frame.meta.render_time_ns,
                width: frame.meta.width(),
                height: frame.meta.height(),
                quality: frame.quality,
                jpeg_bytes: frame.jpeg.len(),
                fragments: sent.fragments,
                encode_ns: frame.encode_ns,
                send_ns,
            });
            Outcome::Sent(sent)
        }
        Err(e) if e.kind() == io::ErrorKind::NotConnected => {
            shared.unsent.fetch_add(1, Ordering::Relaxed);
            Outcome::NoSession
        }
        Err(e) => {
            shared.failed.fetch_add(1, Ordering::Relaxed);
            last.1 = Some(e.to_string());
            Outcome::Failed
        }
    }
}

#[cfg(test)]
mod tests {
    use std::net::SocketAddr;

    use vcam_net::{ControlServer, MemoryStore, ServerConfig};
    use vcam_video::FrameMeta;

    use super::*;

    fn server() -> ControlServer {
        let bind: SocketAddr = "127.0.0.1:0".parse().unwrap();
        ControlServer::start(
            bind,
            ServerConfig::new([7; 16], 0),
            Box::new(MemoryStore::default()),
        )
        .unwrap()
    }

    fn submit(frames: &FrameSlot, pose_seq: u32) {
        let meta = FrameMeta::new(16, 8, pose_seq, 1).unwrap();
        frames
            .submit(meta, |dst: &mut [u8]| {
                dst.fill(128);
                Ok::<_, ()>(())
            })
            .unwrap();
    }

    fn wait_for(pipeline: &VideoPipeline, done: impl Fn(&VideoStats) -> bool) -> VideoStats {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let stats = pipeline.stats();
            if done(&stats) || Instant::now() > deadline {
                return stats;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    #[test]
    fn frames_without_a_device_are_unsent_not_failed() {
        let server = server();
        let frames = Arc::new(FrameSlot::new());
        let pipeline = VideoPipeline::start(frames.clone(), 70, 0, server.video_sender()).unwrap();
        submit(&frames, 3);
        let stats = wait_for(&pipeline, |s| s.unsent == 1);
        assert_eq!((stats.encoded, stats.unsent), (1, 1), "{stats:?}");
        assert_eq!((stats.sent, stats.send_failed), (0, 0), "{stats:?}");
        assert_eq!((stats.last_sent, stats.last_error), (None, None));
        assert_eq!((stats.quality, stats.user_quality), (70, 70));
        assert_eq!(stats.adapt, None, "no device session, no adapter");
    }

    #[test]
    fn stop_wakes_an_idle_sender_and_is_idempotent() {
        let server = server();
        let mut pipeline =
            VideoPipeline::start(Arc::new(FrameSlot::new()), 80, 0, server.video_sender()).unwrap();
        std::thread::sleep(Duration::from_millis(50)); // let both threads block
        let started = Instant::now();
        pipeline.stop();
        assert!(
            started.elapsed() < IDLE_WAIT / 2,
            "stop took {:?}",
            started.elapsed()
        );
        pipeline.stop();
        assert!(pipeline.set_quality(50).is_ok());
    }

    fn sent(session_id: u32, frame_id: u32) -> VideoSent {
        VideoSent {
            session_id,
            frame_id,
            fragments: 1,
        }
    }

    #[test]
    fn each_device_session_adapts_on_its_own_from_the_users_quality() {
        let mut a = Adaptation {
            quality: 80,
            max_resolution_drop: 1,
            session: None,
            report: None,
        };
        let level = |a: &Adaptation| (a.level().quality, a.level().resolution_drop);
        assert_eq!((level(&a), a.info()), ((80, 0), None));
        // Session 7: two intervals of 15 frames with 5 lost each lower the quality one step.
        for (seq, complete) in [(1, 10), (2, 20)] {
            for id in seq * 15 - 14..=seq * 15 {
                a.sent(sent(7, id)).unwrap();
            }
            let report = VideoReport {
                report_seq: seq,
                newest_frame_id: seq * 15,
                frames_complete: complete,
                m2p_p95_ms: 0,
            };
            a.report(7, report).unwrap();
        }
        assert_eq!(level(&a), (70, 0));
        let info = a.info().unwrap();
        assert_eq!((info.session_id, info.stats.changes), (7, 1));
        assert_eq!(info.report.map(|r| r.report_seq), Some(2));
        assert_eq!((info.stats.expected, info.stats.lost), (30, 10));
        // The user raises the quality: the lowered stream stays lowered.
        a.set_quality(90).unwrap();
        assert_eq!((a.quality, level(&a)), (90, (70, 0)));
        // A report of another session starts that session's adapter, at the user's quality.
        let other = VideoReport {
            report_seq: 1,
            newest_frame_id: 1,
            frames_complete: 1,
            m2p_p95_ms: 0,
        };
        a.report(9, other).unwrap();
        let info = a.info().unwrap();
        assert_eq!(
            (info.session_id, info.stats.changes, info.stats.expected),
            (9, 0, 0)
        );
        assert_eq!((info.report, level(&a)), (Some(other), (90, 0)));
        // So does a frame sent to a new session; its report isn't carried over.
        a.sent(sent(11, 1)).unwrap();
        assert_eq!(a.info().map(|i| (i.session_id, i.report)), Some((11, None)));
        a.end_session();
        assert_eq!((level(&a), a.info()), ((90, 0), None));
        assert!(matches!(a.set_quality(0), Err(EncodeError::Quality(0))));
        a.sent(sent(12, 1)).unwrap();
        assert!(matches!(a.set_quality(101), Err(EncodeError::Quality(101))));
        assert_eq!((a.quality, level(&a)), (90, (90, 0)));
    }
}
