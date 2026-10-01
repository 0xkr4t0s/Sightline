//! The raw buffer of one take, filled from the UDP receive path (FR-TAKE-001, FR-BL-006,
//! NET-002, ARC-004).
//!
//! Every authenticated pose is kept, including reordered and duplicated ones, because the
//! live path's latest-sample slot drops all but the newest. Appending is one `Vec` push under
//! the receiver's state lock; formatting and file I/O happen after [`TakeRecorder::stop`]
//! hands the buffers over, outside that lock. The recorder is kept across session changes: a
//! new session (or a reset in between) opens a new segment, because device clocks differ per
//! session and θ is per segment (`docs/takes-jsonl.md`).

use vcam_protocol::{ClockEstimate, ControlState, Pose};

/// Poses kept per take: 30 minutes at 120 Hz.
const MAX_POSES: usize = 30 * 60 * 120;
/// Control, applied, clock and frame notes and segments kept per take, together.
const MAX_NOTES: usize = 2 * MAX_POSES;
/// Capacity reserved at the start, so the first minute needs no reallocation on the rx thread.
const INITIAL_POSES: usize = 8192;

/// How much one take may hold. At a limit further records are dropped and the take is marked
/// truncated; nothing already recorded is lost.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    pub poses: usize,
    /// Control, applied, clock and frame notes and segments, together.
    pub notes: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            poses: MAX_POSES,
            notes: MAX_NOTES,
        }
    }
}

/// One VCP session inside a take. The index in [`RawTake::segments`] is the `seg` of the records.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Segment {
    pub session_id: u32,
    /// Host time the segment began: the take's start for the first one.
    pub start_host_ns: u64,
}

/// One authenticated POSE, exactly as received.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TakePose {
    pub seg: u32,
    pub pose: Pose,
    /// Host time it arrived.
    pub rx_ns: u64,
    /// A pose with a higher `seq` had already been accepted.
    pub late: bool,
}

/// One accepted `CONTROL_STATE`, with the newest accepted pose of its session at that moment.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TakeControl {
    pub seg: u32,
    pub state: ControlState,
    pub rx_ns: u64,
    /// `seq` of the newest accepted pose, 0 if none yet (0 is "none" throughout VCP).
    pub last_pose_seq: u32,
    /// Its `capture_time_ns`, 0 if none yet.
    pub last_pose_capture_ns: u64,
}

/// The CLOCK estimate after an accepted reply.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TakeClock {
    pub seg: u32,
    pub rx_ns: u64,
    /// θ: device minus host clock.
    pub offset_ns: i64,
    pub delay_ns: i64,
    pub jitter_ns: u64,
}

/// A change to what the live rig applied (Blender's main thread reports it).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AppliedKind {
    Zero {
        position_m: [f32; 3],
        yaw_rad: f32,
    },
    Scale {
        motion_scale: f32,
    },
    Locks {
        lock_flags: u8,
    },
    Lens {
        lens_mm: f32,
        focus_distance_m: Option<f32>,
        fstop: Option<f32>,
        dof_on: Option<bool>,
    },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TakeApplied {
    /// The segment running when it was noted (0 if none has started).
    pub seg: u32,
    pub host_ns: u64,
    /// `Some` when the change took effect with that pose (pose-coupled changes: zero, scale,
    /// locks); `None` when it is keyed by `host_ns` (lens and focus).
    pub pose_seq: Option<u32>,
    pub kind: AppliedKind,
}

/// The timeline showed scene frame `frame` at `host_ns` (FR-TAKE-002).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TakeFrame {
    pub host_ns: u64,
    pub frame: f64,
}

