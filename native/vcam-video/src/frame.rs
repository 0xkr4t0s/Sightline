//! Latest-frame slot between Blender's main thread and the encoder (task 2.1a; FR-REN-003,
//! C-5).
//!
//! The renderer submits each read-back frame once. [`FrameSlot::submit`] copies it into a
//! buffer the slot owns, and that copy is the only one on the Python side (SRS §13.1). The
//! encoder takes the newest frame. A frame the encoder hasn't taken yet is replaced (the
//! stream skips it rather than queueing), and its buffer is reused, so a steady stream
//! allocates nothing per frame.
//!
//! Pixels are RGBA8 as GPUTexture.read() returns them: rows bottom-up, with Blender's
//! viewport display transform applied into sRGB (Rec.709 primaries).

use std::sync::{Mutex, MutexGuard, PoisonError};

/// Bytes per RGBA8 pixel.
pub const BYTES_PER_PIXEL: usize = 4;

/// Display-referred colour encoding of a submitted frame, for the future encoder.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameColorSpace {
    /// sRGB transfer curve and Rec.709 primaries, after Blender's viewport transform/look.
    SrgbRec709,
}

impl FrameColorSpace {
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::SrgbRec709 => "sRGB/Rec.709",
        }
    }
}

/// Why a frame was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameError {
    /// Width or height is zero.
    Empty,
    /// `width × height × 4` does not fit in `usize`.
    TooLarge,
}

impl std::fmt::Display for FrameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Empty => f.write_str("frame width and height must be non-zero"),
            Self::TooLarge => f.write_str("frame is too large"),
        }
    }
}

impl std::error::Error for FrameError {}

/// What a frame shows, captured when it was drawn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameMeta {
    width: u32,
    height: u32,
    /// `seq` of the pose on the camera when the frame was drawn (0 = none).
    pub pose_seq: u32,
    /// Host clock (`vcam_net` host clock, ns) when the frame was drawn.
    pub render_time_ns: u64,
    /// Colour encoding of pixels; the Blender renderer supplies sRGB/Rec.709.
    pub color_space: FrameColorSpace,
}

impl FrameMeta {
    /// # Errors
    /// [`FrameError`] if a dimension is zero or the RGBA8 size overflows `usize`.
    pub fn new(
        width: u32,
        height: u32,
        pose_seq: u32,
        render_time_ns: u64,
    ) -> Result<Self, FrameError> {
        if width == 0 || height == 0 {
            return Err(FrameError::Empty);
        }
        usize::try_from(width)
            .ok()
            .zip(usize::try_from(height).ok())
            .and_then(|(w, h)| w.checked_mul(h)?.checked_mul(BYTES_PER_PIXEL))
            .ok_or(FrameError::TooLarge)?;
        Ok(Self {
            width,
            height,
            pose_seq,
            render_time_ns,
            color_space: FrameColorSpace::SrgbRec709,
        })
    }

    #[must_use]
    pub fn width(&self) -> u32 {
        self.width
    }

    #[must_use]
    pub fn height(&self) -> u32 {
        self.height
    }

    /// RGBA8 size in bytes (checked in [`FrameMeta::new`]).
    #[must_use]
    pub fn byte_len(&self) -> usize {
        self.width as usize * self.height as usize * BYTES_PER_PIXEL
    }
}

/// One submitted frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    /// 1 for the slot's first frame, +1 per accepted submit.
    pub frame_id: u64,
    pub meta: FrameMeta,
    /// RGBA8, `meta.byte_len()` bytes, rows bottom-up.
    pub pixels: Vec<u8>,
}

#[derive(Debug, Default)]
struct State {
    latest: Option<Frame>,
    spare: Option<Vec<u8>>,
    last_id: u64,
    replaced: u64,
}

/// Holds the newest frame until the encoder takes it. Shared between threads.
#[derive(Debug, Default)]
pub struct FrameSlot {
    state: Mutex<State>,
}

