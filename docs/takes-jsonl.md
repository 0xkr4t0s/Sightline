# Take sidecar (JSON Lines), schema v1

The raw data of one recorded take (FR-TAKE-001, FR-TAKE-004), written next to the `.blend` so a take can be re-baked with different smoothing. This is a host file format, not part of VCP (`docs/protocol/vcp.md`). The golden files are `testdata/take/sidecar_v1.jsonl` and `testdata/take/resample_v1.json` (NFR-QA-003), both written by `tools/gen_testdata.py`.

## Encoding

- UTF-8, one JSON object per line, `\n` line endings, no blank lines. The key `t` is the line kind.
- Times are integer nanoseconds, `seq` and counts are integers. Pose and control values are the f32 values received, written as the shortest decimal that reads back as the same f32 (`"1.6"`, `"0.70710677"`). They always contain `.` or `e`. No NaN or Inf. Readers parse them as floats and may keep f32.
- Two clocks. `cap` and every `*_dev_*` value are device time (`capture_time_ns`). `rx`, `host_ns` and `start_host_ns` are host monotonic time. The device-minus-host offset is θ (vcp.md §6.3).
- No host names, device names or file paths. Take and camera names are user data and are allowed.

## Line kinds, in file order

The file is written after the take stops. Lines are in host arrival order (`rx` or `host_ns`), except `take` and the first `seg` come first and `end` comes last. Later `seg` lines sit where the session changed.

