//! The real `vcam-fake-iphone` binary against a real `ControlServer` (task 1.2.7; SRS §11).
#![allow(clippy::unwrap_used, clippy::expect_used)] // test code: a panic is a test failure

use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

use vcam_net::{
    ControlEvent, ControlServer, HostStatus, MemoryStore, ServerConfig, VideoFrameMeta,
};
use vcam_protocol::{AppliedLens, ControlState, RackFocus, TapFocus, VideoFragment};

const MOTION: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../testdata/motion/scripted.bin"
);
const FRAMES: u32 = 390;
const LAST_POSITION: [f32; 3] = [-2.0, 0.0, 3.1];

/// A unique scratch directory, removed on drop. The name is built from characters every OS
/// accepts (an `Instant`'s `Debug` form contains `:`, which Windows rejects).
struct Scratch(PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!(
            "vcam-fake-iphone-{tag}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
    fn state(&self) -> String {
        self.0
            .join("fake-iphone.key")
            .to_string_lossy()
            .into_owned()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn server() -> ControlServer {
    ControlServer::start(
        "127.0.0.1:0".parse().unwrap(),
        ServerConfig::new([0xF0; 16], 0),
        Box::new(MemoryStore::default()),
    )
    .unwrap()
}

fn spawn(server: &ControlServer, state: &str, code: Option<&str>, extra: &[&str]) -> Child {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_vcam-fake-iphone"));
    cmd.args([
        "--host",
        &server.local_addr().to_string(),
        "--state",
        state,
        "--motion",
        MOTION,
    ]);
    if let Some(code) = code {
        cmd.args(["--code", code]);
    }
    cmd.args(extra)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    cmd.spawn().unwrap()
}

/// Runs `child` to completion while `each` observes the server; returns its output.
fn drive(mut child: Child, mut each: impl FnMut()) -> Output {
    let deadline = Instant::now() + Duration::from_secs(30);
    while child.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "fake iPhone did not finish");
        each();
        std::thread::sleep(Duration::from_millis(5));
    }
    child.wait_with_output().unwrap()
}

fn field(stdout: &str, key: &str) -> u64 {
    let done = stdout
        .lines()
        .find(|l| l.starts_with("FAKE_IPHONE_DONE"))
        .expect(stdout);
    done.split_whitespace()
        .find_map(|kv| kv.strip_prefix(&format!("{key}=")))
        .expect(key)
        .parse()
        .unwrap()
}

#[test]
fn pairs_streams_the_script_answers_clock_and_reconnects_without_a_code() {
    let server = server();
    let scratch = Scratch::new("stream");
    let code = server.enable_pairing().unwrap();
    let child = spawn(
        &server,
        &scratch.state(),
        Some(&code),
        &["--rate", "600", "--linger", "2.5"],
    );
    let (mut events, mut last_pose, mut control, mut clock) = (Vec::new(), None, None, None);
    let out = drive(child, || {
        while let Some(e) = server.try_event() {
            if let ControlEvent::SessionStarted { session_id, .. } = &e {
                // What Blender would publish after applying a pose (vcp.md §6.4).
                let status = HostStatus {
                    applied_pose_seq: 42,
                    control_ack: 1,
                    error_code: 0,
                    camera_name: Some("Cam".into()),
                    applied_lens: None,
                };
                server.update_status(*session_id, status).unwrap();
            }
            events.push(e);
        }
        if let Some(p) = server.latest_pose() {
            last_pose = Some(p);
        }
        if let Some(c) = server.latest_control() {
            control = Some(c);
        }
        if let Some(c) = server.stats().clock {
            clock = Some(c);
        }
    });
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "{stdout}\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(stdout.contains("FAKE_IPHONE_PAIRED"), "{stdout}");

    assert!(
        matches!(&events[0], ControlEvent::Paired { device_name, .. } if device_name == "Fake iPhone"),
        "{events:?}"
    );
    assert!(
        matches!(&events[1], ControlEvent::SessionStarted { .. }),
        "{events:?}"
    );
    // Closing TCP ends the session; the host reports it shortly after the process exits.
    let deadline = Instant::now() + Duration::from_secs(2);
    while !matches!(events.last(), Some(ControlEvent::SessionEnded { .. })) {
        assert!(Instant::now() < deadline, "no SessionEnded: {events:?}");
        events.extend(server.try_event());
        std::thread::sleep(Duration::from_millis(5));
    }

    // The host received the whole script; the newest pose is the last keypose.
    let last = last_pose.unwrap().pose;
    assert_eq!(last.seq, FRAMES);
    assert_eq!(last.position_m, LAST_POSITION);
    assert_eq!(field(&stdout, "poses"), u64::from(FRAMES));
    // The device sent a complete CONTROL_STATE and answered CLOCK from its own clock.
    let c = control.unwrap().state;
    assert_eq!(
        (c.state_seq, c.motion_scale, c.lock_flags, c.origin_epoch),
        (1, Some(1.0), Some(0), Some(0))
    );
    assert_eq!(c.thermal_state, Some(0));
    assert!(field(&stdout, "clock_replies") >= 2, "{stdout}");
    let clock = clock.expect("host estimated the clock offset");
    // The fake device clock runs 1000 s ahead of its process start; the host's starts at 0.
    assert!(clock.offset_ns > 900_000_000_000, "{clock:?}");
    // The device saw the host's authenticated STATUS, including what the host applied.
    assert!(field(&stdout, "status_seq") >= 2, "{stdout}");
    assert_eq!(field(&stdout, "applied_pose_seq"), 42, "{stdout}");
    assert_eq!(field(&stdout, "control_ack"), 1, "{stdout}");
    assert!(stdout.contains("camera=Cam"), "{stdout}");

    // The stored pairing reconnects without a code: a session, no new pairing.
    let child = spawn(&server, &scratch.state(), None, &["--rate", "2000"]);
    let mut again = Vec::new();
    let out = drive(child, || {
        again.extend(std::iter::from_fn(|| server.try_event()))
    });
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(
        matches!(&again[0], ControlEvent::SessionStarted { device_name, .. } if device_name == "Fake iPhone"),
        "{again:?}"
    );
    assert!(
        !again
            .iter()
            .any(|e| matches!(e, ControlEvent::Paired { .. })),
        "{again:?}"
    );
}

#[test]
fn wrong_code_fails_cleanly_and_stores_nothing() {
    let server = server();
    let scratch = Scratch::new("wrong");
    let code = server.enable_pairing().unwrap();
    let wrong = format!("{:06}", (code.parse::<u32>().unwrap() + 1) % 1_000_000);
    let out = drive(spawn(&server, &scratch.state(), Some(&wrong), &[]), || {});
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("vcam-fake-iphone: error: host refused: ERROR"),
        "{stderr}"
    );
    assert!(!std::path::Path::new(&scratch.state()).exists());

    // No stored pairing and no code: a clear error, nothing sent.
    let out = drive(spawn(&server, &scratch.state(), None, &[]), || {});
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("no stored pairing"));
}

