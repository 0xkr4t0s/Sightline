//! Take recording fed from the UDP receive path over real loopback sockets
//! (task 3.1b; FR-TAKE-001, FR-BL-006, NET-002, ARC-004).
#![allow(clippy::unwrap_used, clippy::expect_used)] // test code: a panic is a test failure

use std::net::UdpSocket;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use serde_json::Value;
use vcam_net::{
    AppliedKind, ControlServer, MemoryStore, RawTake, ServerConfig, TakeStatus, UdpReceiver,
};
use vcam_protocol::{Clock, ControlState, Endpoint, Message, Pose, Role};

const SID: u32 = 0x1234_ABCD;
/// Session keys drawn once per test process, so host and device share them; no fixed key in
/// the source.
static KEYS: LazyLock<([u8; 32], [u8; 32])> = LazyLock::new(|| {
    let (mut d2h, mut h2d) = ([0u8; 32], [0u8; 32]);
    getrandom::fill(&mut d2h).unwrap();
    getrandom::fill(&mut h2d).unwrap();
    (d2h, h2d)
});

fn host(session_id: u32) -> Endpoint {
    Endpoint::new(Role::Host, session_id, &KEYS.0, &KEYS.1).unwrap()
}

fn device(session_id: u32) -> Endpoint {
    Endpoint::new(Role::Device, session_id, &KEYS.0, &KEYS.1).unwrap()
}

fn start() -> UdpReceiver {
    let rx = UdpReceiver::start("127.0.0.1:0".parse().unwrap()).unwrap();
    rx.set_session(host(SID)).unwrap();
    rx
}

fn pose(seq: u32) -> Pose {
    Pose {
        seq,
        capture_time_ns: 1_000_000_000 + u64::from(seq) * 16_666_667,
        position_m: [0.01 * seq as f32, -0.5, 1.5],
        orientation: [0.0, 0.0, 0.0, 1.0],
        tracking_state: Pose::TRACKING_NORMAL,
        flags: 0,
    }
}

fn datagram(session_id: u32, msg: &Message) -> Vec<u8> {
    let mut out = Vec::new();
    device(session_id).seal(msg, &mut out).unwrap();
    out
}

/// Sends each message to `rx` in order, from `tx`.
fn send(tx: &UdpSocket, rx: &UdpReceiver, session_id: u32, msgs: &[Message]) {
    for msg in msgs {
        tx.send_to(&datagram(session_id, msg), rx.local_addr())
            .unwrap();
    }
}

fn sender() -> UdpSocket {
    UdpSocket::bind("127.0.0.1:0").unwrap()
}

