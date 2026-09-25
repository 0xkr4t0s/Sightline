//! Optional One-Euro pose smoothing (task 1.2.6; FR-BL-006).
//!
//! Casiez, Roussel, Vogel, "1€ Filter" (CHI 2012): a low-pass filter whose cutoff rises with
//! speed, so a still camera doesn't jitter and a fast move doesn't lag. Time steps come from the
//! device's `capture_time_ns`, not arrival time, so network jitter doesn't change the filtering.
//! Position uses one filter per axis. Orientation is slerped toward each new sample, with speed
//! taken from the angular velocity. Raw samples are never modified; the caller keeps both.

use std::f64::consts::PI;
use std::io;

use vcam_protocol::Pose;

/// A gap longer than this (or a non-increasing capture time) restarts the filter at the raw
/// sample instead of smoothing across it.
const MAX_GAP_S: f64 = 0.5;

/// One-Euro parameters for one channel.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OneEuro {
    /// Cutoff (Hz) at rest: lower means smoother but more lag when slow.
    pub min_cutoff: f64,
    /// Cutoff increase per unit of speed (per m/s for position, per rad/s for rotation).
    pub beta: f64,
    /// Cutoff (Hz) for the speed estimate itself.
    pub d_cutoff: f64,
}

/// Position and rotation parameters.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Smoothing {
    pub position: OneEuro,
    pub rotation: OneEuro,
}

impl Default for Smoothing {
    /// Starting values, not yet tuned on a device (needs real ARKit data).
    fn default() -> Self {
        Self {
            position: OneEuro {
                min_cutoff: 1.0,
                beta: 2.0,
                d_cutoff: 1.0,
            },
            rotation: OneEuro {
                min_cutoff: 1.0,
                beta: 0.5,
                d_cutoff: 1.0,
            },
        }
    }
}

impl Smoothing {
    /// Cutoffs must be finite and > 0, beta finite and >= 0.
    pub fn validate(&self) -> io::Result<()> {
        for p in [self.position, self.rotation] {
            let ok = p.min_cutoff.is_finite()
                && p.min_cutoff > 0.0
                && p.d_cutoff.is_finite()
                && p.d_cutoff > 0.0
                && p.beta.is_finite()
                && p.beta >= 0.0;
            if !ok {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "smoothing cutoffs must be finite and > 0, beta finite and >= 0",
                ));
            }
        }
        Ok(())
    }
}

/// Smoothing factor for a first-order low-pass at `cutoff` Hz over `dt` seconds.
fn alpha(cutoff: f64, dt: f64) -> f64 {
    let tau = 1.0 / (2.0 * PI * cutoff);
    1.0 / (1.0 + tau / dt)
}

#[derive(Clone, Copy, Debug)]
struct Last {
    time_ns: u64,
    tracking_state: u8,
    position: [f64; 3],
    position_speed: [f64; 3],
    orientation: [f64; 4],
    angular_speed: f64,
}

/// Filter state for one session.
#[derive(Clone, Debug, Default)]
pub struct PoseFilter {
    last: Option<Last>,
}

impl PoseFilter {
    /// Returns the smoothed pose for `raw` (the first sample, a gap, or a tracking-state change
    /// passes through unchanged). Only position and orientation change.
    pub fn apply(&mut self, raw: &Pose, params: &Smoothing) -> Pose {
        let position = raw.position_m.map(f64::from);
        let orientation = raw.orientation.map(f64::from);
        let fresh = Last {
            time_ns: raw.capture_time_ns,
            tracking_state: raw.tracking_state,
            position,
            position_speed: [0.0; 3],
            orientation,
            angular_speed: 0.0,
        };
        let next = match self.last {
            Some(last)
                if raw.tracking_state == last.tracking_state
                    && raw.capture_time_ns > last.time_ns =>
            {
                let dt = (raw.capture_time_ns - last.time_ns) as f64 * 1e-9;
                if dt > MAX_GAP_S {
                    fresh
                } else {
                    step(
                        &last,
                        raw.capture_time_ns,
                        dt,
                        position,
                        orientation,
                        params,
                    )
                }
            }
            _ => fresh,
        };
        self.last = Some(next);
        Pose {
            position_m: next.position.map(|v| v as f32),
            orientation: next.orientation.map(|v| v as f32),
            ..*raw
        }
    }
}

