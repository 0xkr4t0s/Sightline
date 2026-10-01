//! UDP message payloads (`docs/protocol/vcp.md` §6). Decoding is exact: the values are the
//! binary32/integers on the wire. Validation follows §6 and rejects rather than clamps.

use crate::video::{VideoFragment, VideoReport};
use crate::wire::{Reader, put_f32s};

/// Wire type codes (vcp.md §5). Only the UDP types this version specifies.
pub mod msg_type {
    pub const POSE: u8 = 0x01;
    pub const CONTROL_STATE: u8 = 0x02;
    pub const CLOCK: u8 = 0x03;
    pub const STATUS: u8 = 0x04;
    pub const VIDEO_FRAGMENT: u8 = 0x05;
    pub const VIDEO_REPORT: u8 = 0x07;
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
    /// `thermal_state` present but outside 0..=3 (§6.2).
    ThermalStateRange,
    /// Present lens/control value is outside its documented range (§6.2/§6.4).
    LensRange,
    /// `STATUS.camera_name` is not UTF-8 or longer than 63 bytes (§6.4).
    BadName,
    /// `VIDEO_FRAGMENT` ids, lengths, count or index are inconsistent or out of range (§6.5).
    FragmentLayout,
    /// `VIDEO_FRAGMENT` codec or colour value this version doesn't know (§6.5).
    VideoFormat,
    /// `VIDEO_REPORT.frames_complete` above `newest_frame_id` (§6.6).
    ReportCounts,
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

/// Inclusive wire ranges of the T2 lens fields (vcp.md §6.2, §6.4).
mod range {
    pub(super) const LENS_MM: (f32, f32) = (1.0, 2500.0);
    pub(super) const DISTANCE_M: (f32, f32) = (0.01, 100_000.0);
    pub(super) const FSTOP: (f32, f32) = (0.1, 128.0);
    pub(super) const TAP: (f32, f32) = (0.0, 1.0);
    pub(super) const SENSOR_WIDTH_MM: (f32, f32) = (1.0, 1000.0);
    pub(super) const RENDER_ASPECT: (f32, f32) = (0.1, 10.0);
    pub(super) const RACK_MS: u16 = 60_000;
    /// `rack_target` 0 none, 1 A, 2 B; `sensor_fit` 0 horizontal, 1 vertical, 2 auto.
    pub(super) const MAX_ENUM: u8 = 2;
}

fn within(value: f32, (low, high): (f32, f32)) -> bool {
    value.is_finite() && (low..=high).contains(&value)
}

fn checked(value: f32, range: (f32, f32)) -> Result<f32, PayloadError> {
    if within(value, range) {
        Ok(value)
    } else {
        Err(PayloadError::LensRange)
    }
}

/// 0 → false, 1 → true, anything else is out of range.
fn flag(value: u8) -> Result<bool, PayloadError> {
    match value {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(PayloadError::LensRange),
    }
}

/// Tap-to-focus request (`CONTROL_STATE` bit 8, vcp.md §6.2).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TapFocus {
    /// Normalized horizontal position in the streamed picture, 0 at the left.
    pub u: f32,
    /// Normalized vertical position in the streamed picture, 0 at the top.
    pub v: f32,
    /// Request identity: a change (including the wrap) starts one tap.
    pub seq: u16,
}

impl TapFocus {
    fn is_valid(&self) -> bool {
        within(self.u, range::TAP) && within(self.v, range::TAP)
    }
}

/// Host-executed A/B focus rack (`CONTROL_STATE` bit 9, vcp.md §6.2).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RackFocus {
    /// A and B marks along the view axis, metres.
    pub a_m: f32,
    pub b_m: f32,
    /// 0 none, 1 A, 2 B.
    pub target: u8,
    /// 0 jumps to the target at once; at most 60 000.
    pub duration_ms: u16,
    /// Request identity: a change (including the wrap) starts one rack if `target` ≠ 0.
    pub seq: u16,
}

