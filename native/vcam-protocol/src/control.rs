//! TCP control-channel messages (vcp.md §9–§11): `HELLO`, pairing, session setup, `ERROR`.
//! Frames use the §4.1 header with `session_id` 0 and carry no trailer.

use crate::endpoint::{HEADER_LEN, MAGIC, PROTOCOL_VERSION};
use crate::wire::Reader;

/// Largest TCP payload in v1 (vcp.md §3).
pub const MAX_CONTROL_PAYLOAD: usize = 4096;
/// Byte length of an SRP public value on the wire (`PAD(A)`, `PAD(B)`): the 3072-bit group.
pub const SRP_PUBLIC_LEN: usize = 384;

pub mod control_type {
    pub const HELLO: u8 = 0x40;
    pub const PAIR_CHALLENGE: u8 = 0x41;
    pub const PAIR_PROOF: u8 = 0x42;
    pub const PAIR_ACCEPT: u8 = 0x43;
    pub const SESSION_CHALLENGE: u8 = 0x44;
    pub const SESSION_PROOF: u8 = 0x45;
    pub const SESSION_ACCEPT: u8 = 0x46;
    pub const ERROR: u8 = 0x4F;
}

/// Why a control frame was rejected.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ControlError {
    /// Header malformed: size, magic, `session_id` ≠ 0, or `len` inconsistent / > 4096.
    Frame,
    /// Not VCP version 1 (the connection should answer `ERROR` 1).
    Version,
    /// Unknown control type.
    UnknownType,
    /// Payload too short for its type, or a string is not valid UTF-8.
    Payload,
    /// A string field is too long to encode (`device_name` > 64, `message` > 127 bytes).
    TooLong,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hello {
    /// 0 = pair with code, 1 = start a session with an existing pairing.
    pub mode: u8,
    pub proto_min: u8,
    pub proto_max: u8,
    pub device_id: [u8; 16],
    pub nonce_d: [u8; 16],
    pub device_name: String,
}

impl Hello {
    pub const MODE_PAIR: u8 = 0;
    pub const MODE_SESSION: u8 = 1;
    pub const MAX_NAME: usize = 64;
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairChallenge {
    pub host_id: [u8; 16],
    pub salt: [u8; 16],
    /// `PAD(B)`, big-endian.
    pub b_pub: [u8; SRP_PUBLIC_LEN],
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairProof {
    /// `PAD(A)`, big-endian.
    pub a_pub: [u8; SRP_PUBLIC_LEN],
    pub m1: [u8; 32],
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SessionChallenge {
    pub host_id: [u8; 16],
    pub nonce_h: [u8; 16],
    pub session_id: u32,
    pub udp_port: u16,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ControlErrorMsg {
    pub code: u16,
    pub message: String,
}

impl ControlErrorMsg {
    pub const UNSUPPORTED_VERSION: u16 = 1;
    pub const PROOF_FAILED: u16 = 2;
    pub const NOT_PAIRED: u16 = 3;
    pub const BUSY: u16 = 4;
    pub const PAIRING_DISABLED: u16 = 5;
    pub const MALFORMED: u16 = 6;
    pub const MAX_MESSAGE: usize = 127;
}

/// Any v1 control message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ControlMessage {
    Hello(Hello),
    PairChallenge(PairChallenge),
    PairProof(PairProof),
    PairAccept { m2: [u8; 32] },
    SessionChallenge(SessionChallenge),
    SessionProof { proof: [u8; 32] },
    SessionAccept { proof: [u8; 32] },
    Error(ControlErrorMsg),
}

fn str8(out: &mut Vec<u8>, s: &str, max: usize) -> Result<(), ControlError> {
    let b = s.as_bytes();
    let len = u8::try_from(b.len())
        .ok()
        .filter(|&l| usize::from(l) <= max)
        .ok_or(ControlError::TooLong)?;
    out.push(len);
    out.extend_from_slice(b);
    Ok(())
}

fn read_str8<'a>(r: &mut Reader<'a>, max: usize) -> Option<&'a str> {
    let len = usize::from(r.u8()?);
    if len > max {
        return None;
    }
    std::str::from_utf8(r.bytes(len)?).ok()
}

fn arr<const N: usize>(r: &mut Reader<'_>) -> Option<[u8; N]> {
    r.bytes(N)?.try_into().ok()
}

impl ControlMessage {
    #[must_use]
    pub fn control_type(&self) -> u8 {
        use control_type as t;
        match self {
            Self::Hello(_) => t::HELLO,
            Self::PairChallenge(_) => t::PAIR_CHALLENGE,
            Self::PairProof(_) => t::PAIR_PROOF,
            Self::PairAccept { .. } => t::PAIR_ACCEPT,
            Self::SessionChallenge(_) => t::SESSION_CHALLENGE,
            Self::SessionProof { .. } => t::SESSION_PROOF,
            Self::SessionAccept { .. } => t::SESSION_ACCEPT,
            Self::Error(_) => t::ERROR,
        }
    }