/// Everything recorded between start and stop. Records of each kind are in arrival order.
#[derive(Clone, Debug, PartialEq)]
pub struct RawTake {
    pub take_id: u32,
    pub start_host_ns: u64,
    /// Set by [`TakeRecorder::stop`]; 0 while recording.
    pub stop_host_ns: u64,
    /// True if a limit was hit and records were dropped.
    pub truncated: bool,
    pub segments: Vec<Segment>,
    pub poses: Vec<TakePose>,
    pub controls: Vec<TakeControl>,
    pub applied: Vec<TakeApplied>,
    pub clocks: Vec<TakeClock>,
    pub frames: Vec<TakeFrame>,
}

impl RawTake {
    /// Records other than poses (what [`Limits::notes`] bounds).
    fn notes(&self) -> usize {
        self.segments.len()
            + self.controls.len()
            + self.applied.len()
            + self.clocks.len()
            + self.frames.len()
    }

    fn current_seg(&self) -> u32 {
        index(self.segments.len().saturating_sub(1))
    }
}

/// What the N-panel shows while recording.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TakeStatus {
    pub recording: bool,
    pub take_id: u32,
    pub elapsed_ns: u64,
    pub poses: u64,
    pub late: u64,
    pub segments: u32,
    pub truncated: bool,
}

struct Open {
    raw: RawTake,
    /// Session of the segment being filled; `None` after a break.
    session: Option<u32>,
    late: u64,
}

impl Open {
    /// The segment for `session_id`, opened now if the session changed. `None` at the note limit.
    fn segment(&mut self, session_id: u32, rx_ns: u64, max_notes: usize) -> Option<u32> {
        if self.session != Some(session_id) {
            if !self.has_note_room(max_notes) {
                return None;
            }
            // The first segment began when the take did, even if its first record came later.
            let start_host_ns = if self.raw.segments.is_empty() {
                self.raw.start_host_ns
            } else {
                rx_ns
            };
            self.raw.segments.push(Segment {
                session_id,
                start_host_ns,
            });
            self.session = Some(session_id);
        }
        Some(self.raw.current_seg())
    }

    /// An arrival time never precedes the take: the receive loop stamps a datagram before it
    /// takes the state lock, so one queued behind `take_start` can carry an earlier time.
    fn rx(&self, rx_ns: u64) -> u64 {
        rx_ns.max(self.raw.start_host_ns)
    }

    fn has_note_room(&mut self, max_notes: usize) -> bool {
        let room = self.raw.notes() < max_notes;
        self.raw.truncated |= !room;
        room
    }
}

/// Records one take at a time. Create it empty; [`start`](Self::start) begins a take.
#[derive(Default)]
pub struct TakeRecorder {
    limits: Limits,
    open: Option<Open>,
}

impl TakeRecorder {
    #[must_use]
    pub fn with_limits(limits: Limits) -> Self {
        Self { limits, open: None }
    }

    /// Begins a take at host time `host_ns`. Returns false, changing nothing, if one is running.
    pub fn start(&mut self, host_ns: u64, take_id: u32) -> bool {
        if self.open.is_some() {
            return false;
        }
        self.open = Some(Open {
            raw: RawTake {
                take_id,
                start_host_ns: host_ns,
                stop_host_ns: 0,
                truncated: false,
                segments: Vec::new(),
                poses: Vec::with_capacity(INITIAL_POSES.min(self.limits.poses)),
                controls: Vec::new(),
                applied: Vec::new(),
                clocks: Vec::new(),
                frames: Vec::new(),
            },
            session: None,
            late: 0,
        });
        true
    }

    /// Ends the take and hands over its buffers (a move: no record is copied). `None` if none
    /// was running.
    pub fn stop(&mut self, host_ns: u64) -> Option<RawTake> {
        let mut raw = self.open.take()?.raw;
        raw.stop_host_ns = host_ns;
        Some(raw)
    }

    #[must_use]
    pub fn is_recording(&self) -> bool {
        self.open.is_some()
    }

    /// The next record starts a new segment even if the session id is the same: the session
    /// was torn down, so the device clock cannot be assumed continuous.
    pub fn break_segment(&mut self) {
        if let Some(open) = &mut self.open {
            open.session = None;
        }
    }