impl FrameSlot {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Stores a new frame: `fill` writes exactly `meta.byte_len()` bytes into a slot buffer (the one
    /// copy). The copy runs outside the lock, so the encoder never waits for it. If `fill`
    /// fails, nothing is published, the previous frame stays, and the error is returned.
    ///
    /// Returns the new `frame_id`.
    ///
    /// # Errors
    /// Whatever `fill` returns.
    pub fn submit<E>(
        &self,
        meta: FrameMeta,
        fill: impl FnOnce(&mut [u8]) -> Result<(), E>,
    ) -> Result<u64, E> {
        let mut buf = self.lock().spare.take().unwrap_or_default();
        buf.resize(meta.byte_len(), 0);
        if let Err(e) = fill(&mut buf) {
            self.lock().spare = Some(buf);
            return Err(e);
        }
        let mut state = self.lock();
        state.last_id += 1;
        let frame = Frame {
            frame_id: state.last_id,
            meta,
            pixels: buf,
        };
        if let Some(old) = state.latest.replace(frame) {
            state.replaced += 1;
            state.spare = Some(old.pixels);
        }
        Ok(state.last_id)
    }

    /// The newest frame, if one arrived since the last `take`.
    #[must_use]
    pub fn take(&self) -> Option<Frame> {
        self.lock().latest.take()
    }

    /// Hands a taken frame's buffer back for reuse.
    pub fn recycle(&self, pixels: Vec<u8>) {
        self.lock().spare.get_or_insert(pixels);
    }

    /// Frames replaced before anyone took them (skipped by the stream).
    #[must_use]
    pub fn replaced(&self) -> u64 {
        self.lock().replaced
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn meta(w: u32, h: u32, pose_seq: u32) -> FrameMeta {
        FrameMeta::new(w, h, pose_seq, u64::from(pose_seq) * 1000).unwrap()
    }

    fn fill_with(byte: u8) -> impl FnOnce(&mut [u8]) -> Result<(), ()> {
        move |dst| {
            dst.fill(byte);
            Ok(())
        }
    }

    #[test]
    fn refuses_empty_and_overflowing_sizes() {
        assert_eq!(FrameMeta::new(0, 540, 0, 0), Err(FrameError::Empty));
        assert_eq!(FrameMeta::new(960, 0, 0, 0), Err(FrameError::Empty));
        let (w, h) = (u32::MAX, u32::MAX);
        let fits = (w as usize)
            .checked_mul(h as usize)
            .and_then(|n| n.checked_mul(4))
            .is_some();
        assert_eq!(FrameMeta::new(w, h, 0, 0).is_err(), !fits);
        assert_eq!(meta(960, 540, 0).byte_len(), 960 * 540 * 4);
    }

    #[test]
    fn newest_frame_wins_and_carries_its_own_metadata() {
        let slot = FrameSlot::new();
        assert_eq!(slot.take(), None);
        assert_eq!(slot.submit(meta(2, 1, 7), fill_with(1)), Ok(1));
        assert_eq!(slot.submit(meta(4, 2, 8), fill_with(2)), Ok(2));
        assert_eq!(slot.replaced(), 1);
        let frame = slot.take().unwrap();
        assert_eq!(frame.frame_id, 2);
        assert_eq!(frame.meta, meta(4, 2, 8));
        assert_eq!(frame.pixels, vec![2; 4 * 2 * 4]);
        assert_eq!(slot.take(), None, "a frame is taken once");
        assert_eq!(slot.submit(meta(2, 1, 9), fill_with(3)), Ok(3));
        assert_eq!(
            slot.replaced(),
            1,
            "a taken frame is not counted as replaced"
        );
    }

    #[test]
    fn fill_gets_exactly_the_frame_size_even_from_a_larger_reused_buffer() {
        let slot = FrameSlot::new();
        slot.submit(meta(8, 8, 1), fill_with(9)).unwrap();
        slot.submit(meta(8, 8, 2), fill_with(9)).unwrap(); // the first buffer becomes the spare
        let mut seen = 0;
        slot.submit(meta(2, 2, 3), |dst: &mut [u8]| {
            seen = dst.len();
            dst.fill(5);
            Ok::<_, ()>(())
        })
        .unwrap();
        assert_eq!(seen, 2 * 2 * 4);
        assert_eq!(slot.take().unwrap().pixels, vec![5; 16]);
    }

    #[test]
    fn failed_fill_publishes_nothing_and_keeps_the_previous_frame() {
        let slot = FrameSlot::new();
        slot.submit(meta(2, 1, 1), fill_with(1)).unwrap();
        assert_eq!(
            slot.submit(meta(2, 1, 2), |_: &mut [u8]| Err("copy failed")),
            Err("copy failed")
        );
        assert_eq!(slot.replaced(), 0);
        let frame = slot.take().unwrap();
        assert_eq!(
            (frame.frame_id, frame.meta.pose_seq, frame.pixels[0]),
            (1, 1, 1)
        );
        assert_eq!(
            slot.submit(meta(2, 1, 3), fill_with(3)),
            Ok(2),
            "ids stay dense after a failure"
        );
    }

    #[test]
    fn replaced_and_recycled_buffers_are_reused() {
        let slot = FrameSlot::new();
        slot.submit(meta(64, 64, 1), fill_with(1)).unwrap();
        let first = slot.take().unwrap().pixels;
        let ptr = first.as_ptr();
        slot.recycle(first);
        slot.submit(meta(64, 64, 2), fill_with(2)).unwrap();
        assert_eq!(
            slot.take().unwrap().pixels.as_ptr(),
            ptr,
            "recycled buffer reused"
        );

        slot.submit(meta(64, 64, 3), fill_with(3)).unwrap();
        let replaced = slot.lock().latest.as_ref().unwrap().pixels.as_ptr();
        slot.submit(meta(64, 64, 4), fill_with(4)).unwrap();
        slot.submit(meta(64, 64, 5), fill_with(5)).unwrap();
        assert_eq!(
            slot.take().unwrap().pixels.as_ptr(),
            replaced,
            "replaced buffer reused"
        );
    }

    #[test]
    fn a_consumer_thread_sees_complete_frames_only() {
        let slot = std::sync::Arc::new(FrameSlot::new());
        let producer = {
            let slot = slot.clone();
            std::thread::spawn(move || {
                for i in 1..=500u32 {
                    let byte = (i % 251) as u8;
                    slot.submit(meta(32, 32, i), fill_with(byte)).unwrap();
                }
            })
        };
        let mut last = 0;
        while !producer.is_finished() || last < 500 {
            if let Some(frame) = slot.take() {
                assert!(frame.frame_id > last, "ids only increase");
                last = frame.frame_id;
                let byte = (frame.meta.pose_seq % 251) as u8;
                assert!(
                    frame.pixels.iter().all(|&b| b == byte),
                    "frame {last} is torn"
                );
                slot.recycle(frame.pixels);
            }
        }
        producer.join().unwrap();
    }
}