/// Polls `cond` until true or 5 s pass.
fn wait_until(what: &str, mut cond: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !cond() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn recorded(rx: &UdpReceiver) -> u64 {
    rx.take_status().poses
}

#[test]
fn a_burst_between_latest_pose_reads_all_lands_in_the_take() {
    let rx = start();
    let tx = sender();
    rx.take_start(1).unwrap();
    let burst: Vec<Message> = (1..=300).map(|seq| Message::Pose(pose(seq))).collect();
    // Nothing reads `latest_pose` while it runs. Chunks keep the datagrams in flight under
    // Linux's default 208 KB receive buffer, which a descheduled rx thread could overflow.
    let mut sent = 0;
    for chunk in burst.chunks(50) {
        send(&tx, &rx, SID, chunk);
        sent += chunk.len() as u64;
        wait_until("a chunk recorded", || recorded(&rx) == sent);
    }
    // The live slot holds only the newest one; the take holds the whole burst.
    let newest = rx.latest_pose().unwrap();
    assert_eq!((newest.session_id, newest.pose.seq), (SID, 300));
    let take = rx.take_stop().unwrap();
    let seqs: Vec<u32> = take.poses.iter().map(|p| p.pose.seq).collect();
    assert_eq!(seqs, (1..=300).collect::<Vec<u32>>());
    assert!(take.poses.iter().all(|p| p.seg == 0 && !p.late));
    assert_eq!(
        take.poses[41].pose,
        pose(42),
        "recorded exactly as received"
    );
    assert!(
        take.poses.windows(2).all(|w| w[0].rx_ns <= w[1].rx_ns),
        "arrival times never go backwards"
    );
    assert!(!take.truncated);
}

#[test]
fn a_reordered_pose_is_kept_with_the_late_flag_and_a_duplicate_is_not_late() {
    let rx = start();
    let tx = sender();
    rx.take_start(1).unwrap();
    let order = [1, 3, 2, 3, 4];
    let msgs: Vec<Message> = order.iter().map(|&s| Message::Pose(pose(s))).collect();
    send(&tx, &rx, SID, &msgs);
    wait_until("5 poses recorded", || recorded(&rx) == 5);
    let s = rx.stats();
    assert_eq!((s.poses_applied, s.poses_stale), (3, 2));
    assert_eq!(rx.take_status().late, 1);
    let take = rx.take_stop().unwrap();
    let got: Vec<(u32, bool)> = take.poses.iter().map(|p| (p.pose.seq, p.late)).collect();
    assert_eq!(
        got,
        [(1, false), (3, false), (2, true), (3, false), (4, false)]
    );
}

#[test]
fn a_reset_mid_take_keeps_the_buffer_and_the_next_session_is_segment_two() {
    let rx = start();
    let tx = sender();
    rx.take_start(1).unwrap();
    let first: Vec<Message> = (1..=4).map(|s| Message::Pose(pose(s))).collect();
    send(&tx, &rx, SID, &first);
    wait_until("first session", || recorded(&rx) == 4);

    rx.clear_session(SID);
    assert!(rx.stats().session_id.is_none(), "the session ended");
    assert!(rx.take_status().recording, "the take outlives it");
    assert_eq!(recorded(&rx), 4);
    // Datagrams with no session are dropped, not recorded.
    send(&tx, &rx, SID, &[Message::Pose(pose(5))]);
    wait_until("dropped without a session", || {
        rx.stats().dropped.session == 1
    });
    assert_eq!(recorded(&rx), 4);

    // A new session restarts its numbering; so does a replacement with the same id.
    const SECOND: u32 = SID + 1;
    rx.set_session(host(SECOND)).unwrap();
    send(
        &tx,
        &rx,
        SECOND,
        &[Message::Pose(pose(1)), Message::Pose(pose(2))],
    );
    wait_until("second session", || recorded(&rx) == 6);
    rx.set_session(host(SECOND)).unwrap();
    send(&tx, &rx, SECOND, &[Message::Pose(pose(1))]);
    wait_until("replacement session", || recorded(&rx) == 7);

    let take = rx.take_stop().unwrap();
    let got: Vec<(u32, u32)> = take.poses.iter().map(|p| (p.seg, p.pose.seq)).collect();
    assert_eq!(
        got,
        [(0, 1), (0, 2), (0, 3), (0, 4), (1, 1), (1, 2), (2, 1)]
    );
    let sessions: Vec<u32> = take.segments.iter().map(|s| s.session_id).collect();
    assert_eq!(sessions, [SID, SECOND, SECOND]);
    assert_eq!(take.segments[0].start_host_ns, take.start_host_ns);
    assert!(take.segments[1].start_host_ns >= take.poses[3].rx_ns);
    assert!(take.segments[2].start_host_ns >= take.poses[5].rx_ns);
}

fn state(state_seq: u32, motion_scale: f32) -> Message<'static> {
    Message::ControlState(ControlState {
        state_seq,
        motion_scale: Some(motion_scale),
        lock_flags: Some(1),
        origin_epoch: Some(0),
        ..Default::default()
    })
}

