//! `VIDEO_FRAGMENT` (`docs/protocol/vcp.md` §6.5): the fragment codec, the host's split of an
//! encoded frame, and the device's newest-frame-wins reassembly (NET-VID-001, NET-VID-004).

use crate::message::PayloadError;
use crate::wire::Reader;

/// The fields every fragment of one frame repeats (vcp.md §6.5).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VideoFrameInfo {
    /// Strictly increasing within the session, starting at 1; gaps are allowed.
    pub frame_id: u32,
    /// Host clock when Blender drew the frame.
    pub render_time_ns: u64,
    /// `POSE.seq` on the camera when the frame was drawn (0 = none).
    pub pose_seq: u32,
    /// [`VideoFragment::CODEC_JPEG`] in Stage A.
    pub codec: u8,
    /// [`VideoFragment::COLOR_SRGB_REC709`].
    pub color: u8,
    /// JPEG quality 1–100 for display (NET-VID-005); 0 = not stated.
    pub quality: u8,
    /// Reserved, 0.
    pub flags: u8,
}

/// `VIDEO_FRAGMENT` (0x05): one datagram's share of an encoded frame. `data` borrows from the
/// datagram (receive) or the encoded frame (send), so neither direction copies it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VideoFragment<'a> {
    pub frame: VideoFrameInfo,
    /// Encoded frame size in bytes.
    pub frame_len: u32,
    pub frag_index: u16,
    pub frag_count: u16,
    /// Data bytes in every fragment except possibly the last.
    pub frag_size: u16,
    /// Bytes `frag_index × frag_size` onward of the encoded frame.
    pub data: &'a [u8],
}

impl<'a> VideoFragment<'a> {
    /// Fixed fields before `data`.
    pub const HEADER_LEN: usize = 32;
    /// Largest `frag_size`: what fits a 1200-byte datagram after header, tag and fields.
    pub const MAX_DATA: usize = 1148;
    /// Largest encoded frame (4 MiB); a receiver never buffers more.
    pub const MAX_FRAME_LEN: u32 = 4 * 1024 * 1024;
    pub const CODEC_JPEG: u8 = 1;
    pub const COLOR_SRGB_REC709: u8 = 0;

    /// Decodes and validates one payload (vcp.md §6.5 Validation). Bytes after `data` are ignored.
    pub fn decode(payload: &'a [u8]) -> Result<Self, PayloadError> {
        let mut r = Reader::new(payload);
        let fields = (|| {
            Some((
                (r.u32()?, r.u32()?, r.u16()?, r.u16()?, r.u16()?),
                (
                    r.u8()?,
                    r.u8()?,
                    r.u64()?,
                    r.u32()?,
                    r.u8()?,
                    r.u8()?,
                    r.u16()?,
                ),
            ))
        })();
        let (
            (frame_id, frame_len, frag_index, frag_count, frag_size),
            (codec, color, render_time_ns, pose_seq, quality, flags, _reserved),
        ) = fields.ok_or(PayloadError::TooShort)?;
        let frame = VideoFrameInfo {
            frame_id,
            render_time_ns,
            pose_seq,
            codec,
            color,
            quality,
            flags,
        };
        let data_len = data_len(&frame, frame_len, frag_index, frag_count, frag_size)?;
        let data = r.bytes(data_len).ok_or(PayloadError::TooShort)?;
        Ok(Self {
            frame,
            frame_len,
            frag_index,
            frag_count,
            frag_size,
            data,
        })
    }

    /// Fails unless the fragment is one a receiver would accept, `data` length included.
    pub(crate) fn encode(&self, out: &mut Vec<u8>) -> Result<(), PayloadError> {
        let want = data_len(
            &self.frame,
            self.frame_len,
            self.frag_index,
            self.frag_count,
            self.frag_size,
        )?;
        if self.data.len() != want {
            return Err(PayloadError::FragmentLayout);
        }
        let f = &self.frame;
        out.extend_from_slice(&f.frame_id.to_le_bytes());
        out.extend_from_slice(&self.frame_len.to_le_bytes());
        out.extend_from_slice(&self.frag_index.to_le_bytes());
        out.extend_from_slice(&self.frag_count.to_le_bytes());
        out.extend_from_slice(&self.frag_size.to_le_bytes());
        out.extend_from_slice(&[f.codec, f.color]);
        out.extend_from_slice(&f.render_time_ns.to_le_bytes());
        out.extend_from_slice(&f.pose_seq.to_le_bytes());
        out.extend_from_slice(&[f.quality, f.flags, 0, 0]);
        out.extend_from_slice(self.data);
        Ok(())
    }

    /// The fields that must match across one frame's fragments (all but index and data).
    fn frame_key(&self) -> FrameKey {
        (self.frame, self.frame_len, self.frag_count, self.frag_size)
    }
}