impl RackFocus {
    fn is_valid(&self) -> bool {
        within(self.a_m, range::DISTANCE_M)
            && within(self.b_m, range::DISTANCE_M)
            && self.target <= range::MAX_ENUM
            && self.duration_ms <= range::RACK_MS
    }
}

/// The lens the host camera actually has (`STATUS` flags bit 2, vcp.md §6.4), not the device's
/// request.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AppliedLens {
    pub lens_mm: f32,
    /// Along the view axis, metres.
    pub focus_distance_m: f32,
    pub fstop: f32,
    pub dof_on: bool,
    /// Blender's `sensor_fit`: 0 horizontal, 1 vertical, 2 auto.
    pub sensor_fit: u8,
    pub sensor_width_mm: f32,
    /// Scene `resolution_x × pixel_aspect_x / (resolution_y × pixel_aspect_y)`.
    pub render_aspect: f32,
}

impl AppliedLens {
    /// Length of the block after `camera_name`.
    pub const LEN: usize = 24;
    /// Diagonal of the 36 × 24 mm reference frame, rounded as vcp.md §6.4 specifies.
    pub const FULL_FRAME_DIAGONAL_MM: f64 = 43.27;

    /// Whether every value is finite and inside its vcp.md §6.4 range.
    #[must_use]
    pub fn is_valid(&self) -> bool {
        within(self.lens_mm, range::LENS_MM)
            && within(self.focus_distance_m, range::DISTANCE_M)
            && within(self.fstop, range::FSTOP)
            && self.sensor_fit <= range::MAX_ENUM
            && within(self.sensor_width_mm, range::SENSOR_WIDTH_MM)
            && within(self.render_aspect, range::RENDER_ASPECT)
    }

    /// (horizontal FOV in degrees, 35 mm-equivalent focal length in mm), vcp.md §6.4. `None`
    /// unless the fit is horizontal: a vertical or auto fit also depends on the sensor height.
    #[must_use]
    pub fn horizontal_fov_and_equivalent(&self) -> Option<(f64, f64)> {
        if self.sensor_fit != 0 || !self.is_valid() {
            return None;
        }
        let width = f64::from(self.sensor_width_mm);
        let lens = f64::from(self.lens_mm);
        let diagonal = width.hypot(width / f64::from(self.render_aspect));
        Some((
            2.0 * (width / (2.0 * lens)).atan().to_degrees(),
            lens * Self::FULL_FRAME_DIAGONAL_MM / diagonal,
        ))
    }

    fn decode(block: &[u8]) -> Result<Self, PayloadError> {
        let mut r = Reader::new(block);
        let (lens_mm, focus_distance_m, fstop, dof, sensor_fit, _reserved, width, aspect) =
            (|| {
                Some((
                    r.f32()?,
                    r.f32()?,
                    r.f32()?,
                    r.u8()?,
                    r.u8()?,
                    r.u16()?,
                    r.f32()?,
                    r.f32()?,
                ))
            })()
            .ok_or(PayloadError::TooShort)?;
        let lens = Self {
            lens_mm,
            focus_distance_m,
            fstop,
            dof_on: flag(dof)?,
            sensor_fit,
            sensor_width_mm: width,
            render_aspect: aspect,
        };
        if lens.is_valid() {
            Ok(lens)
        } else {
            Err(PayloadError::LensRange)
        }
    }

    fn encode(&self, out: &mut Vec<u8>) {
        put_f32s(out, &[self.lens_mm, self.focus_distance_m, self.fstop]);
        out.extend_from_slice(&[u8::from(self.dof_on), self.sensor_fit, 0, 0]);
        put_f32s(out, &[self.sensor_width_mm, self.render_aspect]);
    }
}

/// The fixed-offset group behind presence `bit`, or `None` if the bit is clear. A set bit needs
/// every byte of its group (vcp.md §6.2); bytes behind a clear bit are never read.
fn group(
    payload: &[u8],
    fields: u32,
    bit: u32,
    bytes: std::ops::Range<usize>,
) -> Result<Option<Reader<'_>>, PayloadError> {
    if fields & (1 << bit) == 0 {
        return Ok(None);
    }
    payload
        .get(bytes)
        .map(|b| Some(Reader::new(b)))
        .ok_or(PayloadError::TooShort)
}

