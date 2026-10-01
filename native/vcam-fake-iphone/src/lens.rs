//! T2 lens controls of the fake iPhone (vcp.md §6.2 bits 4–9) and the applied lens it reports
//! from `STATUS` (§6.4).
//!
//! `--lens`, `--focus`, `--fstop` and `--dof` are absolute state sent from the first
//! `CONTROL_STATE`. `--tap` and `--rack` send their group from the first state with sequence 0,
//! which only sets the host's baseline, then change the sequence to 1 at `FRAME` (default
//! [`DEFAULT_REQUEST_FRAME`]), which is one tap or one rack request. Groups for flags that
//! aren't given are left out, so the host keeps its own values. Like the app, the state that
//! starts a tap or rack and every later one leave the manual focus out (vcp.md §6.2).

use std::fmt::Write as _;

use vcam_protocol::{AppliedLens, ControlState, RackFocus, TapFocus};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

/// The frame a `--tap`/`--rack` request is sent at when `@FRAME` is omitted: 1 s into the
/// 60 Hz script, so the host has seen the baseline sequence first.
pub(crate) const DEFAULT_REQUEST_FRAME: usize = 60;

/// Usage text for the lens flags.
pub(crate) const USAGE: &str = "[--lens MM] [--focus M] [--fstop F] [--dof 0|1] \
     [--tap U,V[@FRAME]] [--rack A,B,TARGET,MS[@FRAME]]";

#[derive(Debug, Default, PartialEq)]
pub(crate) struct LensArgs {
    lens_mm: Option<f32>,
    focus_m: Option<f32>,
    fstop: Option<f32>,
    dof: Option<bool>,
    /// Point and the frame at which the tap is requested.
    tap: Option<(f32, f32, usize)>,
    /// A and B marks, target (1 A, 2 B), duration and the frame at which the rack starts.
    rack: Option<(f32, f32, u8, u16, usize)>,
}

fn number(flag: &str, value: &str, low: f32, high: f32) -> Result<f32> {
    let v: f32 = value
        .trim()
        .parse()
        .map_err(|e| format!("{flag}: {value:?}: {e}"))?;
    if v.is_finite() && (low..=high).contains(&v) {
        Ok(v)
    } else {
        Err(format!("{flag} must be in [{low}, {high}]").into())
    }
}

/// `VALUE[@FRAME]`.
fn at_frame<'a>(flag: &str, value: &'a str) -> Result<(&'a str, usize)> {
    match value.split_once('@') {
        Some((v, frame)) => Ok((
            v,
            frame
                .parse()
                .map_err(|e| format!("{flag}: frame {frame:?}: {e}"))?,
        )),
        None => Ok((value, DEFAULT_REQUEST_FRAME)),
    }
}

fn rack_target(value: &str) -> Result<u8> {
    match value.trim() {
        "A" | "a" | "1" => Ok(1),
        "B" | "b" | "2" => Ok(2),
        _ => Err("--rack TARGET must be A or B".into()),
    }
}

impl LensArgs {
    /// Takes `flag`'s value if it is a lens flag; returns false for any other flag.
    pub(crate) fn parse(
        &mut self,
        flag: &str,
        value: impl FnOnce() -> Result<String>,
    ) -> Result<bool> {
        match flag {
            "--lens" => self.lens_mm = Some(number(flag, &value()?, 1.0, 2500.0)?),
            "--focus" => self.focus_m = Some(number(flag, &value()?, 0.01, 100_000.0)?),
            "--fstop" => self.fstop = Some(number(flag, &value()?, 0.1, 128.0)?),
            "--dof" => {
                self.dof = Some(match value()?.as_str() {
                    "0" => false,
                    "1" => true,
                    _ => return Err("--dof must be 0 or 1".into()),
                });
            }
            "--tap" => {
                let value = value()?;
                let (point, frame) = at_frame(flag, &value)?;
                let (u, v) = point.split_once(',').ok_or("--tap needs U,V")?;
                self.tap = Some((
                    number(flag, u, 0.0, 1.0)?,
                    number(flag, v, 0.0, 1.0)?,
                    frame,
                ));
            }
            "--rack" => {
                let value = value()?;
                let (spec, frame) = at_frame(flag, &value)?;
                let [a, b, target, ms] = spec
                    .split(',')
                    .collect::<Vec<_>>()
                    .try_into()
                    .map_err(|_| "--rack needs A,B,TARGET,MS")?;
                let ms: u16 = ms
                    .trim()
                    .parse()
                    .map_err(|e| format!("--rack MS {ms:?}: {e}"))?;
                if ms > 60_000 {
                    return Err("--rack MS must be in [0, 60000]".into());
                }
                let marks = (
                    number(flag, a, 0.01, 100_000.0)?,
                    number(flag, b, 0.01, 100_000.0)?,
                );
                self.rack = Some((marks.0, marks.1, rack_target(target)?, ms, frame));
            }
            _ => return Ok(false),
        }
        Ok(true)
    }