type FrameKey = (VideoFrameInfo, u32, u16, u16);

/// Data bytes a fragment with these fields carries, or why the fields are invalid.
fn data_len(
    frame: &VideoFrameInfo,
    frame_len: u32,
    frag_index: u16,
    frag_count: u16,
    frag_size: u16,
) -> Result<usize, PayloadError> {
    let size = u32::from(frag_size);
    let layout_ok = frame.frame_id != 0
        && (1..=VideoFragment::MAX_FRAME_LEN).contains(&frame_len)
        && (1..=VideoFragment::MAX_DATA).contains(&usize::from(frag_size))
        && frame_len.div_ceil(size) == u32::from(frag_count)
        && frag_index < frag_count;
    if !layout_ok {
        return Err(PayloadError::FragmentLayout);
    }
    if frame.codec != VideoFragment::CODEC_JPEG || frame.color != VideoFragment::COLOR_SRGB_REC709 {
        return Err(PayloadError::VideoFormat);
    }
    // frag_index < frag_count = ⌈frame_len / size⌉, so the offset is below frame_len.
    let offset = u32::from(frag_index) * size;
    usize::try_from(size.min(frame_len - offset)).map_err(|_| PayloadError::FragmentLayout)
}

/// Splits one encoded frame into its fragments, in index order (vcp.md §6.5 Sending), with
/// `frag_size` [`VideoFragment::MAX_DATA`]. Borrows `data`; nothing is copied.
///
/// Fails for a `frame_id` of 0, an empty frame, one over 4 MiB, or an unknown codec/colour.
pub fn fragment_frame(
    frame: VideoFrameInfo,
    data: &[u8],
) -> Result<impl ExactSizeIterator<Item = VideoFragment<'_>>, PayloadError> {
    let frame_len = u32::try_from(data.len()).map_err(|_| PayloadError::FragmentLayout)?;
    let frag_size = VideoFragment::MAX_DATA as u16;
    let frag_count = u16::try_from(data.len().div_ceil(VideoFragment::MAX_DATA))
        .map_err(|_| PayloadError::FragmentLayout)?;
    // Validates the frame as its first fragment would be validated.
    data_len(&frame, frame_len, 0, frag_count, frag_size)?;
    Ok((0..frag_count)
        .zip(data.chunks(VideoFragment::MAX_DATA))
        .map(move |(frag_index, data)| VideoFragment {
            frame,
            frame_len,
            frag_index,
            frag_count,
            frag_size,
            data,
        }))
}

/// A complete frame from [`Reassembler::push`]; `data` is valid until the next push.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CompleteFrame<'r> {
    pub frame: VideoFrameInfo,
    pub data: &'r [u8],
}

/// What [`Reassembler::push`] did with a fragment (vcp.md §6.5 Reassembly).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pushed<'r> {
    /// Stored; the frame still misses fragments.
    Pending,
    /// Stored, and it was the frame's last missing fragment.
    Complete(CompleteFrame<'r>),
    /// From a frame older than the newest one (rule 1).
    Stale,
    /// Its index already arrived for the frame in progress (rule 3).
    Duplicate,
    /// Its frame is already complete or abandoned (rule 3).
    Done,
    /// Its frame fields differ from the frame's: the frame is abandoned (rule 3).
    Inconsistent,
}

/// Counters for the viewfinder HUD and adaptive quality (NET-VID-005).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ReassemblyStats {
    /// Frames handed to the decoder.
    pub complete: u64,
    /// Frames abandoned incomplete: superseded by a newer frame, or inconsistent.
    pub lost: u64,
    pub stale: u64,
    pub duplicate: u64,
    pub done: u64,
    pub inconsistent: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Open,
    Finished,
}

/// Device-side reassembly: at most one frame in progress, newest `frame_id` wins (NET-VID-001).
/// One per session. Buffers are reused across frames, so steady-state pushes don't allocate.
#[derive(Debug, Default)]
pub struct Reassembler {
    /// Highest `frame_id` accepted in the session (0 = none yet).
    newest: u32,
    /// The newest frame's fields and state; `None` before the first fragment.
    current: Option<(FrameKey, State)>,
    buf: Vec<u8>,
    have: Vec<bool>,
    missing: u16,
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