    /// Records a pose. `late` is true if a pose with a higher `seq` was already accepted.
    pub fn push_pose(&mut self, session_id: u32, pose: &Pose, rx_ns: u64, late: bool) {
        let limits = self.limits;
        let Some(open) = &mut self.open else { return };
        let rx_ns = open.rx(rx_ns);
        if open.raw.poses.len() >= limits.poses {
            open.raw.truncated = true;
            return;
        }
        let Some(seg) = open.segment(session_id, rx_ns, limits.notes) else {
            return;
        };
        open.late += u64::from(late);
        open.raw.poses.push(TakePose {
            seg,
            pose: *pose,
            rx_ns,
            late,
        });
    }

    /// Records a `CONTROL_STATE` that changed the state, with the newest accepted pose's
    /// `seq` and `capture_time_ns` (0 and 0 if there is none).
    pub fn push_control(
        &mut self,
        session_id: u32,
        state: &ControlState,
        rx_ns: u64,
        last_pose: (u32, u64),
    ) {
        let max_notes = self.limits.notes;
        let Some(open) = &mut self.open else { return };
        let rx_ns = open.rx(rx_ns);
        let Some(seg) = open.segment(session_id, rx_ns, max_notes) else {
            return;
        };
        if open.has_note_room(max_notes) {
            open.raw.controls.push(TakeControl {
                seg,
                state: *state,
                rx_ns,
                last_pose_seq: last_pose.0,
                last_pose_capture_ns: last_pose.1,
            });
        }
    }

    /// Records the CLOCK estimate after an accepted reply.
    pub fn push_clock(&mut self, session_id: u32, rx_ns: u64, estimate: &ClockEstimate) {
        let max_notes = self.limits.notes;
        let Some(open) = &mut self.open else { return };
        let rx_ns = open.rx(rx_ns);
        let Some(seg) = open.segment(session_id, rx_ns, max_notes) else {
            return;
        };
        if open.has_note_room(max_notes) {
            open.raw.clocks.push(TakeClock {
                seg,
                rx_ns,
                offset_ns: saturate(estimate.offset_ns),
                delay_ns: saturate(estimate.delay_ns),
                jitter_ns: estimate.jitter_ns,
            });
        }
    }

    /// Records that the live rig now applies something different. `pose` is `(session_id, seq)`
    /// of the pose it took effect with, or `None` for a change keyed by host time. A pose-coupled
    /// note goes to the newest segment of that session, even if a newer session has begun since
    /// the pose was read; it is dropped if the take holds no segment of that session (the pose
    /// predates the take, so there is nothing to key it to).
    pub fn note_applied(&mut self, host_ns: u64, pose: Option<(u32, u32)>, kind: AppliedKind) {
        let max_notes = self.limits.notes;
        let Some(open) = &mut self.open else { return };
        let seg = match pose {
            None => open.raw.current_seg(),
            Some((session_id, _)) => {
                let Some(seg) = open
                    .raw
                    .segments
                    .iter()
                    .rposition(|s| s.session_id == session_id)
                else {
                    return;
                };
                index(seg)
            }
        };
        if open.has_note_room(max_notes) {
            open.raw.applied.push(TakeApplied {
                seg,
                host_ns,
                pose_seq: pose.map(|(_, seq)| seq),
                kind,
            });
        }
    }

    /// Records that the timeline showed `frame` at `host_ns`.
    pub fn note_frame(&mut self, host_ns: u64, frame: f64) {
        let max_notes = self.limits.notes;
        let Some(open) = &mut self.open else { return };
        if open.has_note_room(max_notes) {
            open.raw.frames.push(TakeFrame { host_ns, frame });
        }
    }

    #[must_use]
    pub fn status(&self, host_ns: u64) -> TakeStatus {
        self.open
            .as_ref()
            .map_or_else(TakeStatus::default, |open| TakeStatus {
                recording: true,
                take_id: open.raw.take_id,
                elapsed_ns: host_ns.saturating_sub(open.raw.start_host_ns),
                poses: open.raw.poses.len() as u64,
                late: open.late,
                segments: index(open.raw.segments.len()),
                truncated: open.raw.truncated,
            })
    }
}

