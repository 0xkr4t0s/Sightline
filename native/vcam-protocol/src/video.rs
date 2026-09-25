//! `VIDEO_FRAGMENT` (vcp.md §6.5): the fragment payload, its validation, and the device-side
//! reassembler (newest frame wins, NET-VID-001). The host-side split is `Endpoint::seal_frame`.

use crate::message::PayloadError;
use crate::wire::Reader;

/// Fixed part of a `VIDEO_FRAGMENT` payload, before `data`.
pub const VIDEO_HEADER_LEN: usize = 28;
/// Largest `chunk_len`: 12 + 28 + 1152 + 8 = 1200 bytes (vcp.md §3).
pub const MAX_CHUNK_LEN: u16 = 1152;
/// Largest encoded frame (4 MiB).
pub const MAX_FRAME_LEN: u32 = 4 * 1024 * 1024;
/// Largest number of fragments per frame (`frag_index` is a u16).
pub const MAX_FRAGMENTS: u32 = 1 << 16;

/// `VIDEO_FRAGMENT.codec` values.
pub mod video_codec {
    /// Baseline JPEG, one per frame (Stage A, NET-VID-001).
    pub const JPEG: u8 = 0;
    /// H.264 Annex B access unit (reserved for T3, NET-VID-002).
    pub const H264: u8 = 1;
}

/// The per-frame fields every fragment of a frame repeats (vcp.md §6.5).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FrameInfo {
    /// +1 per frame sent in the session, from 1. Never 0.
    pub frame_id: u32,
    /// Host clock when Blender rendered the frame (NET-VID-004).
    pub render_time_ns: u64,
    /// `POSE.seq` the frame was rendered from (0 = none).
    pub pose_seq: u32,
    pub codec: u8,
    /// Bit 0: keyframe (always set for JPEG).
    pub flags: u8,
}

impl FrameInfo {
    pub const KEYFRAME: u8 = 1 << 0;
}

/// One `VIDEO_FRAGMENT` (0x05).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VideoFragment {
    pub frame: FrameInfo,
    /// Length of the whole encoded frame.
    pub frame_len: u32,
    /// Bytes in every fragment of the frame except the last.
    pub chunk_len: u16,
    pub frag_index: u16,
    /// Bytes `frag_index * chunk_len ..` of the encoded frame.
    pub data: Vec<u8>,
}

/// `⌈frame_len / chunk_len⌉` if both are in range and the count fits (vcp.md §6.5).
#[must_use]
pub fn fragment_count(frame_len: u32, chunk_len: u16) -> Option<u32> {
    if !(1..=MAX_FRAME_LEN).contains(&frame_len) || !(1..=MAX_CHUNK_LEN).contains(&chunk_len) {
        return None;
    }
    Some(frame_len.div_ceil(u32::from(chunk_len))).filter(|&n| n <= MAX_FRAGMENTS)
}

/// The `data` length fragment `index` must carry, or `None` if the layout is invalid.
fn expected_len(frame_len: u32, chunk_len: u16, index: u16) -> Option<usize> {
    let count = fragment_count(frame_len, chunk_len)?;
    let index = u32::from(index);
    if index >= count {
        return None;
    }
    let len = if index + 1 < count {
        u32::from(chunk_len)
    } else {
        frame_len - (count - 1) * u32::from(chunk_len)
    };
    usize::try_from(len).ok()
}

fn check(frame: &FrameInfo, frame_len: u32, chunk_len: u16, index: u16, data_len: usize) -> bool {
    frame.frame_id != 0 && expected_len(frame_len, chunk_len, index) == Some(data_len)
}

/// Writes one fragment payload. The caller has validated the layout.
pub(crate) fn put_fragment(
    out: &mut Vec<u8>,
    frame: &FrameInfo,
    frame_len: u32,
    chunk_len: u16,
    index: u16,
    data: &[u8],
) {
    out.extend_from_slice(&frame.frame_id.to_le_bytes());
    out.extend_from_slice(&frame.render_time_ns.to_le_bytes());
    out.extend_from_slice(&frame.pose_seq.to_le_bytes());
    out.extend_from_slice(&frame_len.to_le_bytes());
    out.extend_from_slice(&index.to_le_bytes());
    out.extend_from_slice(&chunk_len.to_le_bytes());
    out.extend_from_slice(&[frame.codec, frame.flags, 0, 0]);
    out.extend_from_slice(data);
}

impl VideoFragment {
    /// Smallest valid payload: the fixed part plus one data byte.
    pub const MIN_LEN: usize = VIDEO_HEADER_LEN + 1;

    /// Decodes and validates one payload (vcp.md §6.5). Bounds-checked; never panics.
    pub fn decode(payload: &[u8]) -> Result<Self, PayloadError> {
        if payload.len() < Self::MIN_LEN {
            return Err(PayloadError::TooShort);
        }
        let mut r = Reader::new(payload);
        let (frame_id, render_time_ns, pose_seq, frame_len, frag_index, chunk_len, codec, flags) =
            (|| {
                let fields = (
                    r.u32()?,
                    r.u64()?,
                    r.u32()?,
                    r.u32()?,
                    r.u16()?,
                    r.u16()?,
                    r.u8()?,
                    r.u8()?,
                );
                r.u16()?; // reserved
                Some(fields)
            })()
            .ok_or(PayloadError::TooShort)?;
        let data = payload
            .get(VIDEO_HEADER_LEN..)
            .ok_or(PayloadError::TooShort)?;
        let frame = FrameInfo {
            frame_id,
            render_time_ns,
            pose_seq,
            codec,
            flags,
        };
        if !check(&frame, frame_len, chunk_len, frag_index, data.len()) {
            return Err(PayloadError::FragmentLayout);
        }
        Ok(Self {
            frame,
            frame_len,
            chunk_len,
            frag_index,
            data: data.to_vec(),
        })
    }