fn step(
    last: &Last,
    time_ns: u64,
    dt: f64,
    position: [f64; 3],
    orientation: [f64; 4],
    params: &Smoothing,
) -> Last {
    let p = params.position;
    let mut out_position = [0.0; 3];
    let mut out_speed = [0.0; 3];
    for i in 0..3 {
        let raw_speed = (position[i] - last.position[i]) / dt;
        let speed =
            last.position_speed[i] + alpha(p.d_cutoff, dt) * (raw_speed - last.position_speed[i]);
        let cutoff = p.min_cutoff + p.beta * speed.abs();
        out_position[i] = last.position[i] + alpha(cutoff, dt) * (position[i] - last.position[i]);
        out_speed[i] = speed;
    }

    let r = params.rotation;
    // q and -q are the same rotation: take the one nearest the last output.
    let target = if dot(&last.orientation, &orientation) < 0.0 {
        orientation.map(|c| -c)
    } else {
        orientation
    };
    let raw_speed = angle_between(&last.orientation, &target) / dt;
    let angular_speed =
        last.angular_speed + alpha(r.d_cutoff, dt) * (raw_speed - last.angular_speed);
    let cutoff = r.min_cutoff + r.beta * angular_speed;
    let out_orientation = slerp(&last.orientation, &target, alpha(cutoff, dt));

    Last {
        time_ns,
        tracking_state: last.tracking_state,
        position: out_position,
        position_speed: out_speed,
        orientation: out_orientation,
        angular_speed,
    }
}

fn dot(a: &[f64; 4], b: &[f64; 4]) -> f64 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

fn normalize(q: [f64; 4]) -> [f64; 4] {
    let n = dot(&q, &q).sqrt();
    if n > 0.0 {
        q.map(|c| c / n)
    } else {
        [0.0, 0.0, 0.0, 1.0]
    }
}

/// Rotation angle (radians) from `a` to `b`, both unit and in the same hemisphere.
fn angle_between(a: &[f64; 4], b: &[f64; 4]) -> f64 {
    2.0 * dot(a, b).clamp(-1.0, 1.0).acos()
}