#[test]
fn scripted_controls_reach_the_host_in_order() {
    let server = server();
    let scratch = Scratch::new("controls");
    let code = server.enable_pairing().unwrap();
    // The host keeps only the latest control state and this test samples it every 5 ms, so state 1
    // must stay current for many samples before Set origin replaces it: frame 200 of the 390-frame
    // script at 600 Hz is ~330 ms in. (At 2000 Hz and frame 10 it was 5 ms: one sample, and flaky.)
    let args = [
        "--rate",
        "600",
        "--linger",
        "0.6",
        "--scale",
        "2",
        "--locks",
        "5",
        "--set-origin-at",
        "200",
    ];
    let child = spawn(&server, &scratch.state(), Some(&code), &args);
    let mut states = Vec::new();
    let out = drive(child, || {
        if let Some(c) = server.latest_control() {
            let c = c.state;
            let seen = (c.state_seq, c.motion_scale, c.lock_flags, c.origin_epoch);
            if states.last() != Some(&seen) {
                states.push(seen);
            }
        }
    });
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    // The complete first state, then Set origin as a new state with the next epoch.
    assert_eq!(
        states,
        [
            (1, Some(2.0), Some(5), Some(0)),
            (2, Some(2.0), Some(5), Some(1))
        ],
        "{states:?}"
    );

    let out = drive(
        spawn(&server, &scratch.state(), None, &["--scale", "5000"]),
        || {},
    );
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("--scale must be in [0.001, 1000]"));
}