#[test]
fn control_notes_carry_the_newest_accepted_pose_and_skip_stale_states() {
    let rx = start();
    let tx = sender();
    rx.take_start(1).unwrap();
    send(
        &tx,
        &rx,
        SID,
        &[
            state(1, 1.0), // before any pose
            Message::Pose(pose(1)),
            Message::Pose(pose(5)),
            Message::Pose(pose(3)), // late: not the newest
            state(2, 2.0),
            state(1, 9.0), // stale: neither applied nor recorded
            Message::Pose(pose(6)),
            state(3, 3.0),
        ],
    );
    wait_until("3 control notes", || {
        rx.stats().poses_applied == 3 && {
            rx.latest_control().is_some_and(|c| c.state.state_seq == 3)
        }
    });
    let take = rx.take_stop().unwrap();
    let notes: Vec<(u32, u32, u64, Option<f32>)> = take
        .controls
        .iter()
        .map(|c| {
            (
                c.state.state_seq,
                c.last_pose_seq,
                c.last_pose_capture_ns,
                c.state.motion_scale,
            )
        })
        .collect();
    assert_eq!(
        notes,
        [
            (1, 0, 0, Some(1.0)),
            (2, 5, pose(5).capture_time_ns, Some(2.0)),
            (3, 6, pose(6).capture_time_ns, Some(3.0)),
        ]
    );
    assert!(take.controls.iter().all(|c| c.seg == 0));
    assert!(take.controls[1].rx_ns >= take.poses[2].rx_ns);
}

#[test]
fn clock_notes_follow_accepted_replies_only() {
    let rx = start();
    let tx = sender();
    rx.take_start(1).unwrap();
    send(&tx, &rx, SID, &[Message::Pose(pose(1))]); // sets the reply address
    let device_epoch = Instant::now();
    let device_clock = || u64::try_from(device_epoch.elapsed().as_nanos()).unwrap() + 3_500_000_000;
    tx.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    let mut replies = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while replies.len() < 2 {
        assert!(Instant::now() < deadline, "CLOCK deadline expired");
        let mut bytes = [0; 1200];
        let n = tx.recv(&mut bytes).unwrap();
        if let Message::Clock(Clock::Request { t1 }) = device(SID).open(&bytes[..n]).unwrap() {
            let reply = Message::Clock(Clock::Reply {
                t1,
                t2: device_clock(),
                t3: device_clock(),
            });
            send(&tx, &rx, SID, std::slice::from_ref(&reply));
            replies.push(reply);
            let want = replies.len();
            wait_until("reply sampled", || {
                rx.stats().clock.is_some_and(|c| c.samples == want)
            });
        }
    }
    // A replay and an unrequested reply are rejected: no note.
    send(&tx, &rx, SID, &replies[..1]);
    wait_until("replay rejected", || rx.stats().clock_rejected == 1);
    let estimate = rx.stats().clock.unwrap();
    let take = rx.take_stop().unwrap();
    assert_eq!(take.clocks.len(), 2);
    assert!(take.clocks.iter().all(|c| c.seg == 0));
    let last = take.clocks[1];
    assert_eq!(i128::from(last.offset_ns), estimate.offset_ns);
    assert_eq!(i128::from(last.delay_ns), estimate.delay_ns);
    assert_eq!(last.jitter_ns, estimate.jitter_ns);
    assert!(take.clocks[0].rx_ns <= last.rx_ns);
}

#[test]
fn take_lifecycle_notes_and_status_through_the_receiver() {
    let rx = start();
    let tx = sender();
    assert_eq!(rx.take_status(), TakeStatus::default());
    // Notes outside a take are ignored.
    rx.take_note_frame(1.0);
    rx.take_note_applied(None, AppliedKind::Locks { lock_flags: 1 });

    let started = rx.take_start(9).unwrap();
    assert_eq!(
        rx.take_start(10).unwrap_err().kind(),
        std::io::ErrorKind::AlreadyExists
    );
    send(&tx, &rx, SID, &[Message::Pose(pose(1))]);
    wait_until("one pose", || recorded(&rx) == 1);
    rx.take_note_frame(12.0);
    rx.take_note_applied(
        Some((SID, 1)),
        AppliedKind::Zero {
            position_m: [1.0, 2.0, 3.0],
            yaw_rad: 0.5,
        },
    );
    let status = rx.take_status();
    assert_eq!(
        (
            status.recording,
            status.take_id,
            status.poses,
            status.segments
        ),
        (true, 9, 1, 1)
    );
    assert!(status.elapsed_ns > 0 && !status.truncated);

    let take = rx.take_stop().unwrap();
    assert_eq!((take.take_id, take.start_host_ns), (9, started));
    assert!(take.stop_host_ns > started);
    assert_eq!(take.frames.len(), 1);
    assert_eq!(take.frames[0].frame, 12.0);
    assert!(take.frames[0].host_ns >= started);
    assert_eq!(take.applied.len(), 1);
    assert_eq!(
        (take.applied[0].seg, take.applied[0].pose_seq),
        (0, Some(1))
    );
    assert!(rx.take_stop().is_none());
    assert!(!rx.take_status().recording);
}

