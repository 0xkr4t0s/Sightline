//! Stage A viewfinder pipeline behind `vcam_native.Session.start_video` (task 2.2c2a;
//! NET-VID-001, NET-VID-004).
//!
//! Two threads, neither touching Python: [`JpegWorker`] encodes the newest frame of the
//! renderer's [`FrameSlot`], and `vcam-video-send` hands the newest encoded frame to the
//! session's [`VideoSender`], which splits it into `VIDEO_FRAGMENT`s (vcp.md §6.5). Both hand-offs
//! are newest-wins, so a slow stage skips frames instead of queueing them. Until a device
//! session has an authenticated UDP source, frames are counted as unsent and dropped.

use std::io;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use vcam_net::{VideoFrameMeta, VideoSender};
use vcam_protocol::VideoFragment;
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
    pub quality: u8,
    pub last_sent: Option<LastSent>,
    pub last_error: Option<String>,
}

#[derive(Debug, Default)]
struct Shared {
    stop: AtomicBool,
    sent: AtomicU64,
    unsent: AtomicU64,
    failed: AtomicU64,
    last: Mutex<(Option<LastSent>, Option<String>)>,
}

/// Encoder and sender threads for one stream. Stops on [`VideoPipeline::stop`] or drop.
pub struct VideoPipeline {
    worker: Option<Arc<JpegWorker>>,
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

impl VideoPipeline {
    /// Starts encoding frames from `frames` at `quality` (1–100) and sending them with `sender`.
    ///
    /// # Errors
    /// [`EncodeError`] for a bad quality or if a thread cannot start.
    pub fn start(
        frames: Arc<FrameSlot>,
        quality: u8,
        sender: VideoSender,
    ) -> Result<Self, EncodeError> {
        let worker = Arc::new(JpegWorker::start(frames, quality)?);
        let shared = Arc::new(Shared::default());
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

    /// Sets the JPEG quality for the next frame (NET-VID-001).
    ///
    /// # Errors
    /// [`EncodeError::Quality`] outside 1–100; the quality is unchanged.
    pub fn set_quality(&self, quality: u8) -> Result<(), EncodeError> {
        match &self.worker {
            Some(worker) => worker.set_quality(quality),
            None => Ok(()),
        }
    }

    #[must_use]
    pub fn stats(&self) -> VideoStats {
        let (encoder, quality, skipped) = self.worker.as_ref().map_or((None, 0, 0), |w| {
            (Some(w.stats()), w.quality(), w.output().replaced())
        });
        let last = self
            .shared
            .last
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        VideoStats {
            encoded: encoder.map_or(0, |s| s.encoded),
            encode_failed: encoder.map_or(0, |s| s.failed),
            encoded_skipped: skipped,
            sent: self.shared.sent.load(Ordering::Relaxed),
            unsent: self.shared.unsent.load(Ordering::Relaxed),
            send_failed: self.shared.failed.load(Ordering::Relaxed),
            quality,
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

fn run(worker: &JpegWorker, shared: &Shared, mut sender: VideoSender) {
    while !shared.stop.load(Ordering::Acquire) {
        let Some(frame) = worker.output().wait_take(IDLE_WAIT) else {
            continue;
        };
        send(&mut sender, shared, &frame);
        worker.output().recycle(frame.jpeg);
    }
}

fn send(sender: &mut VideoSender, shared: &Shared, frame: &EncodedFrame) {
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
    let mut last = shared.last.lock().unwrap_or_else(PoisonError::into_inner);
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
        }
        Err(e) if e.kind() == io::ErrorKind::NotConnected => {
            shared.unsent.fetch_add(1, Ordering::Relaxed);
        }
        Err(e) => {
            shared.failed.fetch_add(1, Ordering::Relaxed);
            last.1 = Some(e.to_string());
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
        let pipeline = VideoPipeline::start(frames.clone(), 70, server.video_sender()).unwrap();
        submit(&frames, 3);
        let stats = wait_for(&pipeline, |s| s.unsent == 1);
        assert_eq!((stats.encoded, stats.unsent), (1, 1), "{stats:?}");
        assert_eq!((stats.sent, stats.send_failed), (0, 0), "{stats:?}");
        assert_eq!((stats.last_sent, stats.last_error), (None, None));
        assert_eq!(stats.quality, 70);
    }

    #[test]
    fn stop_wakes_an_idle_sender_and_is_idempotent() {
        let server = server();
        let mut pipeline =
            VideoPipeline::start(Arc::new(FrameSlot::new()), 80, server.video_sender()).unwrap();
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
}