#[test]
fn thermal_transition_reaches_host_with_new_sequence_and_ack() {
    let server = server();
    let scratch = Scratch::new("thermal");
    let code = server.enable_pairing().unwrap();
    let child = spawn(
        &server,
        &scratch.state(),
        Some(&code),
        &[
            "--rate",
            "300",
            "--linger",
            "1",
            "--thermal",
            "2",
            "--thermal-at",
            "200:2",
        ],
    );
    let mut states = Vec::new();
    let out = drive(child, || {
        if let Some(c) = server.latest_control() {
            let c = c.state;
            let seen = (c.state_seq, c.thermal_state);
            if states.last() != Some(&seen) {
                states.push(seen);
            }
            server
                .update_status(
                    server.stats().session_id.unwrap(),
                    HostStatus {
                        applied_pose_seq: 0,
                        control_ack: c.state_seq,
                        error_code: 0,
                        camera_name: Some("Cam".into()),
                        applied_lens: None,
                    },
                )
                .unwrap();
        }
    });
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "{stdout}\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(states, [(1, Some(0)), (2, Some(2))]);
    assert!(field(&stdout, "control_ack") >= 2, "{stdout}");
}

#[test]
fn lens_controls_reach_the_host_and_the_applied_lens_is_reported() {
    let server = server();
    let scratch = Scratch::new("lens");
    let code = server.enable_pairing().unwrap();
    let args = [
        "--rate",
        "300",
        "--linger",
        "1",
        "--lens",
        "85",
        "--focus",
        "3",
        "--fstop",
        "2.8",
        "--dof",
        "1",
        "--tap",
        "0.25,0.75@100",
        "--rack",
        "2,8,B,1200@200",
    ];
    let child = spawn(&server, &scratch.state(), Some(&code), &args);
    // What the host would report after applying the request to a 36 mm, 3:2 camera.
    let applied = AppliedLens {
        lens_mm: 85.0,
        focus_distance_m: 3.0,
        fstop: 2.8,
        dof_on: true,
        sensor_fit: 0,
        sensor_width_mm: 36.0,
        render_aspect: 1.5,
    };
    let (mut states, mut last) = (Vec::new(), None::<ControlState>);
    let out = drive(child, || {
        let (Some(c), Some(session_id)) = (server.latest_control(), server.stats().session_id)
        else {
            return;
        };
        let c = c.state;
        let seen = (
            c.state_seq,
            c.tap.map(|t| t.seq),
            c.rack.map(|r| (r.target, r.seq)),
        );
        if states.last() != Some(&seen) {
            states.push(seen);
        }
        last = Some(c);
        let status = HostStatus {
            applied_pose_seq: 0,
            control_ack: c.state_seq,
            error_code: 0,
            camera_name: Some("Cam".into()),
            applied_lens: Some(applied),
        };
        let _ = server.update_status(session_id, status); // the session may just have ended
    });
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "{stdout}\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    // Absolute lens state from the first message; tap then rack as new states at their frames,
    // each after a baseline sequence 0 the host has already seen.
    assert_eq!(
        states,
        [
            (1, Some(0), Some((0, 0))),
            (2, Some(1), Some((0, 0))),
            (3, Some(1), Some((2, 1)))
        ]
    );
    // The tap handed the focus to the host, so the later states leave it out (vcp.md §6.2).
    let last = last.unwrap();
    assert_eq!(
        (last.lens_mm, last.focus_distance_m, last.fstop, last.dof_on),
        (Some(85.0), None, Some(2.8), Some(true))
    );
    assert_eq!(
        last.tap,
        Some(TapFocus {
            u: 0.25,
            v: 0.75,
            seq: 1
        })
    );
    let rack = RackFocus {
        a_m: 2.0,
        b_m: 8.0,
        target: 2,
        duration_ms: 1200,
        seq: 1,
    };
    assert_eq!(last.rack, Some(rack));
    assert!(field(&stdout, "control_ack") >= 3, "{stdout}");
    let (fov, equivalent) = applied.horizontal_fov_and_equivalent().unwrap();
    let want = format!(
        " applied_lens=1 lens_mm=85 focus_m=3 fstop=2.8 dof=1 sensor_width_mm=36 sensor_fit=0 \
         aspect=1.5 hfov_deg={fov:.2} equiv_mm={equivalent:.2} camera=Cam"
    );
    assert!(stdout.contains(&want), "{stdout}\nwant {want}");
    assert_eq!(format!("{fov:.2} {equivalent:.2}"), "23.91 85.01");

    let out = drive(
        spawn(&server, &scratch.state(), None, &["--rack", "1,2,C,0"]),
        || {},
    );
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("--rack TARGET must be A or B"));
}