    /// The payload bytes (what the pairing and session transcripts hash).
    pub fn payload(&self) -> Result<Vec<u8>, ControlError> {
        let mut out = Vec::new();
        match self {
            Self::Hello(h) => {
                out.extend_from_slice(&[h.mode, h.proto_min, h.proto_max, 0]);
                out.extend_from_slice(&h.device_id);
                out.extend_from_slice(&h.nonce_d);
                str8(&mut out, &h.device_name, Hello::MAX_NAME)?;
            }
            Self::PairChallenge(c) => {
                out.extend_from_slice(&c.host_id);
                out.extend_from_slice(&c.salt);
                out.extend_from_slice(&c.b_pub);
            }
            Self::PairProof(p) => {
                out.extend_from_slice(&p.a_pub);
                out.extend_from_slice(&p.m1);
            }
            Self::PairAccept { m2: v }
            | Self::SessionProof { proof: v }
            | Self::SessionAccept { proof: v } => {
                out.extend_from_slice(v);
            }
            Self::SessionChallenge(c) => {
                out.extend_from_slice(&c.host_id);
                out.extend_from_slice(&c.nonce_h);
                out.extend_from_slice(&c.session_id.to_le_bytes());
                out.extend_from_slice(&c.udp_port.to_le_bytes());
                out.extend_from_slice(&[0, 0]);
            }
            Self::Error(e) => {
                out.extend_from_slice(&e.code.to_le_bytes());
                out.extend_from_slice(&[0, 0]);
                str8(&mut out, &e.message, ControlErrorMsg::MAX_MESSAGE)?;
            }
        }
        Ok(out)
    }

    /// A complete frame: header (`session_id` 0) ‖ payload.
    pub fn encode(&self) -> Result<Vec<u8>, ControlError> {
        let payload = self.payload()?;
        let len = u16::try_from(payload.len()).map_err(|_| ControlError::TooLong)?;
        let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
        out.extend_from_slice(&MAGIC);
        out.extend_from_slice(&[PROTOCOL_VERSION, self.control_type()]);
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(&len.to_le_bytes());
        out.extend_from_slice(&payload);
        Ok(out)
    }

    /// Total frame length announced by a 12-byte header, for reading a TCP stream: read 12
    /// bytes, call this, then read the rest and pass the whole frame to [`Self::decode`].
    pub fn frame_len(header: &[u8]) -> Result<usize, ControlError> {
        let mut r = Reader::new(header);
        let (magic, version, _type, session_id, len) =
            (|| Some((r.bytes(4)?, r.u8()?, r.u8()?, r.u32()?, r.u16()?)))()
                .ok_or(ControlError::Frame)?;
        if magic != MAGIC || session_id != 0 || usize::from(len) > MAX_CONTROL_PAYLOAD {
            return Err(ControlError::Frame);
        }
        if version != PROTOCOL_VERSION {
            return Err(ControlError::Version);
        }
        Ok(HEADER_LEN + usize::from(len))
    }

    /// Decodes exactly one complete frame. Payloads longer than the v1 layout are accepted and
    /// the extra bytes ignored (vcp.md §2).
    pub fn decode(frame: &[u8]) -> Result<Self, ControlError> {
        let total = Self::frame_len(frame.get(..HEADER_LEN).ok_or(ControlError::Frame)?)?;
        if total != frame.len() {
            return Err(ControlError::Frame);
        }
        let msg_type = *frame.get(5).ok_or(ControlError::Frame)?;
        let mut r = Reader::new(frame.get(HEADER_LEN..).ok_or(ControlError::Frame)?);
        let r = &mut r;
        use control_type as t;
        let msg = match msg_type {
            t::HELLO => (|| {
                let (mode, proto_min, proto_max, _reserved) = (r.u8()?, r.u8()?, r.u8()?, r.u8()?);
                Some(Self::Hello(Hello {
                    mode,
                    proto_min,
                    proto_max,
                    device_id: arr(r)?,
                    nonce_d: arr(r)?,
                    device_name: read_str8(r, Hello::MAX_NAME)?.to_owned(),
                }))
            })(),
            t::PAIR_CHALLENGE => (|| {
                Some(Self::PairChallenge(PairChallenge {
                    host_id: arr(r)?,
                    salt: arr(r)?,
                    b_pub: arr(r)?,
                }))
            })(),
            t::PAIR_PROOF => (|| {
                Some(Self::PairProof(PairProof {
                    a_pub: arr(r)?,
                    m1: arr(r)?,
                }))
            })(),
            t::PAIR_ACCEPT => arr(r).map(|m2| Self::PairAccept { m2 }),
            t::SESSION_CHALLENGE => (|| {
                let (host_id, nonce_h, session_id, udp_port, _reserved) =
                    (arr(r)?, arr(r)?, r.u32()?, r.u16()?, r.u16()?);
                Some(Self::SessionChallenge(SessionChallenge {
                    host_id,
                    nonce_h,
                    session_id,
                    udp_port,
                }))
            })(),
            t::SESSION_PROOF => arr(r).map(|proof| Self::SessionProof { proof }),
            t::SESSION_ACCEPT => arr(r).map(|proof| Self::SessionAccept { proof }),
            t::ERROR => (|| {
                let (code, _reserved) = (r.u16()?, r.u16()?);
                let message = read_str8(r, ControlErrorMsg::MAX_MESSAGE)?.to_owned();
                Some(Self::Error(ControlErrorMsg { code, message }))
            })(),
            _ => return Err(ControlError::UnknownType),
        };
        msg.ok_or(ControlError::Payload)
    }
}
