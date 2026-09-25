//! Authenticated UDP framing for one session (vcp.md §4): header, HMAC-SHA256/64 trailer with
//! direction keys, and the ordered receive rules of §4.3.

use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;

use crate::message::{Clock, ControlState, Message, PayloadError, Pose, Status, msg_type};
use crate::video::{FrameInfo, VideoFragment, fragment_count, put_fragment};
use crate::wire::Reader;

type HmacSha256 = Hmac<Sha256>;

pub const MAGIC: [u8; 4] = *b"VCP1";
pub const PROTOCOL_VERSION: u8 = 1;
pub const HEADER_LEN: usize = 12;
pub const TAG_LEN: usize = 8;
/// Largest UDP datagram either end sends or accepts (vcp.md §3).
pub const MAX_DATAGRAM: usize = 1200;

/// Which end of the session this endpoint is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    /// The iPhone: sends with `k_d2h`, receives with `k_h2d`.
    Device,
    /// Blender: sends with `k_h2d`, receives with `k_d2h`.
    Host,
}

/// Why `open` dropped a datagram. Each variant is one step of vcp.md §4.3 (or §6 for payloads).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DropReason {
    /// Step 1: shorter than header + trailer, or longer than 1200 bytes.
    Size,
    /// Step 2.
    Magic,
    /// Step 3: not version 1.
    Version,
    /// Step 4: `12 + len + 8` ≠ datagram length.
    Length,
    /// Step 5: `session_id` is 0 or not this session's.
    Session,
    /// Step 6: HMAC tag mismatch (also catches datagrams reflected back to their sender).
    Tag,
    /// Step 7: type (or `CLOCK` mode) not valid in this direction.
    UnknownType,
    /// Step 8 and §6: payload too short or its values invalid.
    Payload(PayloadError),
}

/// Why `seal` refused to build a datagram.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SealError {
    /// This role never sends that message (for example, a device sending `STATUS`).
    WrongDirection,
    /// The encoded datagram would exceed 1200 bytes.
    TooLarge,
    Payload(PayloadError),
}

/// One end of an authenticated session: seals outgoing and opens incoming datagrams.
#[derive(Clone)]
pub struct Endpoint {
    role: Role,
    session_id: u32,
    send_mac: HmacSha256,
    recv_mac: HmacSha256,
}

impl Endpoint {
    /// `session_id` must be non-zero (vcp.md §10.1); returns `None` otherwise.
    #[must_use]
    pub fn new(role: Role, session_id: u32, k_d2h: &[u8; 32], k_h2d: &[u8; 32]) -> Option<Self> {
        if session_id == 0 {
            return None;
        }
        let (send, recv) = match role {
            Role::Device => (k_d2h, k_h2d),
            Role::Host => (k_h2d, k_d2h),
        };
        Some(Self {
            role,
            session_id,
            send_mac: HmacSha256::new_from_slice(send).ok()?,
            recv_mac: HmacSha256::new_from_slice(recv).ok()?,
        })
    }

    #[must_use]
    pub fn session_id(&self) -> u32 {
        self.session_id
    }

    /// Appends one complete datagram (header ‖ payload ‖ tag) for `msg` to `out`.
    pub fn seal(&self, msg: &Message, out: &mut Vec<u8>) -> Result<(), SealError> {
        if !may_send(self.role, msg) {
            return Err(SealError::WrongDirection);
        }
        self.frame(msg.msg_type(), out, |out| match msg {
            Message::Pose(m) => {
                m.encode(out);
                Ok(())
            }
            Message::ControlState(m) => {
                m.encode(out);
                Ok(())
            }
            Message::Clock(m) => {
                m.encode(out);
                Ok(())
            }
            Message::Status(m) => m.encode(out),
            Message::VideoFragment(m) => m.encode(out),
        })
    }

    /// Splits one encoded frame into `VIDEO_FRAGMENT` datagrams (vcp.md §6.5) and calls `emit`
    /// with each, in index order. Host only. `chunk_len` is normally [`crate::MAX_CHUNK_LEN`].
    /// Returns the number of fragments. Nothing is emitted if the frame or `chunk_len` is out of
    /// range.
    pub fn seal_frame(
        &self,
        info: &FrameInfo,
        frame: &[u8],
        chunk_len: u16,
        mut emit: impl FnMut(&[u8]),
    ) -> Result<u32, SealError> {
        if self.role != Role::Host {
            return Err(SealError::WrongDirection);
        }
        let invalid = SealError::Payload(PayloadError::FragmentLayout);
        let frame_len = u32::try_from(frame.len()).map_err(|_| invalid)?;
        let count = fragment_count(frame_len, chunk_len)
            .filter(|_| info.frame_id != 0)
            .ok_or(invalid)?;
        let mut datagram = Vec::with_capacity(MAX_DATAGRAM);
        for (index, data) in (0..=u16::MAX).zip(frame.chunks(usize::from(chunk_len))) {
            datagram.clear();
            self.frame(msg_type::VIDEO_FRAGMENT, &mut datagram, |out| {
                put_fragment(out, info, frame_len, chunk_len, index, data);
                Ok(())
            })?;
            emit(&datagram);
        }
        Ok(count)
    }

