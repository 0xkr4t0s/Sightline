//! UDP message payloads (`docs/protocol/vcp.md` §6). Decoding is exact: the values are the
//! binary32/integers on the wire. Validation follows §6 and rejects rather than clamps.

use crate::video::VideoFragment;
use crate::wire::{Reader, put_f32s};

/// Wire type codes (vcp.md §5). Only the UDP types this version specifies.
pub mod msg_type {
    pub const POSE: u8 = 0x01;
    pub const CONTROL_STATE: u8 = 0x02;
    pub const CLOCK: u8 = 0x03;
    pub const STATUS: u8 = 0x04;
    pub const VIDEO_FRAGMENT: u8 = 0x05;
}

/// Why a payload was rejected after the frame checks passed (vcp.md §4.3 steps 8 and §6).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PayloadError {
    /// Shorter than the v1 layout (§4.3 step 8), or a `str8` runs past the end.
    TooShort,
    /// A float is NaN or infinite (§6.1).
    NonFinite,
    /// Quaternion norm outside 0.9–1.1 (§6.1).
    QuaternionNorm,
    /// `motion_scale` present but not finite or outside [0.001, 1000] (§6.2).
    MotionScaleRange,
    /// `STATUS.camera_name` is not UTF-8 or longer than 63 bytes (§6.4).
    BadName,
    /// `VIDEO_FRAGMENT` ids, lengths, count or index are inconsistent or out of range (§6.5).
    FragmentLayout,
    /// `VIDEO_FRAGMENT` codec or colour value this version doesn't know (§6.5).
    VideoFormat,
}

/// `POSE` (0x01), 42 bytes (vcp.md §6.1).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Pose {
    pub seq: u32,
    pub capture_time_ns: u64,
    /// Canonical axes (Blender: right-handed, Z up), metres.
    pub position_m: [f32; 3],
    /// Unit quaternion x, y, z, w in canonical axes, exactly as sent.
    pub orientation: [f32; 4],
    pub tracking_state: u8,
    pub flags: u8,
}

impl Pose {
    pub const LEN: usize = 42;
    /// `tracking_state` value for ARKit `.normal`.
    pub const TRACKING_NORMAL: u8 = 5;

    pub(crate) fn decode(payload: &[u8]) -> Result<Self, PayloadError> {
        let mut r = Reader::new(payload);
        let pose = (|| {
            Some(Self {
                seq: r.u32()?,
                capture_time_ns: r.u64()?,
                position_m: r.f32x()?,
                orientation: r.f32x()?,
                tracking_state: r.u8()?,
                flags: r.u8()?,
            })
        })()
        .ok_or(PayloadError::TooShort)?;
        if !pose
            .position_m
            .iter()
            .chain(&pose.orientation)
            .all(|v| v.is_finite())
        {
            return Err(PayloadError::NonFinite);
        }
        if !(0.9..=1.1).contains(&pose.norm()) {
            return Err(PayloadError::QuaternionNorm);
        }
        Ok(pose)
    }

    pub(crate) fn encode(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.seq.to_le_bytes());
        out.extend_from_slice(&self.capture_time_ns.to_le_bytes());
        put_f32s(out, &self.position_m);
        put_f32s(out, &self.orientation);
        out.extend_from_slice(&[self.tracking_state, self.flags]);
    }

    fn norm(&self) -> f32 {
        self.orientation.iter().map(|c| c * c).sum::<f32>().sqrt()
    }

    /// The orientation scaled to unit length, as the host applies it (§6.1).
    #[must_use]
    pub fn orientation_normalized(&self) -> [f32; 4] {
        let n = self.norm();
        self.orientation.map(|c| c / n)
    }
}

/// `CONTROL_STATE` (0x02), T1 subset, 16 bytes (vcp.md §6.2). Absent fields are `None`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ControlState {
    pub state_seq: u32,
    /// Host metres per device metre.
    pub motion_scale: Option<f32>,
    /// Bit 0 lock height, bit 1 lock roll, bit 2 pan only.
    pub lock_flags: Option<u8>,
    /// Changes (including wrap) request a Set-origin on the host.
    pub origin_epoch: Option<u16>,
}

impl ControlState {
    pub const LEN: usize = 16;
    const HAS_SCALE: u32 = 1 << 0;
    const HAS_LOCKS: u32 = 1 << 1;
    const HAS_EPOCH: u32 = 1 << 2;

    pub(crate) fn decode(payload: &[u8]) -> Result<Self, PayloadError> {
        let mut r = Reader::new(payload);
        let (state_seq, fields, scale, locks, _reserved, epoch) =
            (|| Some((r.u32()?, r.u32()?, r.f32()?, r.u8()?, r.u8()?, r.u16()?)))()
                .ok_or(PayloadError::TooShort)?;
        let motion_scale = (fields & Self::HAS_SCALE != 0).then_some(scale);
        if let Some(s) = motion_scale
            && !(s.is_finite() && (0.001..=1000.0).contains(&s))
        {
            return Err(PayloadError::MotionScaleRange);
        }
        Ok(Self {
            state_seq,
            motion_scale,
            lock_flags: (fields & Self::HAS_LOCKS != 0).then_some(locks),
            origin_epoch: (fields & Self::HAS_EPOCH != 0).then_some(epoch),
        })
    }

