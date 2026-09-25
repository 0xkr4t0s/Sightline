//! Per-session freshness rules (vcp.md §6): newest sequence wins; origin resets on any change.

/// Accepts a sequence number only if it is greater than every one accepted before
/// (`POSE.seq`, `CONTROL_STATE.state_seq`, `STATUS.status_seq`). Create one per session.
#[derive(Clone, Copy, Debug, Default)]
pub struct SeqFilter {
    last: Option<u32>,
}

impl SeqFilter {
    /// Returns `true` (and remembers `seq`) if `seq` is newer than the last accepted value.
    pub fn accept(&mut self, seq: u32) -> bool {
        if self.last.is_some_and(|last| seq <= last) {
            return false;
        }
        self.last = Some(seq);
        true
    }
}

/// Tracks `CONTROL_STATE.origin_epoch`: any change from the previously seen value, including
/// the 65535 → 0 wrap, is a Set-origin request (vcp.md §6.2). The first value seen is not.
#[derive(Clone, Copy, Debug, Default)]
pub struct EpochWatcher {
    last: Option<u16>,
}

impl EpochWatcher {
    /// Returns `true` if `epoch` differs from the previous one.
    pub fn changed(&mut self, epoch: u16) -> bool {
        let changed = self.last.is_some_and(|last| last != epoch);
        self.last = Some(epoch);
        changed
    }
}