/// `CONTROL_STATE` (0x02), 16-byte base, 20 bytes with thermal, up to 64 with lens (§6.2).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ControlState {
    pub state_seq: u32,
    /// Host metres per device metre.
    pub motion_scale: Option<f32>,
    /// Bit 0 lock height, bit 1 lock roll, bit 2 pan only.
    pub lock_flags: Option<u8>,
    /// Changes (including wrap) request a Set-origin on the host.
    pub origin_epoch: Option<u16>,
    /// Absolute device thermal state: nominal 0, fair 1, serious 2, critical 3.
    pub thermal_state: Option<u8>,
    /// Absolute focal length, mm (bit 4).
    pub lens_mm: Option<f32>,
    /// Absolute manual focus distance along the view axis, metres (bit 5).
    pub focus_distance_m: Option<f32>,
    /// Absolute aperture f-number (bit 6).
    pub fstop: Option<f32>,
    /// Absolute depth-of-field enable (bit 7).
    pub dof_on: Option<bool>,
    pub tap: Option<TapFocus>,
    pub rack: Option<RackFocus>,
}

impl ControlState {
    pub const LEN: usize = 16;
    /// Payload length with every T2 group present.
    pub const MAX_LEN: usize = 64;
    const HAS_SCALE: u32 = 1 << 0;
    const HAS_LOCKS: u32 = 1 << 1;
    const HAS_EPOCH: u32 = 1 << 2;
    const HAS_THERMAL: u32 = 1 << 3;
    const BIT_LENS: u32 = 4;
    const BIT_FOCUS: u32 = 5;
    const BIT_FSTOP: u32 = 6;
    const BIT_DOF: u32 = 7;
    const BIT_TAP: u32 = 8;
    const BIT_RACK: u32 = 9;

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
        let thermal_state = if fields & Self::HAS_THERMAL != 0 {
            let value = r.bytes(4).ok_or(PayloadError::TooShort)?[0];
            if value > 3 {
                return Err(PayloadError::ThermalStateRange);
            }
            Some(value)
        } else {
            None
        };
        let mut state = Self {
            state_seq,
            motion_scale,
            lock_flags: (fields & Self::HAS_LOCKS != 0).then_some(locks),
            origin_epoch: (fields & Self::HAS_EPOCH != 0).then_some(epoch),
            thermal_state,
            ..Self::default()
        };
        state.decode_lens(payload, fields)?;
        Ok(state)
    }

    /// Bits 4–9: each present group at its fixed offset, whatever the earlier bits say.
    fn decode_lens(&mut self, payload: &[u8], fields: u32) -> Result<(), PayloadError> {
        let float = |bit, at: usize, range| {
            group(payload, fields, bit, at..at + 4)?
                .map(|mut r| checked(r.f32().ok_or(PayloadError::TooShort)?, range))
                .transpose()
        };
        self.lens_mm = float(Self::BIT_LENS, 20, range::LENS_MM)?;
        self.focus_distance_m = float(Self::BIT_FOCUS, 24, range::DISTANCE_M)?;
        self.fstop = float(Self::BIT_FSTOP, 28, range::FSTOP)?;
        self.dof_on = group(payload, fields, Self::BIT_DOF, 32..36)?
            .map(|mut r| flag(r.u8().ok_or(PayloadError::TooShort)?))
            .transpose()?;
        self.tap = group(payload, fields, Self::BIT_TAP, 36..48)?
            .map(|mut r| {
                let tap = (|| {
                    Some(TapFocus {
                        u: r.f32()?,
                        v: r.f32()?,
                        seq: r.u16()?,
                    })
                })()
                .ok_or(PayloadError::TooShort)?;
                tap.is_valid().then_some(tap).ok_or(PayloadError::LensRange)
            })
            .transpose()?;
        self.rack = group(payload, fields, Self::BIT_RACK, 48..64)?
            .map(|mut r| {
                let rack = (|| {
                    let (a_m, b_m, target, _reserved) = (r.f32()?, r.f32()?, r.u8()?, r.u8()?);
                    let (duration_ms, seq) = (r.u16()?, r.u16()?);
                    Some(RackFocus {
                        a_m,
                        b_m,
                        target,
                        duration_ms,
                        seq,
                    })
                })()
                .ok_or(PayloadError::TooShort)?;
                rack.is_valid()
                    .then_some(rack)
                    .ok_or(PayloadError::LensRange)
            })
            .transpose()?;
        Ok(())
    }

    fn validate(&self) -> Result<(), PayloadError> {
        if self.thermal_state.is_some_and(|value| value > 3) {
            return Err(PayloadError::ThermalStateRange);
        }
        let floats = [
            (self.lens_mm, range::LENS_MM),
            (self.focus_distance_m, range::DISTANCE_M),
            (self.fstop, range::FSTOP),
        ];
        if floats
            .iter()
            .any(|&(value, range)| value.is_some_and(|v| !within(v, range)))
            || self.tap.is_some_and(|t| !t.is_valid())
            || self.rack.is_some_and(|r| !r.is_valid())
        {
            return Err(PayloadError::LensRange);
        }
        Ok(())
    }

    /// The shortest payload that holds every present group (groups keep fixed offsets).
    fn encoded_len(&self) -> usize {
        [
            (self.thermal_state.is_some(), 20),
            (self.lens_mm.is_some(), 24),
            (self.focus_distance_m.is_some(), 28),
            (self.fstop.is_some(), 32),
            (self.dof_on.is_some(), 36),
            (self.tap.is_some(), 48),
            (self.rack.is_some(), Self::MAX_LEN),
        ]
        .into_iter()
        .filter_map(|(present, end)| present.then_some(end))
        .max()
        .unwrap_or(Self::LEN)
    }

    /// Absent groups inside the encoded length are sent as zero (reserved, vcp.md §2).
    pub(crate) fn encode(&self, out: &mut Vec<u8>) -> Result<(), PayloadError> {
        self.validate()?;
        let bit = |present: bool, bit: u32| u32::from(present) << bit;
        let fields = self.motion_scale.map_or(0, |_| Self::HAS_SCALE)
            | self.lock_flags.map_or(0, |_| Self::HAS_LOCKS)
            | self.origin_epoch.map_or(0, |_| Self::HAS_EPOCH)
            | self.thermal_state.map_or(0, |_| Self::HAS_THERMAL)
            | bit(self.lens_mm.is_some(), Self::BIT_LENS)
            | bit(self.focus_distance_m.is_some(), Self::BIT_FOCUS)
            | bit(self.fstop.is_some(), Self::BIT_FSTOP)
            | bit(self.dof_on.is_some(), Self::BIT_DOF)
            | bit(self.tap.is_some(), Self::BIT_TAP)
            | bit(self.rack.is_some(), Self::BIT_RACK);
        let mut p = [0u8; Self::MAX_LEN];
        p[0..4].copy_from_slice(&self.state_seq.to_le_bytes());
        p[4..8].copy_from_slice(&fields.to_le_bytes());
        p[8..12].copy_from_slice(&self.motion_scale.unwrap_or(0.0).to_le_bytes());
        p[12] = self.lock_flags.unwrap_or(0);
        p[14..16].copy_from_slice(&self.origin_epoch.unwrap_or(0).to_le_bytes());
        p[16] = self.thermal_state.unwrap_or(0);
        for (at, value) in [
            (20, self.lens_mm),
            (24, self.focus_distance_m),
            (28, self.fstop),
        ] {
            p[at..at + 4].copy_from_slice(&value.unwrap_or(0.0).to_le_bytes());
        }
        p[32] = self.dof_on.map_or(0, u8::from);
        if let Some(tap) = self.tap {
            p[36..40].copy_from_slice(&tap.u.to_le_bytes());
            p[40..44].copy_from_slice(&tap.v.to_le_bytes());
            p[44..46].copy_from_slice(&tap.seq.to_le_bytes());
        }
        if let Some(rack) = self.rack {
            p[48..52].copy_from_slice(&rack.a_m.to_le_bytes());
            p[52..56].copy_from_slice(&rack.b_m.to_le_bytes());
            p[56] = rack.target;
            p[58..60].copy_from_slice(&rack.duration_ms.to_le_bytes());
            p[60..62].copy_from_slice(&rack.seq.to_le_bytes());
        }
        out.extend_from_slice(&p[..self.encoded_len()]);
        Ok(())
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
#[derive(Clone, Debug, PartialEq)]
pub struct Status {
    pub status_seq: u32,
    pub applied_pose_seq: u32,
    pub control_ack: u32,
    pub error_code: u16,
    pub flags: u8,
    pub camera_name: String,
    /// Present exactly when `flags` bit 2 is set.
    pub applied_lens: Option<AppliedLens>,
}

impl Status {
    pub const MIN_LEN: usize = 16;
    pub const MAX_NAME: usize = 63;
    /// `flags` bit 2: the applied-lens block follows `camera_name`.
    pub const HAS_LENS: u8 = 1 << 2;

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
        let applied_lens = if flags & Self::HAS_LENS != 0 {
            let block = r.bytes(AppliedLens::LEN).ok_or(PayloadError::TooShort)?;
            Some(AppliedLens::decode(block)?)
        } else {
            None
        };
        Ok(Self {
            status_seq,
            applied_pose_seq,
            control_ack,
            error_code,
            flags,
            camera_name: camera_name.to_owned(),
            applied_lens,
        })
    }

    /// Fails if the name is longer than 63 bytes, or if `flags` bit 2 disagrees with
    /// `applied_lens` or the lens is out of range.
    pub(crate) fn encode(&self, out: &mut Vec<u8>) -> Result<(), PayloadError> {
        let name = self.camera_name.as_bytes();
        let len = u8::try_from(name.len())
            .ok()
            .filter(|&l| usize::from(l) <= Self::MAX_NAME)
            .ok_or(PayloadError::BadName)?;
        if (self.flags & Self::HAS_LENS != 0) != self.applied_lens.is_some()
            || self.applied_lens.is_some_and(|lens| !lens.is_valid())
        {
            return Err(PayloadError::LensRange);
        }
        out.extend_from_slice(&self.status_seq.to_le_bytes());
        out.extend_from_slice(&self.applied_pose_seq.to_le_bytes());
        out.extend_from_slice(&self.control_ack.to_le_bytes());
        out.extend_from_slice(&self.error_code.to_le_bytes());
        out.extend_from_slice(&[self.flags, len]);
        out.extend_from_slice(name);
        if let Some(lens) = self.applied_lens {
            lens.encode(out);
        }
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
    VideoReport(VideoReport),
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
            Self::VideoReport(_) => msg_type::VIDEO_REPORT,
        }
    }
}