    pub(crate) fn encode(&self, out: &mut Vec<u8>) {
        let fields = self.motion_scale.map_or(0, |_| Self::HAS_SCALE)
            | self.lock_flags.map_or(0, |_| Self::HAS_LOCKS)
            | self.origin_epoch.map_or(0, |_| Self::HAS_EPOCH);
        out.extend_from_slice(&self.state_seq.to_le_bytes());
        out.extend_from_slice(&fields.to_le_bytes());
        out.extend_from_slice(&self.motion_scale.unwrap_or(0.0).to_le_bytes());
        out.extend_from_slice(&[self.lock_flags.unwrap_or(0), 0]);
        out.extend_from_slice(&self.origin_epoch.unwrap_or(0).to_le_bytes());
    }
}

/// `CLOCK` (0x03), 28 bytes (vcp.md §6.3).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Clock {
    /// Host → device: `t1` = host clock at send.
    Request { t1: u64 },
    /// Device → host: `t1` echoed; `t2`/`t3` = device clock at receive/send.
    Reply { t1: u64, t2: u64, t3: u64 },
}

impl Clock {
    pub const LEN: usize = 28;

    /// Returns `None` for an unknown `mode` (treated as an unknown type, §4.3 step 7).
    pub(crate) fn decode(payload: &[u8]) -> Result<Option<Self>, PayloadError> {
        let mut r = Reader::new(payload);
        let (mode, _reserved, t1, t2, t3) =
            (|| Some((r.u8()?, r.bytes(3)?, r.u64()?, r.u64()?, r.u64()?)))()
                .ok_or(PayloadError::TooShort)?;
        Ok(match mode {
            0 => Some(Self::Request { t1 }),
            1 => Some(Self::Reply { t1, t2, t3 }),
            _ => None,
        })
    }

    pub(crate) fn encode(&self, out: &mut Vec<u8>) {
        let (mode, t1, t2, t3) = match *self {
            Self::Request { t1 } => (0u8, t1, 0, 0),
            Self::Reply { t1, t2, t3 } => (1u8, t1, t2, t3),
        };
        out.extend_from_slice(&[mode, 0, 0, 0]);
        for t in [t1, t2, t3] {
            out.extend_from_slice(&t.to_le_bytes());
        }
    }
}

/// Clock offset and round-trip delay from one exchange (vcp.md §6.3), in ns.
/// `offset` = device clock − host clock, so `host_time = device_time − offset`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ClockSample {
    pub offset_ns: i128,
    pub delay_ns: i128,
}

impl ClockSample {
    /// `t1`/`t4` host clock, `t2`/`t3` device clock. Uses i128, so any u64 inputs are safe.
    #[must_use]
    pub fn from_timestamps(t1: u64, t2: u64, t3: u64, t4: u64) -> Self {
        let [t1, t2, t3, t4] = [t1, t2, t3, t4].map(i128::from);
        Self {
            offset_ns: ((t2 - t1) + (t3 - t4)) / 2,
            delay_ns: (t4 - t1) - (t3 - t2),
        }
    }
}

/// `STATUS` (0x04), at least 16 bytes (vcp.md §6.4).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub status_seq: u32,
    pub applied_pose_seq: u32,
    pub control_ack: u32,
    pub error_code: u16,
    pub flags: u8,
    pub camera_name: String,
}

impl Status {
    pub const MIN_LEN: usize = 16;
    pub const MAX_NAME: usize = 63;

    pub(crate) fn decode(payload: &[u8]) -> Result<Self, PayloadError> {
        let mut r = Reader::new(payload);
        let (status_seq, applied_pose_seq, control_ack, error_code, flags, name_len) =
            (|| Some((r.u32()?, r.u32()?, r.u32()?, r.u16()?, r.u8()?, r.u8()?)))()
                .ok_or(PayloadError::TooShort)?;
        let name_bytes = r
            .bytes(usize::from(name_len))
            .ok_or(PayloadError::TooShort)?;
        if name_bytes.len() > Self::MAX_NAME {
            return Err(PayloadError::BadName);
        }
        let camera_name = std::str::from_utf8(name_bytes).map_err(|_| PayloadError::BadName)?;
        Ok(Self {
            status_seq,
            applied_pose_seq,
            control_ack,
            error_code,
            flags,
            camera_name: camera_name.to_owned(),
        })
    }

    /// Fails if the name is longer than 63 bytes.
    pub(crate) fn encode(&self, out: &mut Vec<u8>) -> Result<(), PayloadError> {
        let name = self.camera_name.as_bytes();
        let len = u8::try_from(name.len())
            .ok()
            .filter(|&l| usize::from(l) <= Self::MAX_NAME)
            .ok_or(PayloadError::BadName)?;
        out.extend_from_slice(&self.status_seq.to_le_bytes());
        out.extend_from_slice(&self.applied_pose_seq.to_le_bytes());
        out.extend_from_slice(&self.control_ack.to_le_bytes());
        out.extend_from_slice(&self.error_code.to_le_bytes());
        out.extend_from_slice(&[self.flags, len]);
        out.extend_from_slice(name);
        Ok(())
    }
}

/// Any UDP message. `'a` is the lifetime of a `VIDEO_FRAGMENT`'s data.
#[derive(Clone, Debug, PartialEq)]
pub enum Message<'a> {
    Pose(Pose),
    ControlState(ControlState),
    Clock(Clock),
    Status(Status),
    VideoFragment(VideoFragment<'a>),
}

impl Message<'_> {
    #[must_use]
    pub fn msg_type(&self) -> u8 {
        match self {
            Self::Pose(_) => msg_type::POSE,
            Self::ControlState(_) => msg_type::CONTROL_STATE,
            Self::Clock(_) => msg_type::CLOCK,
            Self::Status(_) => msg_type::STATUS,
            Self::VideoFragment(_) => msg_type::VIDEO_FRAGMENT,
        }
    }
}
