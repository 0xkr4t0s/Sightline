//! Stage A video: JPEG encoding on a worker thread (task 2.2a; NET-VID-001, NET-VID-004).
//!
//! [`JpegWorker`] takes the newest frame from a [`FrameSlot`], encodes it with libjpeg-turbo
//! (4:2:0, the S-2a choice in SRS §13.2) and publishes it to an [`EncodedSlot`]. That slot is
//! newest-wins like the frame slot, so a slow consumer skips frames rather than queueing
//! them. Each encoded frame keeps the `frame_id`, `pose_seq`, `render_time_ns` and colour
//! encoding of the frame it came from. Pixel, flip and JPEG buffers are reused, so a steady
//! stream makes no Rust allocation per frame.

use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::frame::{BYTES_PER_PIXEL, Frame, FrameMeta, FrameSlot};

/// Default JPEG quality: 960×540 is 9–13 Mbit/s at 30 fps (SRS §13.2).
pub const DEFAULT_QUALITY: u8 = 80;

/// How long the worker sleeps between stop-flag checks when no frame arrives. Stopping wakes
/// it at once, so this only bounds a missed wake-up.
const IDLE_WAIT: Duration = Duration::from_millis(500);

/// Why a frame could not be encoded or the worker could not start.
#[derive(Debug)]
pub enum EncodeError {
    /// JPEG quality outside 1–100.
    Quality(u8),
    /// The pixel buffer is not `width × height × 4` bytes.
    Size,
    /// libjpeg-turbo refused the frame.
    Jpeg(turbojpeg::Error),
    /// The worker thread could not be spawned.
    Spawn(std::io::Error),
}

impl std::fmt::Display for EncodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Quality(q) => write!(f, "JPEG quality {q} is outside 1-100"),
            Self::Size => f.write_str("pixel buffer does not match the frame size"),
            Self::Jpeg(e) => write!(f, "JPEG encode failed: {e}"),
            Self::Spawn(e) => write!(f, "could not start the JPEG worker: {e}"),
        }
    }
}

impl std::error::Error for EncodeError {}

impl From<turbojpeg::Error> for EncodeError {
    fn from(e: turbojpeg::Error) -> Self {
        Self::Jpeg(e)
    }
}

fn checked_quality(quality: u8) -> Result<u8, EncodeError> {
    if (1..=100).contains(&quality) {
        Ok(quality)
    } else {
        Err(EncodeError::Quality(quality))
    }
}

/// Encodes bottom-up RGBA8 frames to upright 4:2:0 JPEG.
pub struct JpegEncoder {
    compressor: turbojpeg::Compressor,
    quality: u8,
    /// Top-down copy of the frame: the safe turbojpeg API has no bottom-up input.
    top_down: Vec<u8>,
}

impl JpegEncoder {
    /// # Errors
    /// [`EncodeError::Quality`] outside 1–100, or [`EncodeError::Jpeg`] if libjpeg-turbo
    /// can't create a compressor.
    pub fn new(quality: u8) -> Result<Self, EncodeError> {
        let quality = checked_quality(quality)?;
        let mut compressor = turbojpeg::Compressor::new()?;
        compressor.set_quality(i32::from(quality))?;
        compressor.set_subsamp(turbojpeg::Subsamp::Sub2x2)?;
        Ok(Self {
            compressor,
            quality,
            top_down: Vec::new(),
        })
    }

    #[must_use]
    pub fn quality(&self) -> u8 {
        self.quality
    }

    /// # Errors
    /// [`EncodeError::Quality`] outside 1–100 (the quality is unchanged), or
    /// [`EncodeError::Jpeg`].
    pub fn set_quality(&mut self, quality: u8) -> Result<(), EncodeError> {
        let quality = checked_quality(quality)?;
        if quality != self.quality {
            self.compressor.set_quality(i32::from(quality))?;
            self.quality = quality;
        }
        Ok(())
    }

