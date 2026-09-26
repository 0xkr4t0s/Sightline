//! Adaptive viewfinder quality (task 2.2d2a; NET-VID-005).
//!
//! Every 500 ms the device reports how the stream arrives (`VIDEO_REPORT`, vcp.md §6.6).
//! [`VideoAdapter`] turns each report into the loss of its interval, as §6.6 defines it, and
//! applies NET-VID-005: on sustained loss or high motion-to-photon it lowers the JPEG quality,
//! and once the quality is at its floor it lowers the resolution; while the stream stays clean
//! it raises the resolution first, then the quality, back to the user's choice. Pure: no I/O and
//! no clock. The caller feeds it the frames the sender finished and the device's reports, and
//! applies the returned level. One adapter per device session, like the session's `frame_id`s.

use std::collections::VecDeque;
use std::io;

use vcam_protocol::VideoReport;

/// Quality change per step.
pub const QUALITY_STEP: u8 = 10;
/// Lowest quality the adapter picks before it lowers the resolution instead (or the user's
/// quality, if that is lower). S-2a: quality 50 still decodes cleanly at 540p.
pub const QUALITY_FLOOR: u8 = 50;
/// A report whose `m2p_p95_ms` is above this is bad: NFR-LAT-003's Stage A limit.
pub const M2P_LIMIT_MS: u16 = 120;
/// ... and at most this (80 % of the limit), or not measured, allows recovery.
const M2P_CLEAN_MS: u16 = 96;
/// An interval with fewer finished frames says nothing about loss.
const MIN_FRAMES: u64 = 5;
/// More than this share of an interval's frames lost is bad.
const LOSS_BAD_PERCENT: u64 = 10;
/// At most this share lost is clean.
const LOSS_CLEAN_PERCENT: u64 = 2;
/// Consecutive bad reports (1 s) before a step down: one late burst isn't sustained loss.
const BAD_TO_LOWER: u32 = 2;
/// Consecutive clean reports (5 s) before a step up, so the stream doesn't oscillate.
const CLEAN_TO_RAISE: u32 = 10;
/// Reports ignored after a change, while frames of the old level are still in flight.
const SETTLE: u32 = 2;
/// Finished frame ids kept to find those beyond the device's `newest_frame_id`. The device
/// trails the sender by the few frames in flight, far fewer than this.
const RECENT: usize = 64;

/// What the stream should be sent at.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StreamLevel {
    /// JPEG quality, 1–100.
    pub quality: u8,
    /// Resolution steps below the user's choice (0 = the user's resolution). The caller maps
    /// steps to its resolution list.
    pub resolution_drop: u8,
}

/// Why the level changed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AdaptReason {
    /// More than 10 % of the frames lost in consecutive reports; the figures are the last
    /// report's interval.
    Loss { lost: u64, expected: u64 },
    /// Motion-to-photon p95 above [`M2P_LIMIT_MS`] in consecutive reports (the last one's).
    MotionToPhoton { m2p_p95_ms: u16 },
    /// The stream stayed clean long enough to step back up.
    Recovered,
}

/// One change of the level, for both UIs (NET-VID-005).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AdaptChange {
    /// The report that triggered it.
    pub report_seq: u32,
    pub from: StreamLevel,
    pub to: StreamLevel,
    pub reason: AdaptReason,
}

/// Loss in the interval ending at one report (vcp.md §6.6).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IntervalLoss {
    pub report_seq: u32,
    /// Frames the host finished sending with ids up to the report's `newest_frame_id`, not
    /// counted in an earlier interval.
    pub expected: u64,
    pub lost: u64,
    pub m2p_p95_ms: u16,
}

/// Session totals and the latest decisions of a [`VideoAdapter`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AdaptStats {
    pub level: StreamLevel,
    /// Frames counted in report intervals so far.
    pub expected: u64,
    /// Of those, frames the device hasn't completed.
    pub lost: u64,
    pub last_interval: Option<IntervalLoss>,
    pub changes: u32,
    pub last_change: Option<AdaptChange>,
}

