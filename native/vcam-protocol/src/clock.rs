//! Host-side `CLOCK` reply matching and offset/jitter estimation (vcp.md §6.3; NET-003).
//!
//! Pure bookkeeping over host/device nanosecond timestamps: the caller records each request's
//! `t1` when it is sent and passes `t4` (host clock on receipt) with each reply.

use std::collections::VecDeque;

use crate::ClockSample;

/// A reply must echo one of this many most recent requests.
pub const CLOCK_OUTSTANDING: usize = 4;
/// A reply must arrive less than this long after its request.
pub const CLOCK_REPLY_TIMEOUT_NS: u64 = 2_000_000_000;
/// Accepted samples kept for the estimate (8 s at the 1 Hz request rate).
pub const CLOCK_WINDOW: usize = 8;

/// Why a `CLOCK` reply was not used.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClockReject {
    /// `t1` is not an outstanding request (unknown, evicted, or already answered).
    Unmatched,
    /// Arrived 2 s or more after its request.
    Expired,
    /// Impossible timestamps: `t4 < t1`, `t3 < t2`, or a negative round trip.
    Invalid,
}

/// Offset and jitter over the current window, in ns.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ClockEstimate {
    /// θ of the lowest-delay sample in the window (newest on ties): device clock − host clock.
    pub offset_ns: i128,
    /// Round-trip delay δ of that sample.
    pub delay_ns: i128,
    /// Integer RMS of every windowed θ around `offset_ns`.
    pub jitter_ns: u64,
    /// Samples in the window (1..=`CLOCK_WINDOW`).
    pub samples: usize,
}

impl ClockEstimate {
    /// Maps a device-clock time (for example `POSE.capture_time_ns`) onto the host clock.
    #[must_use]
    pub fn host_time_ns(&self, device_time_ns: u64) -> i128 {
        i128::from(device_time_ns) - self.offset_ns
    }
}

/// Outstanding requests and the sliding sample window of one session.
#[derive(Clone, Debug)]
pub struct ClockEstimator {
    outstanding: VecDeque<u64>,
    window: VecDeque<ClockSample>,
}

impl Default for ClockEstimator {
    fn default() -> Self {
        Self {
            outstanding: VecDeque::with_capacity(CLOCK_OUTSTANDING),
            window: VecDeque::with_capacity(CLOCK_WINDOW),
        }
    }
}

impl ClockEstimator {
    /// Records a request sent at host time `t1`, evicting the oldest beyond four.
    pub fn request(&mut self, t1: u64) {
        if self.outstanding.len() == CLOCK_OUTSTANDING {
            self.outstanding.pop_front();
        }
        self.outstanding.push_back(t1);
    }

    /// Checks a reply received at host time `t4`. A matching `t1` is consumed even when the
    /// reply is then rejected, so each request yields at most one sample.
    pub fn reply(
        &mut self,
        t1: u64,
        t2: u64,
        t3: u64,
        t4: u64,
    ) -> Result<ClockSample, ClockReject> {
        let index = self
            .outstanding
            .iter()
            .position(|&t| t == t1)
            .ok_or(ClockReject::Unmatched)?;
        self.outstanding.remove(index);
        let elapsed = t4.checked_sub(t1).ok_or(ClockReject::Invalid)?;
        if elapsed >= CLOCK_REPLY_TIMEOUT_NS {
            return Err(ClockReject::Expired);
        }
        let sample = ClockSample::from_timestamps(t1, t2, t3, t4);
        if t3 < t2 || sample.delay_ns < 0 {
            return Err(ClockReject::Invalid);
        }
        if self.window.len() == CLOCK_WINDOW {
            self.window.pop_front();
        }
        self.window.push_back(sample);
        Ok(sample)
    }

    /// None until the first accepted reply.
    #[must_use]
    pub fn estimate(&self) -> Option<ClockEstimate> {
        // `min_by_key` keeps the first minimum; iterating newest-first prefers the newest.
        let best = self.window.iter().rev().min_by_key(|s| s.delay_ns)?;
        let sum = self.window.iter().fold(0u128, |sum, s| {
            let d = u128::from(
                u64::try_from((s.offset_ns - best.offset_ns).unsigned_abs()).unwrap_or(u64::MAX),
            );
            sum.saturating_add(d * d)
        });
        let mean = sum / self.window.len() as u128;
        Some(ClockEstimate {
            offset_ns: best.offset_ns,
            delay_ns: best.delay_ns,
            jitter_ns: u64::try_from(mean.isqrt()).unwrap_or(u64::MAX),
            samples: self.window.len(),
        })
    }
}