    /// Appends header ‖ payload ‖ tag, with the payload written by `payload`.
    fn frame(
        &self,
        msg_type: u8,
        out: &mut Vec<u8>,
        payload: impl FnOnce(&mut Vec<u8>) -> Result<(), PayloadError>,
    ) -> Result<(), SealError> {
        let start = out.len();
        out.extend_from_slice(&MAGIC);
        out.extend_from_slice(&[PROTOCOL_VERSION, msg_type]);
        out.extend_from_slice(&self.session_id.to_le_bytes());
        out.extend_from_slice(&[0, 0]); // len, patched below
        let payload_start = out.len();
        let fail = |out: &mut Vec<u8>, e| {
            out.truncate(start);
            Err(e)
        };
        if let Err(e) = payload(out) {
            return fail(out, SealError::Payload(e));
        }
        let payload_len = out.len() - payload_start;
        let len = match u16::try_from(payload_len) {
            Ok(len) if HEADER_LEN + payload_len + TAG_LEN <= MAX_DATAGRAM => len,
            _ => return fail(out, SealError::TooLarge),
        };
        out[payload_start - 2..payload_start].copy_from_slice(&len.to_le_bytes());
        let tag = self
            .send_mac
            .clone()
            .chain_update(&out[start..])
            .finalize()
            .into_bytes();
        out.extend_from_slice(&tag[..TAG_LEN]);
        Ok(())
    }

    /// Checks one received datagram against vcp.md §4.3 in order and decodes it.
    /// Freshness (§6 sequence rules) is the caller's job; see [`crate::SeqFilter`].
    pub fn open(&self, datagram: &[u8]) -> Result<Message, DropReason> {
        if !(HEADER_LEN + TAG_LEN..=MAX_DATAGRAM).contains(&datagram.len()) {
            return Err(DropReason::Size);
        }
        let mut r = Reader::new(datagram);
        let (magic, version, msg_type, session_id, len) =
            (|| Some((r.bytes(4)?, r.u8()?, r.u8()?, r.u32()?, r.u16()?)))()
                .ok_or(DropReason::Size)?;
        if magic != MAGIC {
            return Err(DropReason::Magic);
        }
        if version != PROTOCOL_VERSION {
            return Err(DropReason::Version);
        }
        let len = usize::from(len);
        if HEADER_LEN + len + TAG_LEN != datagram.len() {
            return Err(DropReason::Length);
        }
        if session_id == 0 || session_id != self.session_id {
            return Err(DropReason::Session);
        }
        let (authed, tag) = datagram.split_at(HEADER_LEN + len);
        self.recv_mac
            .clone()
            .chain_update(authed)
            .verify_truncated_left(tag)
            .map_err(|_| DropReason::Tag)?;
        let payload = authed.get(HEADER_LEN..).ok_or(DropReason::Length)?;
        let msg = decode(msg_type, payload)?;
        if may_send(self.peer(), &msg) {
            Ok(msg)
        } else {
            Err(DropReason::UnknownType)
        }
    }

    fn peer(&self) -> Role {
        match self.role {
            Role::Device => Role::Host,
            Role::Host => Role::Device,
        }
    }
}

fn decode(msg_type: u8, payload: &[u8]) -> Result<Message, DropReason> {
    let p = DropReason::Payload;
    Ok(match msg_type {
        msg_type::POSE => Message::Pose(Pose::decode(payload).map_err(p)?),
        msg_type::CONTROL_STATE => Message::ControlState(ControlState::decode(payload).map_err(p)?),
        msg_type::CLOCK => Message::Clock(
            Clock::decode(payload)
                .map_err(p)?
                .ok_or(DropReason::UnknownType)?,
        ),
        msg_type::STATUS => Message::Status(Status::decode(payload).map_err(p)?),
        msg_type::VIDEO_FRAGMENT => {
            Message::VideoFragment(VideoFragment::decode(payload).map_err(p)?)
        }
        _ => return Err(DropReason::UnknownType),
    })
}

/// Who may send what (vcp.md §5).
fn may_send(role: Role, msg: &Message) -> bool {
    matches!(
        (role, msg),
        (
            Role::Device,
            Message::Pose(_) | Message::ControlState(_) | Message::Clock(Clock::Reply { .. }),
        ) | (
            Role::Host,
            Message::Status(_) | Message::Clock(Clock::Request { .. }) | Message::VideoFragment(_)
        )
    )
}
