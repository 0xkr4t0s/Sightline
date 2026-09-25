//! The real `vcam-fake-iphone` binary against a real `ControlServer` (task 1.2.7; SRS §11).
#![allow(clippy::unwrap_used, clippy::expect_used)] // test code: a panic is a test failure

use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

use vcam_net::{ControlEvent, ControlServer, HostStatus, MemoryStore, ServerConfig};

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