/// Spherical interpolation from `a` (t = 0) to `b` (t = 1); `b` is in `a`'s hemisphere.
fn slerp(a: &[f64; 4], b: &[f64; 4], t: f64) -> [f64; 4] {
    let cos = dot(a, b).clamp(-1.0, 1.0);
    let theta = cos.acos();
    if theta < 1e-9 {
        return normalize(*b);
    }
    let sin = theta.sin();
    let (wa, wb) = (((1.0 - t) * theta).sin() / sin, (t * theta).sin() / sin);
    normalize([0, 1, 2, 3].map(|i| wa * a[i] + wb * b[i]))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)] // test code: a panic is a test failure

    use super::*;

    const FRAME_NS: u64 = 16_666_667; // 60 Hz

    fn pose(i: u64, position: [f32; 3], orientation: [f32; 4]) -> Pose {
        Pose {
            seq: u32::try_from(i + 1).unwrap(),
            capture_time_ns: 1_000_000_000 + i * FRAME_NS,
            position_m: position,
            orientation,
            tracking_state: Pose::TRACKING_NORMAL,
            flags: 0,
        }
    }

    fn yaw(rad: f64) -> [f32; 4] {
        [0.0, 0.0, (rad / 2.0).sin() as f32, (rad / 2.0).cos() as f32]
    }

    /// Deterministic noise in [-1, 1].
    fn noise(i: u64) -> f64 {
        let x = i
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        ((x >> 11) as f64 / (1u64 << 53) as f64) * 2.0 - 1.0
    }

    #[test]
    fn first_step_matches_the_one_euro_formula() {
        let params = Smoothing {
            position: OneEuro {
                min_cutoff: 1.5,
                beta: 0.0,
                d_cutoff: 1.0,
            },
            rotation: OneEuro {
                min_cutoff: 1.5,
                beta: 0.0,
                d_cutoff: 1.0,
            },
        };
        let mut f = PoseFilter::default();
        f.apply(&pose(0, [0.0; 3], yaw(0.0)), &params);
        let out = f.apply(&pose(1, [1.0, 0.0, 0.0], yaw(0.2)), &params);
        // beta = 0: alpha = 1 / (1 + tau/dt), tau = 1/(2π·1.5 Hz), dt = 1/60 s.
        let dt = FRAME_NS as f64 * 1e-9;
        let a = 1.0 / (1.0 + 1.0 / (2.0 * PI * 1.5) / dt);
        assert!(
            (f64::from(out.position_m[0]) - a).abs() < 1e-6,
            "{out:?} vs {a}"
        );
        // Slerp by the same alpha: yaw a·0.2.
        let expected = yaw(a * 0.2);
        for (got, want) in out.orientation.iter().zip(expected) {
            assert!((got - want).abs() < 1e-6, "{out:?}");
        }
    }

    #[test]
    fn still_camera_jitter_is_reduced_and_raw_is_untouched() {
        let params = Smoothing::default();
        let mut f = PoseFilter::default();
        let (mut raw_var, mut out_var) = (0.0, 0.0);
        for i in 0..600 {
            let n = 0.002 * noise(i); // ±2 mm, ±0.002 rad
            let raw = pose(i, [n as f32, 1.0, 1.5], yaw(n));
            let out = f.apply(&raw, &params);
            assert_eq!(raw.position_m[0], n as f32, "raw must not change");
            if i >= 60 {
                raw_var += n * n;
                out_var += f64::from(out.position_m[0]).powi(2);
            }
            let norm: f32 = out.orientation.iter().map(|c| c * c).sum();
            assert!((norm - 1.0).abs() < 1e-5);
        }
        assert!(out_var < 0.1 * raw_var, "{out_var} vs {raw_var}");
    }

    #[test]
    fn speed_raises_the_cutoff_so_fast_moves_lag_less() {
        let lag = |beta: f64| {
            let params = Smoothing {
                position: OneEuro {
                    min_cutoff: 1.0,
                    beta,
                    d_cutoff: 1.0,
                },
                ..Smoothing::default()
            };
            let mut f = PoseFilter::default();
            let mut last = 0.0;
            for i in 0..120 {
                let x = i as f32 * 2.0 / 60.0; // 2 m/s dolly
                last = x - f
                    .apply(&pose(i, [x, 0.0, 0.0], yaw(0.0)), &params)
                    .position_m[0];
            }
            last
        };
        let (fixed, adaptive) = (lag(0.0), lag(2.0));
        assert!(
            adaptive < 0.25 * fixed,
            "adaptive {adaptive} vs fixed {fixed}"
        );
    }

    #[test]
    fn angular_speed_raises_the_rotation_cutoff() {
        let lag = |beta: f64| {
            let params = Smoothing {
                rotation: OneEuro {
                    min_cutoff: 1.0,
                    beta,
                    d_cutoff: 1.0,
                },
                ..Smoothing::default()
            };
            let mut f = PoseFilter::default();
            let mut last = 0.0;
            for i in 0..60 {
                let angle = i as f64 * 3.0 / 60.0; // 3 rad/s whip pan
                let out = f.apply(&pose(i, [0.0; 3], yaw(angle)), &params);
                last = angle
                    - 2.0 * f64::from(out.orientation[2]).atan2(f64::from(out.orientation[3]));
            }
            last
        };
        let (fixed, adaptive) = (lag(0.0), lag(0.5));
        assert!(
            adaptive < 0.5 * fixed,
            "adaptive {adaptive} vs fixed {fixed}"
        );
    }

    #[test]
    fn opposite_quaternion_sign_takes_the_short_way() {
        let params = Smoothing::default();
        let mut f = PoseFilter::default();
        f.apply(&pose(0, [0.0; 3], yaw(1.0)), &params);
        // yaw 1.1 sent with the opposite sign: still only a 0.1 rad turn.
        let out = f.apply(&pose(1, [0.0; 3], yaw(1.1).map(|c| -c)), &params);
        let q = out.orientation.map(f64::from);
        let angle = 2.0 * q[2].atan2(q[3]);
        let angle = if angle > PI { angle - 2.0 * PI } else { angle };
        assert!((1.0..1.1).contains(&angle), "{angle} {out:?}");
    }

    #[test]
    fn gaps_time_reversal_and_tracking_changes_restart_at_the_raw_sample() {
        let params = Smoothing::default();
        let jump = [5.0, 0.0, 0.0];
        for (name, mutate) in [
            (
                "gap",
                Box::new(|p: &mut Pose| p.capture_time_ns += 600_000_000) as Box<dyn Fn(&mut Pose)>,
            ),
            ("reversal", Box::new(|p: &mut Pose| p.capture_time_ns = 1)),
            ("tracking", Box::new(|p: &mut Pose| p.tracking_state = 2)),
        ] {
            let mut f = PoseFilter::default();
            f.apply(&pose(0, [0.0; 3], yaw(0.0)), &params);
            let mut next = pose(1, jump, yaw(0.5));
            mutate(&mut next);
            let out = f.apply(&next, &params);
            assert_eq!(
                (out.position_m, out.orientation),
                (next.position_m, next.orientation),
                "{name}"
            );
        }
    }

    #[test]
    fn invalid_parameters_are_rejected() {
        assert!(Smoothing::default().validate().is_ok());
        for bad in [0.0, -1.0, f64::NAN, f64::INFINITY] {
            let mut s = Smoothing::default();
            s.rotation.min_cutoff = bad;
            assert!(s.validate().is_err(), "{bad}");
        }
        let mut s = Smoothing::default();
        s.position.beta = -0.1;
        assert!(s.validate().is_err());
    }
}