#[test]
fn impaired_long_run_loses_about_the_requested_share_and_controls_still_converge() {
    let server = server();
    let scratch = Scratch::new("impair");
    let code = server.enable_pairing().unwrap();
    // 3 s at 2000 Hz loops the 390-frame script into 6000 poses; Set origin at pose 3000 is a
    // second control state that must be acknowledged despite 2 % loss both ways.
    let args = [
        "--rate",
        "2000",
        "--duration",
        "3",
        "--linger",
        "1.5",
        "--loss",
        "2",
        "--jitter",
        "10",
        "--seed",
        "1",
        "--set-origin-at",
        "3000",
    ];
    let child = spawn(&server, &scratch.state(), Some(&code), &args);
    let (mut last_pose, mut states, mut host_poses) = (None, Vec::new(), (0, 0));
    let out = drive(child, || {
        last_pose = server.latest_pose().or(last_pose);
        let stats = server.stats();
        // The host's counters reset when the session ends; keep the last live values.
        if stats.poses_applied > 0 {
            host_poses = (stats.poses_applied, stats.poses_stale);
        }
        let (Some(c), Some(session_id)) = (server.latest_control(), stats.session_id) else {
            return;
        };
        if states.last() != Some(&c.state.state_seq) {
            states.push(c.state.state_seq);
        }
        let status = HostStatus {
            applied_pose_seq: 0,
            control_ack: c.state.state_seq,
            error_code: 0,
            camera_name: Some("Cam".into()),
            applied_lens: None,
        };
        let _ = server.update_status(session_id, status); // the session may just have ended
    });
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "{stdout}\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    println!("{stdout}");
    assert_eq!(field(&stdout, "poses"), 6000, "{stdout}");
    assert!(
        last_pose.unwrap().pose.seq > 5900,
        "the looped script kept going"
    );
    assert_eq!(
        (
            field(&stdout, "loss_pct"),
            field(&stdout, "jitter_ms"),
            field(&stdout, "seed")
        ),
        (2, 10, 1)
    );
    let (sent, dropped, delayed) = (
        field(&stdout, "udp_out"),
        field(&stdout, "dropped_out"),
        field(&stdout, "delayed"),
    );
    assert!(sent >= 6000, "{stdout}");
    let pct = 100.0 * dropped as f64 / sent as f64;
    assert!((1.0..=3.0).contains(&pct), "send loss {pct} %: {stdout}");
    // Almost every surviving datagram is held for 0..10 ms (0 exactly goes out at once).
    assert!(
        delayed <= sent - dropped && delayed * 100 > (sent - dropped) * 99,
        "{stdout}"
    );
    // What reached the host: about 2 % of the poses are missing, and the 0..10 ms delays at a
    // 0.5 ms pose period reorder many of the rest (older ones arrive late and are stale).
    let (applied, stale) = host_poses;
    let host_loss = 100.0 * (6000 - (applied + stale)) as f64 / 6000.0;
    println!("host: {applied} applied, {stale} stale, {host_loss:.2} % missing");
    assert!((1.0..=3.0).contains(&host_loss), "host saw {host_poses:?}");
    assert!(stale > 100, "no reordering: {host_poses:?}");
    let (received, dropped_in) = (field(&stdout, "udp_in"), field(&stdout, "dropped_in"));
    assert!(received > 0 && dropped_in < received, "{stdout}");
    // Resends every 500 ms get the newest state through and acknowledged.
    assert_eq!(states, [1, 2], "{stdout}");
    assert_eq!(field(&stdout, "control_ack"), 2, "{stdout}");

    let out = drive(
        spawn(&server, &scratch.state(), None, &["--duration", "0"]),
        || {},
    );
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("--duration must be > 0"));
}