#[test]
fn a_take_survives_stopping_the_receiver() {
    let mut rx = start();
    let tx = sender();
    rx.take_start(1).unwrap();
    send(
        &tx,
        &rx,
        SID,
        &[Message::Pose(pose(1)), Message::Pose(pose(2))],
    );
    wait_until("two poses", || recorded(&rx) == 2);
    rx.stop();
    let take = rx.take_stop().expect("the take outlives the session");
    assert_eq!(take.poses.len(), 2);
}

#[test]
fn the_control_server_forwards_take_calls() {
    let server = ControlServer::start(
        "127.0.0.1:0".parse().unwrap(),
        ServerConfig::new([0xF0; 16], 0),
        Box::new(MemoryStore::default()),
    )
    .unwrap();
    assert!(!server.take_status().recording);
    let started = server.take_start(3).unwrap();
    assert_eq!(
        server.take_start(4).unwrap_err().kind(),
        std::io::ErrorKind::AlreadyExists
    );
    server.take_note_frame(2.0);
    server.take_note_applied(None, AppliedKind::Scale { motion_scale: 2.0 });
    assert_eq!(
        (server.take_status().recording, server.take_status().take_id),
        (true, 3)
    );
    let take = server.take_stop().unwrap();
    assert_eq!((take.take_id, take.start_host_ns), (3, started));
    assert_eq!((take.frames.len(), take.applied.len()), (1, 1));
    assert!(server.take_stop().is_none());
}

fn f32_of(value: &Value) -> f32 {
    value.as_f64().expect("a number") as f32
}

fn f32s<const N: usize>(value: &Value) -> [f32; N] {
    let items = value.as_array().expect("an array");
    std::array::from_fn(|i| f32_of(&items[i]))
}

fn control_of(line: &Value) -> ControlState {
    let opt = |key: &str| line.get(key).map(f32_of);
    ControlState {
        state_seq: u32::try_from(line["state_seq"].as_u64().unwrap()).unwrap(),
        motion_scale: opt("motion_scale"),
        lock_flags: line["lock_flags"]
            .as_u64()
            .map(|v| u8::try_from(v).unwrap()),
        origin_epoch: line["origin_epoch"]
            .as_u64()
            .map(|v| u16::try_from(v).unwrap()),
        lens_mm: opt("lens_mm"),
        focus_distance_m: opt("focus_distance_m"),
        fstop: opt("fstop"),
        dof_on: line["dof_on"].as_u64().map(|v| v != 0),
        ..Default::default()
    }
}

fn pose_of(line: &Value) -> Pose {
    Pose {
        seq: u32::try_from(line["seq"].as_u64().unwrap()).unwrap(),
        capture_time_ns: line["cap"].as_u64().unwrap(),
        position_m: f32s(&line["p"]),
        orientation: f32s(&line["q"]),
        tracking_state: u8::try_from(line["trk"].as_u64().unwrap()).unwrap(),
        flags: u8::try_from(line["fl"].as_u64().unwrap()).unwrap(),
    }
}

fn applied_of(line: &Value) -> AppliedKind {
    let opt = |key: &str| line.get(key).map(f32_of);
    match line["kind"].as_str().unwrap() {
        "zero" => AppliedKind::Zero {
            position_m: f32s(&line["p"]),
            yaw_rad: f32_of(&line["yaw"]),
        },
        "scale" => AppliedKind::Scale {
            motion_scale: f32_of(&line["motion_scale"]),
        },
        "locks" => AppliedKind::Locks {
            lock_flags: u8::try_from(line["lock_flags"].as_u64().unwrap()).unwrap(),
        },
        "lens" => AppliedKind::Lens {
            lens_mm: f32_of(&line["lens_mm"]),
            focus_distance_m: opt("focus_distance_m"),
            fstop: opt("fstop"),
            dof_on: line["dof_on"].as_u64().map(|v| v != 0),
        },
        other => panic!("unknown applied kind {other}"),
    }
}