    /// Appends the payload. Fails if the fields break the §6.5 layout rules.
    pub fn encode(&self, out: &mut Vec<u8>) -> Result<(), PayloadError> {
        if !self.is_valid() {
            return Err(PayloadError::FragmentLayout);
        }
        put_fragment(
            out,
            &self.frame,
            self.frame_len,
            self.chunk_len,
            self.frag_index,
            &self.data,
        );
        Ok(())
    }

    fn is_valid(&self) -> bool {
        check(
            &self.frame,
            self.frame_len,
            self.chunk_len,
            self.frag_index,
            self.data.len(),
        )
    }
}

/// A reassembled frame, ready for the decoder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VideoFrame {
    pub info: FrameInfo,
    /// The encoded frame (`frame_len` bytes).
    pub data: Vec<u8>,
}

/// What [`Reassembler::push`] did with one fragment (vcp.md §6.5 reassembly steps).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FragmentOutcome {
    /// Stored; the frame still has missing fragments.
    Pending,
    /// The last missing fragment: here is the whole frame.
    Complete(VideoFrame),
    /// Belongs to a frame that is finished, abandoned, or older than the one in progress.
    Stale,
    /// This index was already received.
    Duplicate,
    /// Its frame fields disagree with the frame in progress, which is dropped.
    Inconsistent,
    /// Breaks the §6.5 layout rules (only possible for a fragment that wasn't decoded).
    Invalid,
}

/// Counters for the viewfinder stats (NET-VID-005).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ReassemblyStats {
    pub complete: u64,
    /// Frames dropped incomplete because a newer frame started.
    pub abandoned: u64,
    pub inconsistent: u64,
    pub stale: u64,
    pub duplicate: u64,
}

#[derive(Debug)]
struct Partial {
    info: FrameInfo,
    frame_len: u32,
    chunk_len: u16,
    received: Vec<bool>,
    missing: u32,
    data: Vec<u8>,
}

/// Device-side reassembly for one session: at most one frame in progress, and a newer frame
/// abandons an incomplete older one (NET-VID-001). Create a new one per session.
#[derive(Debug, Default)]
pub struct Reassembler {
    /// Fragments with `frame_id <= floor` are stale.
    floor: u32,
    current: Option<Partial>,
    stats: ReassemblyStats,
}

impl Reassembler {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn stats(&self) -> ReassemblyStats {
        self.stats
    }

    /// Feeds one authenticated fragment (vcp.md §6.5 reassembly steps 1–6).
    pub fn push(&mut self, frag: &VideoFragment) -> FragmentOutcome {
        if !frag.is_valid() {
            return FragmentOutcome::Invalid;
        }
        let id = frag.frame.frame_id;
        let current_id = self.current.as_ref().map(|p| p.info.frame_id);
        if id <= self.floor || current_id.is_some_and(|c| id < c) {
            self.stats.stale += 1;
            return FragmentOutcome::Stale;
        }
        if let Some(c) = current_id
            && id > c
        {
            self.stats.abandoned += 1;
            self.floor = c;
            self.current = None;
        }
        let partial = match &mut self.current {
            Some(p) => {
                if p.info != frag.frame
                    || p.frame_len != frag.frame_len
                    || p.chunk_len != frag.chunk_len
                {
                    self.stats.inconsistent += 1;
                    self.floor = id;
                    self.current = None;
                    return FragmentOutcome::Inconsistent;
                }
                p
            }
            None => self.current.insert(Partial::start(frag)),
        };
        let index = usize::from(frag.frag_index);
        match partial.received.get_mut(index) {
            Some(true) => {
                self.stats.duplicate += 1;
                return FragmentOutcome::Duplicate;
            }
            Some(seen) => *seen = true,
            None => return FragmentOutcome::Invalid,
        }
        let offset = index * usize::from(partial.chunk_len);
        let Some(dst) = partial.data.get_mut(offset..offset + frag.data.len()) else {
            return FragmentOutcome::Invalid;
        };
        dst.copy_from_slice(&frag.data);
        partial.missing -= 1;
        if partial.missing > 0 {
            return FragmentOutcome::Pending;
        }
        self.floor = id;
        self.stats.complete += 1;
        match self.current.take() {
            Some(p) => FragmentOutcome::Complete(VideoFrame {
                info: p.info,
                data: p.data,
            }),
            None => FragmentOutcome::Invalid,
        }
    }
}

impl Partial {
    /// `frag` is valid, so the count and length fit their limits (≤ 65536, ≤ 4 MiB).
    fn start(frag: &VideoFragment) -> Self {
        let count = fragment_count(frag.frame_len, frag.chunk_len).unwrap_or(1);
        Self {
            info: frag.frame,
            frame_len: frag.frame_len,
            chunk_len: frag.chunk_len,
            received: vec![false; usize::try_from(count).unwrap_or(1)],
            missing: count,
            data: vec![0; usize::try_from(frag.frame_len).unwrap_or(0)],
        }
    }
}