    /// Replaces the contents of `out` with `frame` as an upright JPEG, reusing `out`'s
    /// allocation. On error `out` is left empty.
    ///
    /// # Errors
    /// [`EncodeError::Size`] if the pixels don't match the metadata, or [`EncodeError::Jpeg`].
    pub fn encode(&mut self, frame: &Frame, out: &mut Vec<u8>) -> Result<(), EncodeError> {
        out.clear();
        if frame.pixels.len() != frame.meta.byte_len() {
            return Err(EncodeError::Size);
        }
        let width = frame.meta.width() as usize;
        let height = frame.meta.height() as usize;
        let row = width * BYTES_PER_PIXEL;
        self.top_down.clear();
        for src in frame.pixels.chunks_exact(row).rev() {
            self.top_down.extend_from_slice(src);
        }
        out.resize(self.compressor.buf_len(width, height)?, 0);
        let image = turbojpeg::Image {
            pixels: self.top_down.as_slice(),
            width,
            pitch: row,
            height,
            format: turbojpeg::PixelFormat::RGBA,
        };
        match self.compressor.compress_to_slice(image, out) {
            Ok(len) => {
                out.truncate(len);
                Ok(())
            }
            Err(e) => {
                out.clear();
                Err(e.into())
            }
        }
    }
}

/// One encoded frame, with the metadata of the frame it came from (NET-VID-004).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedFrame {
    /// The source frame's [`Frame::frame_id`].
    pub frame_id: u64,
    /// Size, `pose_seq`, `render_time_ns` and colour encoding of the source frame.
    pub meta: FrameMeta,
    /// JPEG quality used.
    pub quality: u8,
    /// Time spent flipping and encoding, in ns.
    pub encode_ns: u64,
    /// Baseline JPEG (JFIF), rows top-down.
    pub jpeg: Vec<u8>,
}

#[derive(Debug, Default)]
struct EncodedState {
    latest: Option<EncodedFrame>,
    spare: Option<Vec<u8>>,
    replaced: u64,
}

/// Holds the newest encoded frame until the sender takes it. Shared between threads.
#[derive(Debug, Default)]
pub struct EncodedSlot {
    state: Mutex<EncodedState>,
    ready: Condvar,
}

impl EncodedSlot {
    fn lock(&self) -> MutexGuard<'_, EncodedState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn publish(&self, frame: EncodedFrame) {
        let mut state = self.lock();
        if let Some(old) = state.latest.replace(frame) {
            state.replaced += 1;
            state.spare = Some(old.jpeg);
        }
        drop(state);
        self.ready.notify_all();
    }

    fn take_spare(&self) -> Vec<u8> {
        self.lock().spare.take().unwrap_or_default()
    }

    /// The newest encoded frame, if one arrived since the last take.
    #[must_use]
    pub fn take(&self) -> Option<EncodedFrame> {
        self.lock().latest.take()
    }

    /// Like [`EncodedSlot::take`], but waits up to `timeout` for a frame.
    #[must_use]
    pub fn wait_take(&self, timeout: Duration) -> Option<EncodedFrame> {
        let (mut state, _) = self
            .ready
            .wait_timeout_while(self.lock(), timeout, |s| s.latest.is_none())
            .unwrap_or_else(PoisonError::into_inner);
        state.latest.take()
    }

    /// Hands a taken frame's JPEG buffer back for reuse.
    pub fn recycle(&self, jpeg: Vec<u8>) {
        self.lock().spare.get_or_insert(jpeg);
    }

    /// Encoded frames replaced before anyone took them.
    #[must_use]
    pub fn replaced(&self) -> u64 {
        self.lock().replaced
    }
}

/// Counters of a [`JpegWorker`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JpegWorkerStats {
    pub encoded: u64,
    pub failed: u64,
}

#[derive(Debug)]
struct Shared {
    stop: AtomicBool,
    quality: AtomicU8,
    encoded: AtomicU64,
    failed: AtomicU64,
    output: EncodedSlot,
}

/// Encodes frames from a [`FrameSlot`] on its own thread until stopped or dropped.
#[derive(Debug)]
pub struct JpegWorker {
    frames: Arc<FrameSlot>,
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

impl JpegWorker {
    /// Starts the worker thread.
    ///
    /// # Errors
    /// [`EncodeError::Quality`] outside 1–100, [`EncodeError::Jpeg`] if no compressor can be
    /// created, or [`EncodeError::Spawn`].
    pub fn start(frames: Arc<FrameSlot>, quality: u8) -> Result<Self, EncodeError> {
        let encoder = JpegEncoder::new(quality)?;
        let shared = Arc::new(Shared {
            stop: AtomicBool::new(false),
            quality: AtomicU8::new(quality),
            encoded: AtomicU64::new(0),
            failed: AtomicU64::new(0),
            output: EncodedSlot::default(),
        });
        let thread = std::thread::Builder::new()
            .name("vcam-jpeg".into())
            .spawn({
                let frames = frames.clone();
                let shared = shared.clone();
                move || run(&frames, &shared, encoder)
            })
            .map_err(EncodeError::Spawn)?;
        Ok(Self {
            frames,
            shared,
            thread: Some(thread),
        })
    }