    /// Feeds one validated fragment (from [`crate::Endpoint::open`] or [`VideoFragment::decode`]).
    pub fn push(&mut self, frag: &VideoFragment<'_>) -> Pushed<'_> {
        let key = frag.frame_key();
        let id = frag.frame.frame_id;
        if id < self.newest {
            self.stats.stale += 1;
            return Pushed::Stale;
        }
        if id > self.newest {
            if matches!(self.current, Some((_, State::Open))) {
                self.stats.lost += 1;
            }
            self.start(id, key, frag);
        } else {
            match self.current {
                Some((_, State::Finished)) | None => {
                    self.stats.done += 1;
                    return Pushed::Done;
                }
                Some((current, State::Open)) => {
                    if self.have.get(usize::from(frag.frag_index)) == Some(&true) {
                        self.stats.duplicate += 1;
                        return Pushed::Duplicate;
                    }
                    if current != key {
                        self.current = Some((current, State::Finished));
                        self.stats.lost += 1;
                        self.stats.inconsistent += 1;
                        return Pushed::Inconsistent;
                    }
                }
            }
        }
        let index = usize::from(frag.frag_index);
        let offset = index * usize::from(frag.frag_size);
        // `decode` bounds data to frame_len and `start` sized both buffers from this frame's key.
        let (Some(dst), Some(flag)) = (
            self.buf.get_mut(offset..offset + frag.data.len()),
            self.have.get_mut(index),
        ) else {
            return Pushed::Inconsistent;
        };
        dst.copy_from_slice(frag.data);
        *flag = true;
        self.missing -= 1;
        if self.missing > 0 {
            return Pushed::Pending;
        }
        self.current = Some((key, State::Finished));
        self.stats.complete += 1;
        Pushed::Complete(CompleteFrame {
            frame: frag.frame,
            data: &self.buf,
        })
    }

    fn start(&mut self, id: u32, key: FrameKey, frag: &VideoFragment<'_>) {
        self.newest = id;
        self.current = Some((key, State::Open));
        // Old bytes left in `buf` are never exposed: the fragments tile [0, frame_len) exactly,
        // and the frame completes only after every one of them has been copied in.
        self.buf.resize(frag.frame_len as usize, 0);
        self.have.clear();
        self.have.resize(usize::from(frag.frag_count), false);
        self.missing = frag.frag_count;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info(frame_id: u32) -> VideoFrameInfo {
        VideoFrameInfo {
            frame_id,
            render_time_ns: 5,
            pose_seq: 6,
            codec: VideoFragment::CODEC_JPEG,
            color: VideoFragment::COLOR_SRGB_REC709,
            quality: 80,
            flags: 0,
        }
    }

    #[test]
    fn split_tiles_the_frame_and_reassembles_in_any_order() {
        let data: Vec<u8> = (0..3000u32).map(|i| (i * 31 % 251) as u8).collect();
        let frags: Vec<_> = fragment_frame(info(3), &data).unwrap().collect();
        assert_eq!(
            frags.iter().map(|f| f.data.len()).collect::<Vec<_>>(),
            [1148, 1148, 704]
        );
        let mut r = Reassembler::new();
        assert_eq!(r.push(&frags[2]), Pushed::Pending);
        assert_eq!(r.push(&frags[0]), Pushed::Pending);
        match r.push(&frags[1]) {
            Pushed::Complete(c) => {
                assert_eq!(c.data, &data[..]);
                assert_eq!(c.frame, info(3));
            }
            other => panic!("expected a complete frame, got {other:?}"),
        }
    }

    #[test]
    fn a_shorter_frame_after_a_longer_one_is_exact() {
        let long = [7u8; 2500];
        let short = [9u8; 10];
        let mut r = Reassembler::new();
        for f in fragment_frame(info(1), &long).unwrap() {
            r.push(&f);
        }
        let f = fragment_frame(info(2), &short).unwrap().next().unwrap();
        assert!(matches!(r.push(&f), Pushed::Complete(c) if c.data == short));
    }

    #[test]
    fn split_rejects_what_a_receiver_would_drop() {
        let too_big = vec![0u8; VideoFragment::MAX_FRAME_LEN as usize + 1];
        assert_eq!(
            fragment_frame(info(1), &too_big).err(),
            Some(PayloadError::FragmentLayout)
        );
        assert_eq!(
            fragment_frame(info(1), &[]).err(),
            Some(PayloadError::FragmentLayout)
        );
        assert_eq!(
            fragment_frame(info(0), &[1]).err(),
            Some(PayloadError::FragmentLayout)
        );
        let h264 = VideoFrameInfo {
            codec: 2,
            ..info(1)
        };
        assert_eq!(
            fragment_frame(h264, &[1]).err(),
            Some(PayloadError::VideoFormat)
        );
        // Exactly 4 MiB is allowed and every fragment re-validates.
        let max = vec![0u8; VideoFragment::MAX_FRAME_LEN as usize];
        let mut out = Vec::new();
        for f in fragment_frame(info(1), &max).unwrap() {
            out.clear();
            f.encode(&mut out).unwrap();
            assert_eq!(VideoFragment::decode(&out).unwrap(), f);
        }
    }
}