#[test]
fn viewfinder_frames_reach_the_device_whole_over_the_paired_session() {
    const SENT: u32 = 20;
    let server = server();
    let scratch = Scratch::new("video");
    let video_out = scratch.0.join("newest.jpg");
    let code = server.enable_pairing().unwrap();
    let child = spawn(
        &server,
        &scratch.state(),
        Some(&code),
        &[
            "--rate",
            "300",
            "--linger",
            "1",
            "--video-out",
            &video_out.to_string_lossy(),
        ],
    );
    let mut video = server.video_sender();
    let (mut sent, mut last, mut report) = (Vec::new(), Vec::new(), None);
    let out = drive(child, || {
        let stats = server.stats();
        report = stats.video_report.or(report);
        // Frames of 1 to 5 fragments, sent once the device's UDP source is known.
        if sent.len() < SENT as usize && stats.source.is_some() {
            let n = sent.len() as u32 + 1;
            last = (0..n as usize * 1000 + 17)
                .map(|i| (i % 253) as u8 ^ n as u8)
                .collect();
            let meta = VideoFrameMeta {
                render_time_ns: server.host_clock_ns(),
                pose_seq: 1000 + n,
                codec: VideoFragment::CODEC_JPEG,
                color: VideoFragment::COLOR_SRGB_REC709,
                quality: 70,
            };
            sent.push(video.send(meta, &last).unwrap());
        }
    });
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "{stdout}\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(sent.len(), SENT as usize, "{stdout}");
    let ids: Vec<u32> = sent.iter().map(|s| s.frame_id).collect();
    assert_eq!(ids, (1..=SENT).collect::<Vec<_>>(), "numbered per session");
    // Loopback loses nothing: every frame completed, and the newest one is byte-exact.
    assert_eq!(field(&stdout, "video_frames"), u64::from(SENT), "{stdout}");
    assert_eq!(field(&stdout, "video_lost"), 0, "{stdout}");
    assert_eq!(
        (field(&stdout, "dropped_out"), field(&stdout, "dropped_in")),
        (0, 0),
        "no impairment unless asked"
    );
    assert_eq!(field(&stdout, "video_last_id"), u64::from(SENT), "{stdout}");
    assert_eq!(
        field(&stdout, "video_last_pose_seq"),
        u64::from(1000 + SENT)
    );
    assert_eq!(field(&stdout, "video_last_len"), last.len() as u64);
    assert_eq!(std::fs::read(&video_out).unwrap(), last);
    // The device's VIDEO_REPORTs (vcp.md §6.6) reached the host: the newest one seen covers
    // every frame and carries no motion-to-photon figure.
    let report = report.expect("no VIDEO_REPORT reached the host");
    assert_eq!(
        (
            report.newest_frame_id,
            report.frames_complete,
            report.m2p_p95_ms
        ),
        (SENT, SENT, 0),
        "{stdout}"
    );
    assert!(
        (1..=field(&stdout, "video_reports")).contains(&u64::from(report.report_seq)),
        "{stdout}"
    );
}