    /// Where encoded frames appear.
    #[must_use]
    pub fn output(&self) -> &EncodedSlot {
        &self.shared.output
    }

    /// Sets the quality for the next frame (NET-VID-001 "quality adjustable").
    ///
    /// # Errors
    /// [`EncodeError::Quality`] outside 1–100; the quality is unchanged.
    pub fn set_quality(&self, quality: u8) -> Result<(), EncodeError> {
        let quality = checked_quality(quality)?;
        self.shared.quality.store(quality, Ordering::Relaxed);
        Ok(())
    }

    #[must_use]
    pub fn quality(&self) -> u8 {
        self.shared.quality.load(Ordering::Relaxed)
    }

    #[must_use]
    pub fn stats(&self) -> JpegWorkerStats {
        JpegWorkerStats {
            encoded: self.shared.encoded.load(Ordering::Relaxed),
            failed: self.shared.failed.load(Ordering::Relaxed),
        }
    }

    /// Stops and joins the thread. Idempotent; also runs on drop.
    pub fn stop(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
        self.frames.wake();
        if let Some(thread) = self.thread.take() {
            // A panic in the worker has already been reported by the panic hook; nothing
            // is left to clean up here.
            let _ = thread.join();
        }
    }
}

impl Drop for JpegWorker {
    fn drop(&mut self) {
        self.stop();
    }
}

fn run(frames: &FrameSlot, shared: &Shared, mut encoder: JpegEncoder) {
    while !shared.stop.load(Ordering::Acquire) {
        let Some(frame) = frames.wait_take(IDLE_WAIT) else {
            continue;
        };
        let mut jpeg = shared.output.take_spare();
        let started = Instant::now();
        let result = encoder
            .set_quality(shared.quality.load(Ordering::Relaxed))
            .and_then(|()| encoder.encode(&frame, &mut jpeg));
        let encode_ns = u64::try_from(started.elapsed().as_nanos()).unwrap_or(u64::MAX);
        match result {
            Ok(()) => {
                shared.output.publish(EncodedFrame {
                    frame_id: frame.frame_id,
                    meta: frame.meta,
                    quality: encoder.quality(),
                    encode_ns,
                    jpeg,
                });
                shared.encoded.fetch_add(1, Ordering::Relaxed);
            }
            Err(_) => {
                shared.output.recycle(jpeg);
                shared.failed.fetch_add(1, Ordering::Relaxed);
            }
        }
        frames.recycle(frame.pixels);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RED: [u8; 4] = [230, 20, 20, 255];
    const BLUE: [u8; 4] = [20, 20, 230, 255];

    /// A bottom-up frame whose upper half (as displayed) is red and lower half blue.
    fn split_frame(w: u32, h: u32, pose_seq: u32) -> (FrameMeta, Vec<u8>) {
        let meta = FrameMeta::new(w, h, pose_seq, u64::from(pose_seq) * 1000).unwrap();
        let mut pixels = Vec::with_capacity(meta.byte_len());
        for stored_row in 0..h {
            let colour = if stored_row < h / 2 { BLUE } else { RED };
            for _ in 0..w {
                pixels.extend_from_slice(&colour);
            }
        }
        (meta, pixels)
    }

    fn submit(slot: &FrameSlot, (meta, pixels): (FrameMeta, Vec<u8>)) -> u64 {
        slot.submit(meta, |dst: &mut [u8]| {
            dst.copy_from_slice(&pixels);
            Ok::<_, ()>(())
        })
        .unwrap()
    }

    fn near(pixel: &[u8], rgb: &[u8]) -> bool {
        pixel.iter().zip(rgb).all(|(a, b)| a.abs_diff(*b) <= 12)
    }

    /// Decoded RGB pixel at display position (x, y).
    fn rgb_at(image: &turbojpeg::Image<Vec<u8>>, x: usize, y: usize) -> &[u8] {
        &image.pixels[y * image.pitch + x * 3..][..3]
    }

    #[test]
    fn encodes_bottom_up_frames_upright() {
        let (meta, pixels) = split_frame(32, 16, 1);
        let frame = Frame {
            frame_id: 1,
            meta,
            pixels,
        };
        let mut encoder = JpegEncoder::new(95).unwrap();
        let mut out = Vec::new();
        encoder.encode(&frame, &mut out).unwrap();
        let image = turbojpeg::decompress(&out, turbojpeg::PixelFormat::RGB).unwrap();
        assert_eq!((image.width, image.height), (32, 16));
        assert!(near(rgb_at(&image, 16, 2), &RED[..3]), "top is red");
        assert!(near(rgb_at(&image, 16, 13), &BLUE[..3]), "bottom is blue");
    }

    #[test]
    fn quality_is_bounded_and_changes_the_output() {
        assert!(matches!(JpegEncoder::new(0), Err(EncodeError::Quality(0))));
        let mut encoder = JpegEncoder::new(30).unwrap();
        assert!(matches!(
            encoder.set_quality(101),
            Err(EncodeError::Quality(101))
        ));
        assert_eq!(encoder.quality(), 30, "a refused quality changes nothing");

        let meta = FrameMeta::new(64, 64, 1, 0).unwrap();
        let mut noise = 0x1234_5678_u32;
        let pixels = (0..meta.byte_len())
            .map(|_| {
                noise ^= noise << 13;
                noise ^= noise >> 17;
                noise ^= noise << 5;
                noise.to_le_bytes()[0]
            })
            .collect();
        let frame = Frame {
            frame_id: 1,
            meta,
            pixels,
        };
        let mut low = Vec::new();
        encoder.encode(&frame, &mut low).unwrap();
        encoder.set_quality(95).unwrap();
        let mut high = Vec::new();
        encoder.encode(&frame, &mut high).unwrap();
        assert!(low.len() < high.len(), "{} vs {}", low.len(), high.len());
    }

    #[test]
    fn refuses_pixels_that_do_not_match_the_size() {
        let frame = Frame {
            frame_id: 1,
            meta: FrameMeta::new(4, 4, 0, 0).unwrap(),
            pixels: vec![0; 60],
        };
        let mut out = vec![1, 2, 3];
        assert!(matches!(
            JpegEncoder::new(80).unwrap().encode(&frame, &mut out),
            Err(EncodeError::Size)
        ));
        assert!(out.is_empty());
    }

    #[test]
    fn encoded_slot_keeps_only_the_newest_frame() {
        let slot = EncodedSlot::default();
        let encoded = |frame_id, jpeg| EncodedFrame {
            frame_id,
            meta: FrameMeta::new(2, 2, 0, 0).unwrap(),
            quality: 80,
            encode_ns: 0,
            jpeg,
        };
        slot.publish(encoded(1, vec![1; 64]));
        slot.publish(encoded(2, vec![2]));
        assert_eq!(slot.replaced(), 1);
        assert_eq!(slot.take().map(|f| f.frame_id), Some(2));
        assert_eq!(slot.take(), None);
        assert_eq!(slot.take_spare().capacity(), 64, "replaced buffer reused");
    }

    #[test]
    fn worker_encodes_with_the_source_metadata_and_current_quality() {
        let frames = Arc::new(FrameSlot::new());
        let worker = JpegWorker::start(frames.clone(), DEFAULT_QUALITY).unwrap();
        let id = submit(&frames, split_frame(32, 16, 7));
        let first = worker.output().wait_take(Duration::from_secs(5)).unwrap();
        assert_eq!(first.frame_id, id);
        assert_eq!((first.meta.pose_seq, first.meta.render_time_ns), (7, 7000));
        assert_eq!(first.meta.color_space, crate::FrameColorSpace::SrgbRec709);
        assert_eq!(first.quality, DEFAULT_QUALITY);
        let image = turbojpeg::decompress(&first.jpeg, turbojpeg::PixelFormat::RGB).unwrap();
        assert!(near(rgb_at(&image, 16, 2), &RED[..3]));

        assert!(matches!(
            worker.set_quality(0),
            Err(EncodeError::Quality(0))
        ));
        worker.set_quality(40).unwrap();
        worker.output().recycle(first.jpeg);
        submit(&frames, split_frame(32, 16, 8));
        let second = worker.output().wait_take(Duration::from_secs(5)).unwrap();
        assert_eq!((second.meta.pose_seq, second.quality), (8, 40));
        assert_eq!(
            worker.stats(),
            JpegWorkerStats {
                encoded: 2,
                failed: 0
            }
        );
    }

    #[test]
    fn stop_wakes_an_idle_worker() {
        let frames = Arc::new(FrameSlot::new());
        let mut worker = JpegWorker::start(frames, DEFAULT_QUALITY).unwrap();
        std::thread::sleep(Duration::from_millis(50)); // let it block in wait_take
        let started = Instant::now();
        worker.stop();
        assert!(
            started.elapsed() < IDLE_WAIT / 2,
            "stop took {:?}",
            started.elapsed()
        );
        worker.stop();
    }
}