fn index(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

fn saturate(ns: i128) -> i64 {
    i64::try_from(ns).unwrap_or(if ns < 0 { i64::MIN } else { i64::MAX })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pose(seq: u32) -> Pose {
        Pose {
            seq,
            capture_time_ns: u64::from(seq) * 16_666_667,
            position_m: [seq as f32, 0.0, 1.5],
            orientation: [0.0, 0.0, 0.0, 1.0],
            tracking_state: Pose::TRACKING_NORMAL,
            flags: 0,
        }
    }

    fn recording() -> TakeRecorder {
        let mut rec = TakeRecorder::default();
        assert!(rec.start(1_000, 7));
        rec
    }

    fn scale(motion_scale: f32) -> AppliedKind {
        AppliedKind::Scale { motion_scale }
    }

    #[test]
    fn nothing_is_recorded_outside_a_take() {
        let mut rec = TakeRecorder::default();
        rec.push_pose(1, &pose(1), 10, false);
        rec.push_control(1, &ControlState::default(), 10, (1, 5));
        rec.note_applied(10, None, scale(2.0));
        rec.note_frame(10, 1.0);
        assert!(!rec.is_recording());
        assert_eq!(rec.status(99), TakeStatus::default());
        assert!(rec.stop(99).is_none());
    }

    #[test]
    fn a_second_start_changes_nothing_and_stop_ends_the_take() {
        let mut rec = recording();
        rec.push_pose(1, &pose(1), 1_100, false);
        assert!(!rec.start(5_000, 8), "a take is already running");
        let take = rec.stop(2_000).unwrap();
        assert_eq!(
            (take.take_id, take.start_host_ns, take.stop_host_ns),
            (7, 1_000, 2_000)
        );
        assert_eq!(take.poses.len(), 1);
        assert!(rec.stop(3_000).is_none());
        assert!(rec.start(4_000, 8), "a new take can start after stop");
    }

    #[test]
    fn stop_hands_over_the_buffers_without_copying() {
        let mut rec = recording();
        for seq in 1..=100 {
            rec.push_pose(1, &pose(seq), 1_000 + u64::from(seq), false);
        }
        let Some(open) = &rec.open else {
            panic!("no take")
        };
        let (ptr, cap) = (open.raw.poses.as_ptr(), open.raw.poses.capacity());
        let take = rec.stop(9_000).unwrap();
        assert_eq!(
            take.poses.as_ptr(),
            ptr,
            "the pose buffer must move, not be copied"
        );
        assert_eq!(take.poses.capacity(), cap);
    }

    #[test]
    fn a_new_session_starts_a_new_segment_and_a_break_does_too() {
        let mut rec = recording();
        rec.push_pose(5, &pose(1), 1_100, false);
        rec.push_pose(5, &pose(2), 1_200, false);
        rec.push_pose(6, &pose(1), 2_000, false);
        rec.push_clock(
            6,
            2_100,
            &ClockEstimate {
                offset_ns: 5,
                delay_ns: 3,
                jitter_ns: 1,
                samples: 1,
            },
        );
        rec.break_segment();
        rec.push_pose(6, &pose(1), 3_000, false);
        let take = rec.stop(4_000).unwrap();
        assert_eq!(
            take.segments,
            [
                Segment {
                    session_id: 5,
                    start_host_ns: 1_000
                },
                Segment {
                    session_id: 6,
                    start_host_ns: 2_000
                },
                Segment {
                    session_id: 6,
                    start_host_ns: 3_000
                },
            ]
        );
        let segs: Vec<u32> = take.poses.iter().map(|p| p.seg).collect();
        assert_eq!(segs, [0, 0, 1, 2]);
        assert_eq!(take.clocks[0].seg, 1);
    }

    #[test]
    fn the_first_segment_begins_at_the_take_start() {
        let mut rec = recording();
        rec.push_pose(5, &pose(1), 1_900, false);
        assert_eq!(rec.stop(2_000).unwrap().segments[0].start_host_ns, 1_000);
    }

    #[test]
    fn late_poses_are_kept_flagged_and_counted() {
        let mut rec = recording();
        for (seq, late) in [(1, false), (3, false), (2, true), (3, false)] {
            rec.push_pose(1, &pose(seq), 1_000 + u64::from(seq), late);
        }
        assert_eq!((rec.status(2_000).poses, rec.status(2_000).late), (4, 1));
        let take = rec.stop(2_000).unwrap();
        let lates: Vec<(u32, bool)> = take.poses.iter().map(|p| (p.pose.seq, p.late)).collect();
        assert_eq!(lates, [(1, false), (3, false), (2, true), (3, false)]);
    }

    #[test]
    fn the_pose_cap_truncates_and_keeps_what_was_recorded() {
        let mut rec = TakeRecorder::with_limits(Limits {
            poses: 3,
            notes: 100,
        });
        assert!(rec.start(0, 1));
        for seq in 1..=5 {
            rec.push_pose(1, &pose(seq), u64::from(seq), false);
        }
        assert!(rec.status(9).truncated);
        let take = rec.stop(9).unwrap();
        assert!(take.truncated);
        let seqs: Vec<u32> = take.poses.iter().map(|p| p.pose.seq).collect();
        assert_eq!(seqs, [1, 2, 3]);
    }

    #[test]
    fn a_take_at_the_cap_is_not_truncated() {
        let mut rec = TakeRecorder::with_limits(Limits {
            poses: 2,
            notes: 100,
        });
        assert!(rec.start(0, 1));
        rec.push_pose(1, &pose(1), 1, false);
        rec.push_pose(1, &pose(2), 2, false);
        assert!(!rec.stop(3).unwrap().truncated);
    }

    #[test]
    fn the_note_cap_counts_every_kind_and_the_segments() {
        let mut rec = TakeRecorder::with_limits(Limits {
            poses: 100,
            notes: 4,
        });
        assert!(rec.start(0, 1));
        rec.push_pose(1, &pose(1), 1, false); // segment 1 of 4
        rec.push_control(1, &ControlState::default(), 2, (1, 9)); // 2
        rec.note_applied(3, Some((1, 1)), scale(2.0)); // 3
        rec.note_frame(4, 1.0); // 4
        assert!(!rec.status(5).truncated);
        rec.note_frame(5, 2.0);
        rec.note_applied(6, None, scale(3.0));
        rec.push_control(1, &ControlState::default(), 7, (1, 9));
        rec.push_clock(
            1,
            8,
            &ClockEstimate {
                offset_ns: 0,
                delay_ns: 0,
                jitter_ns: 0,
                samples: 1,
            },
        );
        rec.push_pose(2, &pose(1), 9, false); // would need a segment
        let take = rec.stop(10).unwrap();
        assert!(take.truncated);
        assert_eq!(
            (
                take.controls.len(),
                take.applied.len(),
                take.frames.len(),
                take.clocks.len()
            ),
            (1, 1, 1, 0)
        );
        assert_eq!((take.segments.len(), take.poses.len()), (1, 1));
    }

    #[test]
    fn control_notes_carry_the_last_pose_and_applied_notes_the_current_segment() {
        let mut rec = recording();
        let state = ControlState {
            state_seq: 4,
            motion_scale: Some(2.5),
            ..Default::default()
        };
        rec.note_applied(1_050, None, scale(1.0)); // before any segment
        rec.push_pose(5, &pose(9), 1_100, false);
        rec.push_control(5, &state, 1_200, (9, 150_000_003));
        rec.push_pose(6, &pose(1), 2_000, false);
        rec.note_applied(2_100, Some((6, 1)), AppliedKind::Locks { lock_flags: 3 });
        let take = rec.stop(3_000).unwrap();
        assert_eq!(
            take.controls,
            [TakeControl {
                seg: 0,
                state,
                rx_ns: 1_200,
                last_pose_seq: 9,
                last_pose_capture_ns: 150_000_003,
            }]
        );
        let applied: Vec<(u32, Option<u32>)> =
            take.applied.iter().map(|a| (a.seg, a.pose_seq)).collect();
        assert_eq!(applied, [(0, None), (1, Some(1))]);
    }

    #[test]
    fn a_pose_coupled_note_goes_to_the_segment_of_its_session() {
        let mut rec = recording();
        rec.push_pose(5, &pose(9), 1_100, false);
        rec.push_pose(6, &pose(1), 2_000, false); // session 6 opens segment 1
        // The pose was read in session 5, then the reset happened, then the note arrived.
        rec.note_applied(2_100, Some((5, 9)), scale(2.0));
        rec.note_applied(2_200, Some((6, 1)), scale(3.0));
        rec.note_applied(2_300, Some((7, 1)), scale(4.0)); // no segment of session 7
        rec.break_segment();
        rec.push_pose(5, &pose(1), 3_000, false); // session 5 again: segment 2
        rec.note_applied(3_100, Some((5, 1)), scale(5.0));
        let take = rec.stop(4_000).unwrap();
        let applied: Vec<(u32, Option<u32>)> =
            take.applied.iter().map(|a| (a.seg, a.pose_seq)).collect();
        assert_eq!(applied, [(0, Some(9)), (1, Some(1)), (2, Some(1))]);
    }

    #[test]
    fn a_record_that_arrived_before_the_take_started_is_stamped_at_its_start() {
        let mut rec = recording(); // starts at 1_000
        rec.push_pose(5, &pose(1), 900, false);
        rec.push_control(5, &ControlState::default(), 950, (1, 5));
        rec.break_segment();
        rec.push_clock(
            5,
            990,
            &ClockEstimate {
                offset_ns: 0,
                delay_ns: 0,
                jitter_ns: 0,
                samples: 1,
            },
        );
        rec.push_pose(5, &pose(2), 1_001, false);
        let take = rec.stop(2_000).unwrap();
        let rx: Vec<u64> = take.poses.iter().map(|p| p.rx_ns).collect();
        assert_eq!(rx, [1_000, 1_001]);
        assert_eq!(
            (take.controls[0].rx_ns, take.clocks[0].rx_ns),
            (1_000, 1_000)
        );
        assert_eq!(take.segments[1].start_host_ns, 1_000);
    }

    #[test]
    fn clock_offsets_saturate_instead_of_wrapping() {
        assert_eq!(saturate(i128::MAX), i64::MAX);
        assert_eq!(saturate(i128::MIN), i64::MIN);
        assert_eq!(saturate(-5), -5);
        let mut rec = recording();
        rec.push_clock(
            1,
            1_100,
            &ClockEstimate {
                offset_ns: i128::from(i64::MAX) + 1,
                delay_ns: -1,
                jitter_ns: 9,
                samples: 2,
            },
        );
        let clock = rec.stop(2_000).unwrap().clocks[0];
        assert_eq!(
            (clock.offset_ns, clock.delay_ns, clock.jitter_ns),
            (i64::MAX, -1, 9)
        );
    }

    #[test]
    fn status_reports_elapsed_and_counts_while_recording() {
        let mut rec = recording();
        rec.push_pose(1, &pose(1), 1_100, false);
        assert_eq!(
            rec.status(4_000),
            TakeStatus {
                recording: true,
                take_id: 7,
                elapsed_ns: 3_000,
                poses: 1,
                late: 0,
                segments: 1,
                truncated: false,
            }
        );
        assert_eq!(
            rec.status(500).elapsed_ns,
            0,
            "a clock before the start saturates"
        );
    }
}
