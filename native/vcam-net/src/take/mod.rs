//! Take recording: the raw data of one recorded take (FR-TAKE-001; format in
//! `docs/takes-jsonl.md`). Resampling, the sidecar writer and reduction build on it in later
//! tasks (3.1c-3.1e).

mod recorder;

pub use recorder::{
    AppliedKind, Limits, RawTake, Segment, TakeApplied, TakeClock, TakeControl, TakeFrame,
    TakePose, TakeRecorder, TakeStatus,
};