| `t` | Keys | Meaning |
|---|---|---|
| `take` | `v` (=1), `take_id`, `name`, `fps_num`, `fps_den`, `frame0`, `play_on_record`, `smoothing`, `applied_start`, `start_host_ns` | One, first. `frame0` is the scene frame at record start. `smoothing` is `{enabled, min_cutoff, beta, d_cutoff}` (the live setting; the raw data is never smoothed) or `null`. `applied_start` is what the live rig applied when the take began: `{zero: {p, yaw}, motion_scale, lock_flags, lens: {lens_mm, focus_distance_m, fstop, dof_on}}` (`focus_distance_m`, `fstop` and `dof_on` may be absent if the lens had none). A re-bake starts from it, not from rig defaults; `applied` lines are changes relative to it. `start_host_ns` is the host time of record start. |
| `seg` | `seg`, `session_id`, `start_host_ns`, `theta_clock_ns`, `theta_hat_ns` | A new segment: right after `take`, and again whenever the VCP session changes. Device clocks differ per session, so θ and θ̂ are per seg. `start_host_ns` is the host time the seg began (seg 0: the take's `start_host_ns`). `theta_clock_ns` is the seg's last CLOCK estimate or `null`; `theta_hat_ns` is the seg's θ̂ below. |
| `pose` | `seg`, `seq`, `cap`, `rx`, `p`[3], `q`[4], `trk`, `fl`, `late` | One POSE (vcp.md §6.1). `q` is x, y, z, w. `trk` is `tracking_state`, `fl` is `flags`. `late` is 1 if a pose with a higher `seq` had already arrived. |
| `ctl` | `seg`, `rx`, `last_seq`, `last_cap`, `state_seq`, then each present group | One CONTROL_STATE (vcp.md §6.2) that changed the state, with the newest pose seen when it arrived. Groups use the §6.2 names: `motion_scale`, `lock_flags`, `origin_epoch`, `thermal_state`, `lens_mm`, `focus_distance_m`, `fstop`, `dof_on`, `tap_u`/`tap_v`/`tap_seq`, `rack_a_m`/`rack_b_m`/`rack_target`/`rack_duration_ms`/`rack_seq`. |
| `applied` | `seg` (with `pose_seq`), `pose_seq` or `host_ns`, `kind`, values | A change to what the live rig applied, relative to `applied_start` and earlier `applied` lines. `kind` is `zero` (`p`, `yaw`), `scale` (`motion_scale`), `locks` (`lock_flags`) or `lens` (`lens_mm`, and any of `focus_distance_m`, `fstop`, `dof_on`). Keyed by `pose_seq` (and `seg`) when the change took effect with that pose (in `seq` order, inclusive); by `host_ns` otherwise (from that host time, device time `host_ns + θ` of the seg active then). |
| `clock` | `seg`, `rx`, `offset_ns`, `delay_ns`, `jitter_ns` | The CLOCK estimate after an accepted reply: θ, round trip and jitter. It belongs to `seg`. |
| `frame` | `host_ns`, `f` | The timeline showed scene frame `f` at `host_ns`, one per playback tick (FR-TAKE-002). Absent unless the take played the timeline. It has no `seg`: the seg whose host interval contains `host_ns` applies. |
| `end` | `poses`, `late`, `truncated`, `dur_ns` | One, last. Counts of `pose` lines and of those with `late` = 1; `truncated` is true if the recorder hit its cap and dropped data; `dur_ns` is the host time from `start_host_ns` to stop. |

## Rules

- A reader ignores unknown `t` kinds and unknown keys. This keeps old readers working when kinds or keys are added (`testdata/take/sidecar_v1.jsonl` has an `x_future` line), and `v` changes only when a change would break them.
- Raw lines are never rewritten. Smoothing, keyframe reduction and later repair (FR-TAKE-005, FR-TAKE-006) write their results elsewhere: the action, its id properties or a separate file. A repair marks its spans there, not here.
- Gaps are derived, not stored: the `seq` values missing between a seg's lowest and highest `seq`.
- A pose is a duplicate if its `(seg, seq)` was already seen (a duplicated datagram); the first arrival is kept, whatever the later one carries. Duplicates stay in the file and count in `end.poses`.
- A seg's host interval runs from its `start_host_ns` to the next seg's `start_host_ns` (the last one to the stop).

## Resample (capture time to scene frames)

Poses are sorted by `(seg, cap)`, never by arrival, then deduplicated. The vectors in `resample_v1.json` resample the raw samples with no smoothing. Samples of different segs are never interpolated together: a frame is resampled within the one seg that owns its time, and the vectors cover a single seg.

- **θ.** Per seg: the seg's `theta_clock_ns` if it is not `null`, else its θ̂ = max over its poses of `cap − rx`. θ is device minus host, so the device time of a host time `h` is `h + θ`.
- **Frame time.** Frames run from `frame0` while the host time is at most `start_host_ns + dur_ns`. A frame's host time `h` picks its seg (the seg whose host interval contains `h`), and its device time is `h + θ` of that seg.
  - Nominal grid: `h = start_host_ns + round((f − frame0)·fps_den·10⁹ / fps_num)`, to the nearest ns, halves up. With one seg this is `t0 + round(…)` with `t0 = start_host_ns + θ`.
  - With `frame` lines: `h` is the host time of the first line showing `f`. A frame shown twice keeps its first time. A frame never shown (dropped by playback) gets a time interpolated linearly in `f` between the nearest shown frames. Frames run to the last frame shown.
- **Pose at time `t`.** Let `a` be the last sample with `cap ≤ t` and `b` the next one.

| Case | Pose | `source` |
|---|---|---|
| no `a` (`t` before the first sample) | the first sample with `trk` = 5 | `before_first` |
| `a.trk ≠ 5` | the last `trk` = 5 sample before `a`, or the first one after `a` if none precedes it (a take that starts limited) | `limited` |
| `a.cap = t` | `a` | `exact` |
| no `b` (after the last sample) | `a` | `held_gap` |
| `b.trk ≠ 5` | `a` | `limited` |
| `b.cap − a.cap` > `max_interp_gap_ns` | `a` | `held_gap` |
| otherwise | position lerp, orientation slerp along the shortest arc (negate `b.q` if the dot product is negative, so the result keeps the sign of `a.q` and is not renormalised to `w ≥ 0`; plain normalised lerp when `1 − dot` < 10⁻¹²), weight `(t − a.cap)/(b.cap − a.cap)` | `interp` |

So a limited span is held from the last normal pose until the next normal pose, `t` in `(cap of the last normal, cap of the next normal)`, and a dropout is held when it is longer than `max_interp_gap_ns` (default 250 ms; the loss of 16 poses at 60 Hz is 283 ms). A frame is never interpolated between a normal pose and a limited one.
- **Output.** `trk` is the limited state that caused a `limited` hold, else 5.