/// NET-VID-005's controller for one device session. See the module docs.
#[derive(Debug)]
pub struct VideoAdapter {
    quality: u8,
    max_resolution_drop: u8,
    level: StreamLevel,
    /// Newest finished frame ids, oldest first, at most [`RECENT`].
    recent: VecDeque<u32>,
    finished: u64,
    /// Finished frames counted in an interval so far.
    counted: u64,
    /// `counted` minus the device's `frames_complete` at the last report.
    lost: u64,
    last_report_seq: u32,
    last_interval: Option<IntervalLoss>,
    bad: u32,
    clean: u32,
    settle: u32,
    changes: u32,
    last_change: Option<AdaptChange>,
}

impl VideoAdapter {
    /// Starts at the user's `quality` (1–100) and resolution; the resolution may drop by up to
    /// `max_resolution_drop` steps (0 = never lower it).
    ///
    /// # Errors
    /// `InvalidInput` for a quality outside 1–100.
    pub fn new(quality: u8, max_resolution_drop: u8) -> io::Result<Self> {
        if !(1..=100).contains(&quality) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("JPEG quality must be 1-100, got {quality}"),
            ));
        }
        Ok(Self {
            quality,
            max_resolution_drop,
            level: StreamLevel {
                quality,
                resolution_drop: 0,
            },
            recent: VecDeque::with_capacity(RECENT),
            finished: 0,
            counted: 0,
            lost: 0,
            last_report_seq: 0,
            last_interval: None,
            bad: 0,
            clean: 0,
            settle: 0,
            changes: 0,
            last_change: None,
        })
    }

    /// The level to send the next frame at.
    #[must_use]
    pub fn level(&self) -> StreamLevel {
        self.level
    }

    #[must_use]
    pub fn stats(&self) -> AdaptStats {
        AdaptStats {
            level: self.level,
            expected: self.counted,
            lost: self.lost,
            last_interval: self.last_interval,
            changes: self.changes,
            last_change: self.last_change,
        }
    }

    /// Records a frame the sender handed to the socket in full (`VideoSent::frame_id`). Frames
    /// given up part-way are not recorded: §6.6 counts only finished frames.
    pub fn frame_sent(&mut self, frame_id: u32) {
        if self.recent.len() == RECENT {
            self.recent.pop_front();
        }
        self.recent.push_back(frame_id);
        self.finished += 1;
    }

    /// Takes the device's report and returns the level change it causes, if any. Reports with
    /// a `report_seq` not above the last one are ignored, so the caller may pass the receiver's
    /// newest report on every poll.
    pub fn report(&mut self, report: &VideoReport) -> Option<AdaptChange> {
        if report.report_seq <= self.last_report_seq {
            return None;
        }
        self.last_report_seq = report.report_seq;
        let interval = self.count(report);
        self.last_interval = Some(interval);
        if self.settle > 0 {
            self.settle -= 1;
            return None;
        }
        let enough = interval.expected >= MIN_FRAMES;
        let lossy = enough && interval.lost * 100 > LOSS_BAD_PERCENT * interval.expected;
        let slow = interval.m2p_p95_ms > M2P_LIMIT_MS;
        let clean = enough
            && interval.lost * 100 <= LOSS_CLEAN_PERCENT * interval.expected
            && interval.m2p_p95_ms <= M2P_CLEAN_MS;
        let (to, reason) = if lossy || slow {
            self.clean = 0;
            self.bad += 1;
            if self.bad < BAD_TO_LOWER {
                return None;
            }
            self.bad = 0;
            let reason = if lossy {
                AdaptReason::Loss {
                    lost: interval.lost,
                    expected: interval.expected,
                }
            } else {
                AdaptReason::MotionToPhoton {
                    m2p_p95_ms: interval.m2p_p95_ms,
                }
            };
            (self.lower()?, reason)
        } else if clean {
            self.bad = 0;
            self.clean += 1;
            if self.clean < CLEAN_TO_RAISE {
                return None;
            }
            self.clean = 0;
            (self.raise()?, AdaptReason::Recovered)
        } else {
            self.bad = 0;
            self.clean = 0;
            return None;
        };
        let change = AdaptChange {
            report_seq: report.report_seq,
            from: self.level,
            to,
            reason,
        };
        self.level = to;
        self.settle = SETTLE;
        self.changes += 1;
        self.last_change = Some(change);
        Some(change)
    }

    /// §6.6 loss: frames finished with ids up to `newest_frame_id` that no earlier interval
    /// counted, minus the growth of `frames_complete`. The loss is kept as a session total, so
    /// a frame still arriving at one report counts as lost there and is taken back (not counted
    /// again) once a later report shows it complete.
    fn count(&mut self, report: &VideoReport) -> IntervalLoss {
        let beyond = self
            .recent
            .iter()
            .filter(|&&id| id > report.newest_frame_id)
            .count();
        let upto = self.finished.saturating_sub(beyond as u64);
        let expected = upto.saturating_sub(self.counted);
        self.counted = self.counted.max(upto);
        let lost = self
            .counted
            .saturating_sub(u64::from(report.frames_complete));
        let interval_lost = lost.saturating_sub(self.lost);
        self.lost = lost;
        IntervalLoss {
            report_seq: report.report_seq,
            expected,
            lost: interval_lost,
            m2p_p95_ms: report.m2p_p95_ms,
        }
    }

    /// Quality first, down to the floor; then resolution. The level's quality never exceeds
    /// the user's, so a user quality below the floor goes straight to resolution.
    fn lower(&self) -> Option<StreamLevel> {
        let StreamLevel {
            quality,
            resolution_drop,
        } = self.level;
        if quality > QUALITY_FLOOR {
            Some(StreamLevel {
                quality: quality.saturating_sub(QUALITY_STEP).max(QUALITY_FLOOR),
                resolution_drop,
            })
        } else if resolution_drop < self.max_resolution_drop {
            Some(StreamLevel {
                quality,
                resolution_drop: resolution_drop + 1,
            })
        } else {
            None
        }
    }

    /// The reverse of [`Self::lower`]: resolution first, then quality up to the user's.
    fn raise(&self) -> Option<StreamLevel> {
        let StreamLevel {
            quality,
            resolution_drop,
        } = self.level;
        if resolution_drop > 0 {
            Some(StreamLevel {
                quality,
                resolution_drop: resolution_drop - 1,
            })
        } else if quality < self.quality {
            Some(StreamLevel {
                quality: quality.saturating_add(QUALITY_STEP).min(self.quality),
                resolution_drop,
            })
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Drives an adapter like a sender and a device: each call is one 500 ms interval.
    struct Link {
        adapter: VideoAdapter,
        next_id: u32,
        complete: u32,
        report_seq: u32,
    }

    impl Link {
        fn new(quality: u8, max_drop: u8) -> Self {
            Self {
                adapter: VideoAdapter::new(quality, max_drop).unwrap(),
                next_id: 1,
                complete: 0,
                report_seq: 0,
            }
        }

        /// Sends `sent` frames; the device completes all but `lost` and reports.
        fn interval(&mut self, sent: u32, lost: u32, m2p: u16) -> Option<AdaptChange> {
            for _ in 0..sent {
                self.adapter.frame_sent(self.next_id);
                self.next_id += 1;
            }
            self.complete += sent - lost;
            self.report_seq += 1;
            self.adapter.report(&VideoReport {
                report_seq: self.report_seq,
                newest_frame_id: self.next_id - 1,
                frames_complete: self.complete,
                m2p_p95_ms: m2p,
            })
        }

        fn level(&self) -> (u8, u8) {
            let l = self.adapter.level();
            (l.quality, l.resolution_drop)
        }
    }

    fn report(report_seq: u32, newest: u32, complete: u32) -> VideoReport {
        VideoReport {
            report_seq,
            newest_frame_id: newest,
            frames_complete: complete,
            m2p_p95_ms: 0,
        }
    }

    fn last(a: &VideoAdapter) -> (u64, u64) {
        let i = a.stats().last_interval.unwrap();
        (i.expected, i.lost)
    }

    #[test]
    fn loss_follows_vcp_6_6() {
        let mut a = VideoAdapter::new(80, 1).unwrap();
        // Frames 1–15 finished; the device completed 13 (two lost, one with no fragment at all).
        (1..=15).for_each(|id| a.frame_sent(id));
        assert_eq!(a.report(&report(1, 15, 13)), None);
        assert_eq!(last(&a), (15, 2));
        // 16–20 finished, 19 given up part-way (never recorded). The device has seen up to 18:
        // 19 and 20 belong to a later interval.
        [16, 17, 18, 20].into_iter().for_each(|id| a.frame_sent(id));
        a.report(&report(2, 18, 16));
        assert_eq!(last(&a), (3, 0));
        // Up to 20: only 20 is new (19 was never finished); the device completed it.
        a.report(&report(3, 20, 17));
        assert_eq!(last(&a), (1, 0));
        let s = a.stats();
        assert_eq!((s.expected, s.lost), (19, 2));
    }

    #[test]
    fn a_frame_still_arriving_is_lost_once_then_taken_back() {
        let mut a = VideoAdapter::new(80, 1).unwrap();
        (1..=10).for_each(|id| a.frame_sent(id));
        // Frame 10's first fragment is in, the rest still on the way.
        a.report(&report(1, 10, 9));
        assert_eq!(last(&a), (10, 1));
        (11..=20).for_each(|id| a.frame_sent(id));
        // 10 completed after all, and 11–20 too: this interval lost nothing, and the total is 0.
        a.report(&report(2, 20, 20));
        assert_eq!(last(&a), (10, 0));
        assert_eq!(a.stats().lost, 0);
        // A real loss afterwards counts in full, not against the taken-back frame.
        (21..=30).for_each(|id| a.frame_sent(id));
        a.report(&report(3, 30, 29));
        assert_eq!(last(&a), (10, 1));
    }

    #[test]
    fn frames_finished_late_count_in_the_next_interval() {
        let mut a = VideoAdapter::new(80, 1).unwrap();
        (1..=9).for_each(|id| a.frame_sent(id));
        // The device already has all of frame 10 while the sender hasn't recorded it yet.
        a.report(&report(1, 10, 10));
        assert_eq!(last(&a), (9, 0));
        a.frame_sent(10);
        a.report(&report(2, 10, 10));
        assert_eq!(last(&a), (1, 0));
        assert_eq!(a.stats().expected, 10);
    }

    #[test]
    fn old_or_repeated_reports_are_ignored() {
        let mut a = VideoAdapter::new(80, 1).unwrap();
        (1..=10).for_each(|id| a.frame_sent(id));
        a.report(&report(2, 10, 5));
        let before = a.stats();
        a.report(&report(2, 10, 5));
        a.report(&report(1, 10, 0));
        assert_eq!(a.stats(), before);
    }

    #[test]
    fn sustained_loss_lowers_quality_then_resolution() {
        let mut link = Link::new(80, 2);
        // One bad interval is a burst, not sustained loss.
        assert_eq!(link.interval(15, 3, 0), None);
        assert_eq!(link.interval(15, 0, 0), None);
        assert_eq!(link.interval(15, 3, 0), None);
        let change = link.interval(15, 2, 0).unwrap();
        assert_eq!(
            change,
            AdaptChange {
                report_seq: 4,
                from: StreamLevel {
                    quality: 80,
                    resolution_drop: 0
                },
                to: StreamLevel {
                    quality: 70,
                    resolution_drop: 0
                },
                reason: AdaptReason::Loss {
                    lost: 2,
                    expected: 15
                },
            }
        );
        // 10 % exactly isn't above the threshold.
        for _ in 0..6 {
            assert_eq!(link.interval(20, 2, 0), None);
        }
        let mut levels = vec![link.level()];
        for _ in 0..40 {
            if link.interval(15, 5, 0).is_some() {
                levels.push(link.level());
            }
        }
        assert_eq!(
            levels,
            [(70, 0), (60, 0), (50, 0), (50, 1), (50, 2)],
            "quality to its floor first, then resolution, and no further"
        );
        let s = link.adapter.stats();
        assert_eq!(s.changes, 5);
        assert_eq!(s.last_change.map(|c| c.to), Some(link.adapter.level()));
    }

    #[test]
    fn after_a_change_the_next_reports_settle() {
        let mut link = Link::new(80, 1);
        link.interval(15, 5, 0);
        assert!(link.interval(15, 5, 0).is_some());
        // Frames sent at the old level are still in flight: two reports don't count.
        assert_eq!(link.interval(15, 5, 0), None);
        assert_eq!(link.interval(15, 5, 0), None);
        assert_eq!(link.interval(15, 5, 0), None);
        assert_eq!(link.level(), (70, 0));
        assert!(link.interval(15, 5, 0).is_some());
    }

    #[test]
    fn high_motion_to_photon_lowers_too() {
        let mut link = Link::new(80, 1);
        // At the limit is fine, however long; unmeasured (0) is ignored.
        for _ in 0..5 {
            assert_eq!(link.interval(15, 0, M2P_LIMIT_MS), None);
            assert_eq!(link.interval(15, 0, M2P_LIMIT_MS), None);
            assert_eq!(link.interval(15, 0, 0), None);
        }
        link.interval(15, 0, 150);
        let change = link.interval(15, 0, 121).unwrap();
        assert_eq!(
            change.reason,
            AdaptReason::MotionToPhoton { m2p_p95_ms: 121 }
        );
        assert_eq!(link.level(), (70, 0));
    }

    #[test]
    fn a_clean_stream_recovers_resolution_first_then_quality() {
        let mut link = Link::new(75, 1);
        for _ in 0..30 {
            link.interval(15, 5, 0);
        }
        assert_eq!(link.level(), (50, 1));
        let mut levels = vec![];
        let mut clean_reports = 0;
        for _ in 0..80 {
            clean_reports += 1;
            if let Some(change) = link.interval(15, 0, 0) {
                assert_eq!(change.reason, AdaptReason::Recovered);
                levels.push((link.level(), clean_reports));
                clean_reports = 0;
            }
        }
        assert_eq!(
            levels,
            [((50, 0), 10), ((60, 0), 12), ((70, 0), 12), ((75, 0), 12)],
            "10 clean reports per step (plus 2 settling), resolution first, up to the user's quality"
        );
    }

    #[test]
    fn middling_reports_neither_lower_nor_raise() {
        let mut link = Link::new(80, 1);
        link.interval(20, 10, 0);
        link.interval(20, 10, 0);
        assert_eq!(link.level(), (70, 0));
        link.interval(20, 0, 0);
        link.interval(20, 0, 0);
        // 5 % loss, M2P between 96 and 120 ms, or too few frames: no verdict, and each one
        // breaks a run of clean or bad reports.
        for _ in 0..12 {
            for _ in 0..9 {
                assert_eq!(link.interval(20, 0, 0), None);
            }
            match link.adapter.stats().last_interval.unwrap().report_seq % 3 {
                0 => assert_eq!(link.interval(20, 1, 0), None),
                1 => assert_eq!(link.interval(20, 0, 110), None),
                _ => assert_eq!(link.interval(4, 0, 0), None),
            }
        }
        assert_eq!(link.level(), (70, 0));
        for _ in 0..3 {
            assert_eq!(link.interval(20, 3, 0), None);
            assert_eq!(link.interval(4, 4, 0), None);
        }
        assert_eq!(link.level(), (70, 0));
    }

    #[test]
    fn a_user_quality_below_the_floor_goes_straight_to_resolution() {
        let mut link = Link::new(40, 1);
        link.interval(15, 5, 0);
        link.interval(15, 5, 0);
        assert_eq!(link.level(), (40, 1));
        let mut still = Link::new(40, 0);
        for _ in 0..10 {
            assert_eq!(still.interval(15, 5, 0), None);
        }
        assert_eq!(still.level(), (40, 0));
    }

    #[test]
    fn quality_outside_1_to_100_is_rejected() {
        for q in [0, 101] {
            let e = VideoAdapter::new(q, 0).unwrap_err();
            assert_eq!(e.kind(), io::ErrorKind::InvalidInput);
        }
        assert!(VideoAdapter::new(1, 0).is_ok() && VideoAdapter::new(100, 0).is_ok());
    }
}