/// Replays the sidecar vector's arrival order over a socket and checks that the recorder keeps
/// what the vector's `pose` and `ctl` lines hold: the same values, `late` flags, duplicates and
/// `last_*` fields (docs/takes-jsonl.md).
#[test]
fn the_sidecar_vector_replays_into_the_recorder_it_describes() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../testdata/take/sidecar_v1.jsonl");
    let lines: Vec<Value> = std::fs::read_to_string(path)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let kind = |l: &Value| l["t"].as_str().unwrap().to_owned();
    let session_id = u32::try_from(
        lines.iter().find(|l| kind(l) == "seg").unwrap()["session_id"]
            .as_u64()
            .unwrap(),
    )
    .unwrap();

    let rx = UdpReceiver::start("127.0.0.1:0".parse().unwrap()).unwrap();
    rx.set_session(host(session_id)).unwrap();
    let tx = sender();
    rx.take_start(1).unwrap();
    let (mut poses, mut ctls, mut applied, mut frames) = (0, 0, Vec::new(), Vec::new());
    for line in &lines {
        match kind(line).as_str() {
            "pose" => {
                send(&tx, &rx, session_id, &[Message::Pose(pose_of(line))]);
                poses += 1;
            }
            "ctl" => {
                let msg = Message::ControlState(control_of(line));
                send(&tx, &rx, session_id, &[msg]);
                ctls += 1;
            }
            "applied" => {
                // A pose-coupled note needs its pose's segment: let the poses sent so far land.
                wait_until("poses before the note", || recorded(&rx) == poses);
                let pose_seq = line
                    .get("pose_seq")
                    .map(|v| u32::try_from(v.as_u64().unwrap()).unwrap());
                rx.take_note_applied(pose_seq.map(|seq| (session_id, seq)), applied_of(line));
                applied.push((pose_seq, applied_of(line)));
            }
            "frame" => {
                rx.take_note_frame(line["f"].as_f64().unwrap());
                frames.push(line["f"].as_f64().unwrap());
            }
            _ => {}
        }
    }
    wait_until("the whole vector recorded", || {
        recorded(&rx) == poses && rx.latest_control().is_some_and(|c| c.state.state_seq == 1)
    });
    let take: RawTake = rx.take_stop().unwrap();
    assert_eq!(take.segments.len(), 1);
    assert_eq!(take.segments[0].session_id, session_id);

    let want: Vec<&Value> = lines.iter().filter(|l| kind(l) == "pose").collect();
    assert_eq!(take.poses.len(), want.len());
    for (got, line) in take.poses.iter().zip(&want) {
        assert_eq!(got.pose, pose_of(line));
        assert_eq!(got.seg, 0);
        assert_eq!(
            got.late,
            line["late"].as_u64() == Some(1),
            "seq {}",
            got.pose.seq
        );
    }
    assert_eq!(take.poses.iter().filter(|p| p.late).count(), 1);

    let want: Vec<&Value> = lines.iter().filter(|l| kind(l) == "ctl").collect();
    assert_eq!(take.controls.len(), ctls);
    for (got, line) in take.controls.iter().zip(&want) {
        assert_eq!(got.state, control_of(line));
        assert_eq!(
            u64::from(got.last_pose_seq),
            line["last_seq"].as_u64().unwrap()
        );
        assert_eq!(got.last_pose_capture_ns, line["last_cap"].as_u64().unwrap());
    }
    let got: Vec<_> = take.applied.iter().map(|a| (a.pose_seq, a.kind)).collect();
    assert_eq!(got, applied);
    let got: Vec<f64> = take.frames.iter().map(|f| f.frame).collect();
    assert_eq!(got, frames);
}