/// Robustness of the T2 tails (vcp.md §2, §6.2, §6.4): truncation, trailing bytes and random
/// payloads never panic; valid-with-trailing is accepted unchanged.
#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)] // test code: a panic is a test failure

    use super::*;

    fn full_control() -> ControlState {
        ControlState {
            state_seq: 11,
            motion_scale: Some(10.0),
            lock_flags: Some(2),
            origin_epoch: Some(3),
            thermal_state: Some(1),
            lens_mm: Some(50.0),
            focus_distance_m: Some(4.0),
            fstop: Some(2.8),
            dof_on: Some(true),
            tap: Some(TapFocus {
                u: 0.25,
                v: 0.75,
                seq: 12,
            }),
            rack: Some(RackFocus {
                a_m: 2.0,
                b_m: 8.0,
                target: 2,
                duration_ms: 1200,
                seq: 7,
            }),
        }
    }

    fn applied() -> AppliedLens {
        AppliedLens {
            lens_mm: 50.0,
            focus_distance_m: 4.0,
            fstop: 2.8,
            dof_on: true,
            sensor_fit: 0,
            sensor_width_mm: 36.0,
            render_aspect: 1.5,
        }
    }

    fn status(applied_lens: Option<AppliedLens>) -> Status {
        Status {
            status_seq: 4,
            applied_pose_seq: 1,
            control_ack: 11,
            error_code: 0,
            flags: 3 | if applied_lens.is_some() {
                Status::HAS_LENS
            } else {
                0
            },
            camera_name: "Camera".into(),
            applied_lens,
        }
    }

    fn encoded(state: &ControlState) -> Vec<u8> {
        let mut out = Vec::new();
        state.encode(&mut out).unwrap();
        out
    }

    #[test]
    fn each_lens_bit_needs_its_whole_group_and_ignores_trailing_bytes() {
        let full = encoded(&full_control());
        assert_eq!(full.len(), ControlState::MAX_LEN);
        for (bit, end) in [(4, 24), (5, 28), (6, 32), (7, 36), (8, 48), (9, 64)] {
            let mut payload = full.clone();
            payload[4..8].copy_from_slice(&(1u32 << bit).to_le_bytes());
            for n in 0..=payload.len() {
                let got = ControlState::decode(&payload[..n]);
                if n < end {
                    assert_eq!(got, Err(PayloadError::TooShort), "bit {bit}, {n} bytes");
                } else {
                    assert!(got.is_ok(), "bit {bit}, {n} bytes: {got:?}");
                }
            }
        }
        for n in 0..ControlState::MAX_LEN {
            assert!(ControlState::decode(&full[..n]).is_err(), "{n} bytes");
        }
        let mut longer = full.clone();
        longer.extend_from_slice(&[0xFF; 40]);
        assert_eq!(ControlState::decode(&longer), Ok(full_control()));
    }

    #[test]
    fn clear_bits_ignore_malformed_lens_bytes() {
        let mut payload = encoded(&full_control());
        payload[4..8].copy_from_slice(&0u32.to_le_bytes());
        payload[20..64].fill(0xFF); // NaNs, dof 255, target 255, duration 65535
        let state = ControlState::decode(&payload).unwrap();
        assert_eq!(
            state,
            ControlState {
                state_seq: 11,
                ..ControlState::default()
            },
            "{state:?}"
        );
    }

    #[test]
    fn out_of_range_lens_values_are_errors_in_both_directions() {
        let bad = [
            ControlState {
                lens_mm: Some(f32::NAN),
                ..full_control()
            },
            ControlState {
                lens_mm: Some(2500.5),
                ..full_control()
            },
            ControlState {
                focus_distance_m: Some(0.0),
                ..full_control()
            },
            ControlState {
                fstop: Some(f32::INFINITY),
                ..full_control()
            },
            ControlState {
                tap: Some(TapFocus {
                    u: 1.01,
                    v: 0.5,
                    seq: 1,
                }),
                ..full_control()
            },
            ControlState {
                tap: Some(TapFocus {
                    u: 0.5,
                    v: -0.1,
                    seq: 1,
                }),
                ..full_control()
            },
            ControlState {
                rack: Some(RackFocus {
                    a_m: 0.0,
                    b_m: 1.0,
                    target: 1,
                    duration_ms: 0,
                    seq: 1,
                }),
                ..full_control()
            },
            ControlState {
                rack: Some(RackFocus {
                    a_m: 1.0,
                    b_m: 1.0,
                    target: 3,
                    duration_ms: 0,
                    seq: 1,
                }),
                ..full_control()
            },
            ControlState {
                rack: Some(RackFocus {
                    a_m: 1.0,
                    b_m: 1.0,
                    target: 1,
                    duration_ms: 60_001,
                    seq: 1,
                }),
                ..full_control()
            },
        ];
        for state in bad {
            assert_eq!(
                state.encode(&mut Vec::new()),
                Err(PayloadError::LensRange),
                "{state:?}"
            );
        }
        let mut dof = encoded(&full_control());
        dof[32] = 2;
        assert_eq!(ControlState::decode(&dof), Err(PayloadError::LensRange));
    }

    #[test]
    fn status_lens_block_follows_the_name_and_tolerates_trailing_bytes() {
        let mut full = Vec::new();
        status(Some(applied())).encode(&mut full).unwrap();
        assert_eq!(full.len(), 16 + "Camera".len() + AppliedLens::LEN);
        for n in 0..full.len() {
            assert!(Status::decode(&full[..n]).is_err(), "{n} bytes");
        }
        full.extend_from_slice(&[0xFF; 17]);
        assert_eq!(Status::decode(&full), Ok(status(Some(applied()))));
        // A clear bit 2 ignores a trailing block, even an invalid one.
        let mut plain = Vec::new();
        status(None).encode(&mut plain).unwrap();
        plain.extend_from_slice(&[0xFF; AppliedLens::LEN]);
        assert_eq!(Status::decode(&plain), Ok(status(None)));
        // Bit 2 and the block must agree when encoding, and the block must be valid.
        let mismatched = Status {
            flags: 3,
            ..status(Some(applied()))
        };
        assert_eq!(
            mismatched.encode(&mut Vec::new()),
            Err(PayloadError::LensRange)
        );
        let no_block = Status {
            flags: 7,
            ..status(None)
        };
        assert_eq!(
            no_block.encode(&mut Vec::new()),
            Err(PayloadError::LensRange)
        );
        for lens in [
            AppliedLens {
                dof_on: true,
                sensor_fit: 3,
                ..applied()
            },
            AppliedLens {
                sensor_width_mm: 1000.5,
                ..applied()
            },
            AppliedLens {
                render_aspect: f32::NAN,
                ..applied()
            },
        ] {
            assert!(!lens.is_valid(), "{lens:?}");
            assert_eq!(
                status(Some(lens)).encode(&mut Vec::new()),
                Err(PayloadError::LensRange)
            );
        }
    }

    #[test]
    fn fov_and_equivalent_need_a_horizontal_fit() {
        let (fov, equivalent) = applied().horizontal_fov_and_equivalent().unwrap();
        assert!((fov - 39.597_752_709_049_864).abs() < 1e-9, "{fov}");
        assert!(
            (equivalent - 50.003_911_438_886_796).abs() < 1e-6,
            "{equivalent}"
        );
        for sensor_fit in [1, 2] {
            let lens = AppliedLens {
                sensor_fit,
                ..applied()
            };
            assert_eq!(lens.horizontal_fov_and_equivalent(), None);
        }
        let invalid = AppliedLens {
            lens_mm: 0.5,
            ..applied()
        };
        assert_eq!(invalid.horizontal_fov_and_equivalent(), None);
    }

    /// Pseudo-random payloads with plausible `fields` words: never a panic, and anything
    /// accepted re-encodes to a payload that decodes to the same value.
    #[test]
    fn random_payloads_never_panic_and_accepted_ones_round_trip() {
        let mut state: u64 = 0x2545_F491_4F6C_DD1D;
        let mut next = || {
            state = state
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            state >> 24
        };
        let seed = encoded(&full_control());
        let (mut accepted, mut lens_accepted) = (0, 0);
        for _ in 0..50_000 {
            let len = usize::try_from(next() % 96).unwrap();
            let mut payload: Vec<u8> = (0..len)
                .map(|i| {
                    let flips = next() & next() & next(); // each bit flips with p = 1/8
                    seed.get(i).copied().unwrap_or(0) ^ flips.to_le_bytes()[0]
                })
                .collect();
            if payload.len() >= 8 {
                let fields = u32::try_from(next() & 0x3FF).unwrap();
                payload[4..8].copy_from_slice(&fields.to_le_bytes());
            }
            let Ok(control) = ControlState::decode(&payload) else {
                let _ = Status::decode(&payload);
                continue;
            };
            accepted += 1;
            lens_accepted += usize::from(control.tap.is_some() || control.rack.is_some());
            assert_eq!(ControlState::decode(&encoded(&control)), Ok(control));
            if let Ok(status) = Status::decode(&payload) {
                let mut out = Vec::new();
                status.encode(&mut out).unwrap();
                assert_eq!(Status::decode(&out), Ok(status));
            }
        }
        assert!(
            accepted > 1000 && lens_accepted > 100,
            "{accepted} {lens_accepted}"
        );
    }
}