    /// The lens part of the session's first `CONTROL_STATE`.
    pub(crate) fn initial(&self, state: &mut ControlState) {
        state.lens_mm = self.lens_mm;
        state.focus_distance_m = self.focus_m;
        state.fstop = self.fstop;
        state.dof_on = self.dof;
        state.tap = self.tap.map(|(u, v, _)| TapFocus { u, v, seq: 0 });
        state.rack = self.rack.map(|(a_m, b_m, _, duration_ms, _)| RackFocus {
            a_m,
            b_m,
            target: 0,
            duration_ms,
            seq: 0,
        });
    }

    /// Starts the tap and/or rack due at `frame`; true if `state` changed.
    pub(crate) fn change_at(&self, frame: usize, state: &mut ControlState) -> bool {
        let mut changed = false;
        if let (Some((_, _, at)), Some(tap)) = (self.tap, state.tap.as_mut())
            && at == frame
        {
            tap.seq = tap.seq.wrapping_add(1);
            changed = true;
        }
        if let (Some((_, _, target, _, at)), Some(rack)) = (self.rack, state.rack.as_mut())
            && at == frame
        {
            rack.target = target;
            rack.seq = rack.seq.wrapping_add(1);
            changed = true;
        }
        if changed {
            state.focus_distance_m = None;
        }
        changed
    }
}

/// ` applied_lens=0`, or `applied_lens=1` with the host's values (shortest round-trip binary32
/// text) and the horizontal FOV and 35 mm equivalent derived from them (vcp.md §6.4).
pub(crate) fn applied_summary(lens: Option<&AppliedLens>) -> String {
    let Some(l) = lens else {
        return " applied_lens=0".to_owned();
    };
    let mut out = format!(
        " applied_lens=1 lens_mm={} focus_m={} fstop={} dof={} sensor_width_mm={} sensor_fit={} aspect={}",
        l.lens_mm,
        l.focus_distance_m,
        l.fstop,
        u8::from(l.dof_on),
        l.sensor_width_mm,
        l.sensor_fit,
        l.render_aspect
    );
    match l.horizontal_fov_and_equivalent() {
        Some((fov, equivalent)) => {
            let _ = write!(out, " hfov_deg={fov:.2} equiv_mm={equivalent:.2}");
        }
        None => out.push_str(" hfov_deg=unavailable equiv_mm=unavailable"),
    }
    out
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)] // test code: a panic is a test failure

    use super::*;

    fn parse(args: &[&str]) -> Result<LensArgs> {
        let mut lens = LensArgs::default();
        for pair in args.chunks(2) {
            assert!(lens.parse(pair[0], || Ok(pair[1].to_owned()))?, "{pair:?}");
        }
        Ok(lens)
    }

    #[test]
    fn lens_flags_parse_with_ranges_and_default_frames() {
        let lens = parse(&[
            "--lens",
            "50",
            "--focus",
            "3",
            "--fstop",
            "2.8",
            "--dof",
            "1",
            "--tap",
            "0.25,0.75",
            "--rack",
            "2,8,B,1200@90",
        ])
        .unwrap();
        assert_eq!(
            lens,
            LensArgs {
                lens_mm: Some(50.0),
                focus_m: Some(3.0),
                fstop: Some(2.8),
                dof: Some(true),
                tap: Some((0.25, 0.75, DEFAULT_REQUEST_FRAME)),
                rack: Some((2.0, 8.0, 2, 1200, 90)),
            }
        );
        let err = |args: &[&str]| parse(args).unwrap_err().to_string();
        assert_eq!(err(&["--lens", "0.5"]), "--lens must be in [1, 2500]");
        assert_eq!(
            err(&["--focus", "NaN"]),
            "--focus must be in [0.01, 100000]"
        );
        assert_eq!(err(&["--fstop", "200"]), "--fstop must be in [0.1, 128]");
        assert_eq!(err(&["--dof", "2"]), "--dof must be 0 or 1");
        assert_eq!(err(&["--tap", "1.5,0"]), "--tap must be in [0, 1]");
        assert_eq!(err(&["--tap", "0.5"]), "--tap needs U,V");
        assert_eq!(err(&["--rack", "1,2,C,0"]), "--rack TARGET must be A or B");
        assert_eq!(err(&["--rack", "1,2,A"]), "--rack needs A,B,TARGET,MS");
        assert_eq!(
            err(&["--rack", "1,2,A,60001"]),
            "--rack MS must be in [0, 60000]"
        );
        assert!(err(&["--tap", "0.5,0.5@x"]).starts_with("--tap: frame"));
        let mut other = LensArgs::default();
        assert!(!other.parse("--scale", || Ok("2".to_owned())).unwrap());
    }

    #[test]
    fn tap_and_rack_send_a_baseline_then_one_request_at_their_frame() {
        let lens = parse(&["--tap", "0.5,0.25@3", "--rack", "1,4,A,500@5"]).unwrap();
        let mut state = ControlState::default();
        lens.initial(&mut state);
        assert_eq!(
            state.tap,
            Some(TapFocus {
                u: 0.5,
                v: 0.25,
                seq: 0
            })
        );
        let rack = RackFocus {
            a_m: 1.0,
            b_m: 4.0,
            target: 0,
            duration_ms: 500,
            seq: 0,
        };
        assert_eq!(state.rack, Some(rack));
        assert_eq!(state.lens_mm, None, "absent flags leave their group out");
        let changes: Vec<usize> = (0..8).filter(|&f| lens.change_at(f, &mut state)).collect();
        assert_eq!(changes, [3, 5]);
        assert_eq!(state.tap.unwrap().seq, 1);
        assert_eq!(
            state.rack,
            Some(RackFocus {
                target: 1,
                seq: 1,
                ..rack
            })
        );
    }

    #[test]
    fn a_tap_or_rack_clears_the_manual_focus_like_the_app() {
        for flags in [["--tap", "0.5,0.5@2"], ["--rack", "1,4,B,0@2"]] {
            let lens = parse(&["--focus", "3", flags[0], flags[1]]).unwrap();
            let mut state = ControlState::default();
            lens.initial(&mut state);
            assert_eq!(state.focus_distance_m, Some(3.0));
            assert!(!lens.change_at(1, &mut state));
            assert_eq!(state.focus_distance_m, Some(3.0), "{flags:?}");
            assert!(lens.change_at(2, &mut state));
            assert_eq!(state.focus_distance_m, None, "{flags:?}");
        }
    }

    #[test]
    fn applied_summary_prints_wire_values_and_derived_fov() {
        assert_eq!(applied_summary(None), " applied_lens=0");
        let lens = AppliedLens {
            lens_mm: 50.0,
            focus_distance_m: 4.0,
            fstop: 2.8,
            dof_on: true,
            sensor_fit: 0,
            sensor_width_mm: 36.0,
            render_aspect: 1.5,
        };
        assert_eq!(
            applied_summary(Some(&lens)),
            " applied_lens=1 lens_mm=50 focus_m=4 fstop=2.8 dof=1 sensor_width_mm=36 sensor_fit=0 aspect=1.5 hfov_deg=39.60 equiv_mm=50.00"
        );
        let vertical = AppliedLens {
            sensor_fit: 1,
            ..lens
        };
        assert!(
            applied_summary(Some(&vertical))
                .ends_with(" hfov_deg=unavailable equiv_mm=unavailable")
        );
    }
}
