//! UdpReceiver over real loopback sockets (task 1.2.1; NET-002, FR-BL-004, NFR-REL-002).
#![allow(clippy::unwrap_used, clippy::expect_used)] // test code: a panic is a test failure

use std::net::{SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

use vcam_net::{HostStatus, OneEuro, Smoothing, UdpReceiver, VideoFrameMeta};
use vcam_protocol::{
    Clock, ControlState, Endpoint, Message, Pose, Pushed, Reassembler, Role, Status, VideoFragment,
    VideoFrameInfo,
};

const SID: u32 = 0x1234_ABCD;
const K_D2H: [u8; 32] = [0x11; 32];
const K_H2D: [u8; 32] = [0x22; 32];

fn host() -> Endpoint {
    Endpoint::new(Role::Host, SID, &K_D2H, &K_H2D).unwrap()
}

fn device() -> Endpoint {
    Endpoint::new(Role::Device, SID, &K_D2H, &K_H2D).unwrap()
}

fn start() -> UdpReceiver {
    let rx = UdpReceiver::start("127.0.0.1:0".parse().unwrap()).unwrap();
    rx.set_session(host()).unwrap();
    rx
}

fn pose(seq: u32) -> Message<'static> {
    Message::Pose(Pose {
        seq,
        capture_time_ns: u64::from(seq) * 16_666_667,
        position_m: [0.1 * seq as f32, 0.0, 1.5],
        orientation: [0.0, 0.0, 0.0, 1.0],
        tracking_state: Pose::TRACKING_NORMAL,
        flags: 0,
    })
}

fn datagram(msg: &Message) -> Vec<u8> {
    let mut out = Vec::new();
    device().seal(msg, &mut out).unwrap();
    out
}

fn sender() -> UdpSocket {
    UdpSocket::bind("127.0.0.1:0").unwrap()
}

/// Polls `cond` until true or 2 s pass.
fn wait_until(what: &str, mut cond: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(2);
    while !cond() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn newest_seq_wins_and_reordered_poses_are_stale() {
    let rx = start();
    let tx = sender();
    for seq in [1, 3, 2] {
        tx.send_to(&datagram(&pose(seq)), rx.local_addr()).unwrap();
    }
    wait_until("3 poses processed", || {
        let s = rx.stats();
        s.poses_applied + s.poses_stale == 3
    });
    let s = rx.stats();
    assert_eq!((s.poses_applied, s.poses_stale), (2, 1));
    let latest = rx.latest_pose().unwrap();
    assert_eq!(latest.pose.seq, 3);
    assert_eq!(latest.source, tx.local_addr().unwrap());
    assert!(s.last_pose_age.unwrap() < Duration::from_secs(1));
}

#[test]
fn bad_datagrams_are_counted_by_reason_and_never_reach_the_slot() {
    let rx = start();
    let tx = sender();
    let mut wrong_key = Vec::new();
    Endpoint::new(Role::Device, SID, &[0x99; 32], &K_H2D)
        .unwrap()
        .seal(&pose(7), &mut wrong_key)
        .unwrap();
    tx.send_to(&wrong_key, rx.local_addr()).unwrap();
    tx.send_to(b"hello", rx.local_addr()).unwrap();
    tx.send_to(&[0u8; 1300], rx.local_addr()).unwrap(); // larger than MAX_DATAGRAM
    wait_until("3 drops", || rx.stats().dropped.total() == 3);
    let d = rx.stats().dropped;
    assert_eq!((d.tag, d.size), (1, 2), "{d:?}");
    assert!(rx.latest_pose().is_none());
    assert_eq!(
        rx.stats().source,
        None,
        "unauthenticated datagrams must not set the reply address"
    );
}

#[test]
fn loss_and_rate_come_from_seq_gaps_in_the_last_second() {
    let rx = start();
    let tx = sender();
    let sent: Vec<u32> = (1..=20).filter(|s| !(5..=8).contains(s)).collect();
    for &seq in &sent {
        tx.send_to(&datagram(&pose(seq)), rx.local_addr()).unwrap();
    }
    wait_until("16 poses", || rx.stats().poses_applied == 16);
    let s = rx.stats();
    assert!((s.loss - 0.2).abs() < 1e-9, "loss {}", s.loss);
    assert!((s.rate_hz - 16.0).abs() < 1e-9, "rate {}", s.rate_hz);
    std::thread::sleep(Duration::from_millis(1100));
    let later = rx.stats();
    assert_eq!(
        (later.rate_hz, later.loss),
        (0.0, 0.0),
        "the window must expire"
    );
    assert!(later.last_pose_age.unwrap() >= Duration::from_secs(1));
}

#[test]
fn control_state_newest_wins() {
    let rx = start();
    let tx = sender();
    for (seq, epoch) in [(2, 5), (1, 9)] {
        let msg = Message::ControlState(ControlState {
            state_seq: seq,
            motion_scale: Some(1.0),
            lock_flags: Some(0),
            origin_epoch: Some(epoch),
        });
        tx.send_to(&datagram(&msg), rx.local_addr()).unwrap();
    }
    tx.send_to(&datagram(&pose(1)), rx.local_addr()).unwrap(); // a marker that both were read
    wait_until("marker pose", || rx.latest_pose().is_some());
    let c = rx.latest_control().unwrap();
    assert_eq!((c.state.state_seq, c.state.origin_epoch), (2, Some(5)));
}

#[test]
fn reply_address_follows_the_latest_authenticated_source() {
    let rx = start();
    let (a, b) = (sender(), sender());
    a.send_to(&datagram(&pose(1)), rx.local_addr()).unwrap();
    wait_until("pose from A", || {
        rx.stats().source == Some(a.local_addr().unwrap())
    });
    b.send_to(&datagram(&pose(2)), rx.local_addr()).unwrap();
    wait_until("pose from B", || {
        rx.stats().source == Some(b.local_addr().unwrap())
    });
    assert_eq!(rx.latest_pose().unwrap().source, b.local_addr().unwrap());
}

/// A pose at 60 Hz capture time `seq` with x position `x`.
fn pose_at(seq: u32, x: f32) -> Message<'static> {
    Message::Pose(Pose {
        seq,
        capture_time_ns: 1_000_000_000 + u64::from(seq) * 16_666_667,
        position_m: [x, 0.0, 1.5],
        orientation: [0.0, 0.0, 0.0, 1.0],
        tracking_state: Pose::TRACKING_NORMAL,
        flags: 0,
    })
}

#[test]
fn smoothing_is_optional_keeps_raw_and_survives_session_changes() {
    let rx = start();
    let tx = sender();
    let send = |seq: u32, x: f32| {
        tx.send_to(&datagram(&pose_at(seq, x)), rx.local_addr())
            .unwrap();
        wait_until("pose", || {
            rx.latest_pose().is_some_and(|p| p.pose.seq == seq)
        });
        rx.latest_pose().unwrap()
    };
    // Off by default: what to apply is exactly what arrived.
    assert_eq!(rx.smoothing(), None);
    let p = send(1, 0.0);
    assert_eq!(p.smoothed, p.pose);
    let p = send(2, 1.0);
    assert_eq!(p.smoothed, p.pose);

    rx.set_smoothing(Some(Smoothing::default())).unwrap();
    let first = send(3, 1.0); // the filter restarts at the raw sample
    assert_eq!(first.smoothed, first.pose);
    let p = send(4, 2.0);
    assert_eq!(p.pose.position_m[0], 2.0, "raw is kept for recording");
    let x = p.smoothed.position_m[0];
    assert!(1.0 < x && x < 2.0, "smoothed toward the new sample: {x}");
    // Re-setting the parameters restarts the filter at the next pose.
    rx.set_smoothing(Some(Smoothing::default())).unwrap();
    let p = send(5, 3.0);
    assert_eq!(p.smoothed, p.pose);

    // Revocation and a new session keep the setting but not the filter state.
    rx.clear_session(SID);
    assert_eq!(rx.smoothing(), Some(Smoothing::default()));
    rx.set_session(host()).unwrap();
    assert_eq!(rx.smoothing(), Some(Smoothing::default()));
    let p = send(1, 7.0);
    assert_eq!(p.smoothed, p.pose);
    let p = send(2, 8.0);
    assert!(p.smoothed.position_m[0] < 8.0);

    let mut bad = Smoothing::default();
    bad.position = OneEuro {
        min_cutoff: -1.0,
        ..bad.position
    };
    let err = rx.set_smoothing(Some(bad)).unwrap_err();
    assert_eq!(err.kind(), std::io::ErrorKind::InvalidInput);
    assert_eq!(
        rx.smoothing(),
        Some(Smoothing::default()),
        "rejected change keeps the old one"
    );
    rx.set_smoothing(None).unwrap();
    let p = send(3, 9.0);
    assert_eq!(p.smoothed, p.pose);
}

#[test]
fn stop_is_prompt_and_releases_the_port() {
    let mut rx = start();
    let addr: SocketAddr = rx.local_addr();
    let t = Instant::now();
    rx.stop();
    let took = t.elapsed();
    assert!(
        took < Duration::from_secs(1),
        "stop took {took:?} (NFR-REL-002)"
    );
    rx.stop(); // idempotent
    // Re-enabling works without restarting: the same port binds again at once.
    let again = UdpReceiver::start(addr).expect("port released");
    again.set_session(host()).unwrap();
    assert_eq!(again.local_addr(), addr);
}

/// The next host datagram. These tests never stream video, so the message owns its data.
fn receive(tx: &UdpSocket, endpoint: &Endpoint) -> Message<'static> {
    tx.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    let mut bytes = [0; 1200];
    let n = tx.recv(&mut bytes).unwrap();
    match endpoint.open(&bytes[..n]).unwrap() {
        Message::Status(s) => Message::Status(s),
        Message::Clock(c) => Message::Clock(c),
        other => panic!("unexpected host message: {other:?}"),
    }
}

fn receive_status(tx: &UdpSocket, endpoint: &Endpoint) -> Status {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        assert!(Instant::now() < deadline, "STATUS deadline expired");
        if let Message::Status(status) = receive(tx, endpoint) {
            return status;
        }
    }
}

fn quiet(tx: &UdpSocket, duration: Duration) {
    tx.set_read_timeout(Some(duration)).unwrap();
    let err = tx
        .recv(&mut [0; 1200])
        .expect_err("unexpected outbound datagram");
    assert!(matches!(
        err.kind(),
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
    ));
}

fn drain(tx: &UdpSocket) {
    tx.set_nonblocking(true).unwrap();
    while tx.recv(&mut [0; 1200]).is_ok() {}
    tx.set_nonblocking(false).unwrap();
}

#[test]
fn outbound_heartbeat_rates_continue_without_device_traffic() {
    let rx = start();
    let tx = sender();
    tx.send_to(&datagram(&pose(9)), rx.local_addr()).unwrap();
    let mut statuses = Vec::new();
    let mut clocks = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(4);
    while clocks.len() < 3 {
        assert!(Instant::now() < deadline, "CLOCK deadline expired");
        match receive(&tx, &device()) {
            Message::Status(s) => {
                assert_eq!(s.status_seq, statuses.len() as u32 + 1);
                // Reception is not application: only the host apply path may acknowledge.
                assert_eq!((s.applied_pose_seq, s.control_ack), (0, 0));
                assert_eq!((s.flags, s.error_code, s.camera_name.as_str()), (1, 1, ""));
                statuses.push(Instant::now());
            }
            Message::Clock(Clock::Request { t1 }) => clocks.push(t1),
            m => panic!("unexpected host message: {m:?}"),
        }
    }
    assert!((4..=6).contains(&statuses.len()), "{statuses:?}");
    for times in statuses.windows(2) {
        assert!(
            (Duration::from_millis(450)..Duration::from_millis(900))
                .contains(&times[1].duration_since(times[0]))
        );
    }
    for times in clocks.windows(2) {
        assert!(
            (900_000_000..1_500_000_000).contains(&(times[1] - times[0])),
            "{clocks:?}"
        );
    }
}

#[test]
fn clock_replies_estimate_offset_and_reject_replays() {
    let rx = start();
    let tx = sender();
    tx.send_to(&datagram(&pose(1)), rx.local_addr()).unwrap();
    // The device clock has its own epoch, 3.5 s ahead: the host never sees it directly.
    let device_epoch = Instant::now();
    let device_clock = || u64::try_from(device_epoch.elapsed().as_nanos()).unwrap() + 3_500_000_000;
    let mut replies = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(4);
    while replies.len() < 2 {
        assert!(Instant::now() < deadline, "CLOCK deadline expired");
        if let Message::Clock(Clock::Request { t1 }) = receive(&tx, &device()) {
            let t2 = device_clock();
            let reply = datagram(&Message::Clock(Clock::Reply {
                t1,
                t2,
                t3: device_clock(),
            }));
            tx.send_to(&reply, rx.local_addr()).unwrap();
            replies.push(reply);
        }
    }
    wait_until("two clock samples", || {
        rx.stats().clock.is_some_and(|c| c.samples == 2)
    });
    let est = rx.stats().clock.unwrap();
    let (before, device_now, after) = (rx.host_clock_ns(), device_clock(), rx.host_clock_ns());
    let truth = i128::from(device_now) - (i128::from(before) + i128::from(after)) / 2;
    assert!(
        (est.offset_ns - truth).abs() < 5_000_000,
        "{est:?} vs {truth}"
    );
    assert!((0..50_000_000).contains(&est.delay_ns), "{est:?}");
    assert!(est.jitter_ns < 5_000_000, "{est:?}");
    // A capture stamped now on the device maps to (about) now on the host clock.
    let mapped = est.host_time_ns(device_clock());
    assert!((mapped - i128::from(rx.host_clock_ns())).abs() < 5_000_000);
    assert_eq!(rx.stats().clock_rejected, 0);

    // Authenticated but already answered, and never requested: counted, not sampled.
    tx.send_to(&replies[0], rx.local_addr()).unwrap();
    wait_until("replayed reply rejected", || rx.stats().clock_rejected == 1);
    let forged = Clock::Reply {
        t1: 7,
        t2: 1,
        t3: 2,
    };
    tx.send_to(&datagram(&Message::Clock(forged)), rx.local_addr())
        .unwrap();
    wait_until("unrequested reply rejected", || {
        rx.stats().clock_rejected == 2
    });
    assert_eq!(rx.stats().clock.unwrap().samples, 2);

    // A new session starts a new estimate (the device may have rebooted its clock).
    rx.set_session(host()).unwrap();
    assert_eq!(rx.stats().clock, None);
}

#[test]
fn applied_status_changes_are_prompt_validated_and_session_scoped() {
    let rx = start();
    let tx = sender();
    tx.send_to(&datagram(&pose(9)), rx.local_addr()).unwrap();
    assert_eq!(receive_status(&tx, &device()).status_seq, 1);
    assert!(matches!(
        receive(&tx, &device()),
        Message::Clock(Clock::Request { .. })
    ));
    let status = HostStatus {
        applied_pose_seq: 8,
        control_ack: 7,
        error_code: 0,
        camera_name: Some("é".repeat(31) + "a"), // 63 UTF-8 bytes
    };
    let published = Instant::now();
    rx.update_status(SID, status.clone()).unwrap();
    let received = receive_status(&tx, &device());
    assert!(
        published.elapsed() < Duration::from_millis(400),
        "change waited for 2 Hz timer"
    );
    assert_eq!(
        (
            received.status_seq,
            received.applied_pose_seq,
            received.control_ack,
            received.flags
        ),
        (2, 8, 7, 3)
    );
    assert_eq!(received.camera_name, status.camera_name.clone().unwrap());
    assert_eq!(received.error_code, 0);
    rx.update_status(SID, status.clone()).unwrap();
    quiet(&tx, Duration::from_millis(150)); // no change, no extra packet
    assert_eq!(
        rx.update_status(SID + 1, HostStatus::default())
            .unwrap_err()
            .kind(),
        std::io::ErrorKind::NotConnected
    );
    assert_eq!(
        rx.update_status(
            SID,
            HostStatus {
                camera_name: Some("é".repeat(32)),
                ..status
            }
        )
        .unwrap_err()
        .kind(),
        std::io::ErrorKind::InvalidInput
    );
    let next = receive_status(&tx, &device());
    assert_eq!(next.status_seq, 3);
    assert_eq!(
        (
            next.applied_pose_seq,
            next.control_ack,
            next.flags,
            next.camera_name
        ),
        (8, 7, 3, received.camera_name)
    );
}

#[test]
fn outbound_routing_requires_authentication_and_stops_on_revocation() {
    let mut rx = UdpReceiver::start("127.0.0.1:0".parse().unwrap()).unwrap();
    let (a, b) = (sender(), sender());
    a.send_to(&datagram(&pose(1)), rx.local_addr()).unwrap();
    quiet(&a, Duration::from_millis(150));
    rx.set_session(host()).unwrap();
    quiet(&a, Duration::from_millis(150)); // no address inherited from pre-session traffic
    a.send_to(&datagram(&pose(1)), rx.local_addr()).unwrap();
    assert_eq!(receive_status(&a, &device()).status_seq, 1);
    assert!(matches!(
        receive(&a, &device()),
        Message::Clock(Clock::Request { .. })
    ));
    let mut forged = datagram(&pose(2));
    *forged.last_mut().unwrap() ^= 1;
    b.send_to(&forged, rx.local_addr()).unwrap();
    wait_until("bad tag dropped", || rx.stats().dropped.tag == 1);
    assert_eq!(receive_status(&a, &device()).status_seq, 2);
    quiet(&b, Duration::from_millis(150));
    b.send_to(&datagram(&pose(2)), rx.local_addr()).unwrap();
    wait_until("roamed", || {
        rx.stats().source == Some(b.local_addr().unwrap())
    });
    assert_eq!(receive_status(&b, &device()).status_seq, 3);
    drain(&a);
    quiet(&a, Duration::from_millis(150));

    // Replacement resets routing, keys, acknowledgements and outbound sequence.
    rx.update_status(
        SID,
        HostStatus {
            applied_pose_seq: 2,
            ..HostStatus::default()
        },
    )
    .unwrap();
    let new_host = Endpoint::new(Role::Host, SID + 1, &[3; 32], &[4; 32]).unwrap();
    let new_device = Endpoint::new(Role::Device, SID + 1, &[3; 32], &[4; 32]).unwrap();
    rx.set_session(new_host).unwrap();
    drain(&b);
    b.send_to(&datagram(&pose(3)), rx.local_addr()).unwrap();
    quiet(&b, Duration::from_millis(650));
    let mut bytes = Vec::new();
    new_device.seal(&pose(1), &mut bytes).unwrap();
    b.send_to(&bytes, rx.local_addr()).unwrap();
    let status = receive_status(&b, &new_device);
    assert_eq!(
        (
            status.status_seq,
            status.applied_pose_seq,
            status.control_ack
        ),
        (1, 0, 0)
    );
    assert!(matches!(
        receive(&b, &new_device),
        Message::Clock(Clock::Request { .. })
    ));
    rx.clear_session(SID + 1);
    drain(&b);
    b.send_to(&bytes, rx.local_addr()).unwrap();
    quiet(&b, Duration::from_millis(650));
    assert_eq!(
        rx.update_status(SID + 1, HostStatus::default())
            .unwrap_err()
            .kind(),
        std::io::ErrorKind::NotConnected
    );
    rx.stop();
    quiet(&b, Duration::from_millis(150));
}

fn video_meta(pose_seq: u32) -> VideoFrameMeta {
    VideoFrameMeta {
        render_time_ns: u64::from(pose_seq) * 1_000_000,
        pose_seq,
        codec: VideoFragment::CODEC_JPEG,
        color: VideoFragment::COLOR_SRGB_REC709,
        quality: 80,
    }
}

/// Bytes that differ at every offset of a frame, so a misplaced fragment shows up.
fn frame_bytes(len: usize, salt: u8) -> Vec<u8> {
    (0..len).map(|i| (i % 251) as u8 ^ salt).collect()
}

/// Completed frames and the (frame_id, frag_index) of every fragment, in arrival order.
type Received = (Vec<(VideoFrameInfo, Vec<u8>)>, Vec<(u32, u16)>);

/// Feeds host `VIDEO_FRAGMENT`s into a device reassembler (skipping STATUS/CLOCK) until
/// `frames` frames complete.
fn receive_frames(tx: &UdpSocket, endpoint: &Endpoint, frames: usize) -> Received {
    tx.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    let (mut done, mut order) = (Vec::new(), Vec::new());
    let mut reassembler = Reassembler::new();
    let mut bytes = [0; 1200];
    while done.len() < frames {
        let n = tx.recv(&mut bytes).expect("VIDEO_FRAGMENT");
        if let Message::VideoFragment(frag) = endpoint.open(&bytes[..n]).unwrap() {
            order.push((frag.frame.frame_id, frag.frag_index));
            match reassembler.push(&frag) {
                Pushed::Complete(c) => done.push((c.frame, c.data.to_vec())),
                Pushed::Pending => {}
                other => panic!("host sent a fragment the device rejects: {other:?}"),
            }
        }
    }
    (done, order)
}

#[test]
fn video_frames_reach_the_latest_source_numbered_in_order_and_exact() {
    let rx = start();
    let mut video = rx.video_sender();
    let (a, b) = (sender(), sender());
    // No authenticated source yet: nowhere to send, and no frame number is used up.
    let err = video.send(video_meta(1), &[0xFF; 10]).unwrap_err();
    assert_eq!(err.kind(), std::io::ErrorKind::NotConnected);
    a.send_to(&datagram(&pose(1)), rx.local_addr()).unwrap();
    wait_until("source", || rx.stats().source.is_some());

    let first = frame_bytes(2 * VideoFragment::MAX_DATA + 7, 0x5A);
    let sent = video.send(video_meta(1), &first).unwrap();
    assert_eq!(
        (sent.session_id, sent.frame_id, sent.fragments),
        (SID, 1, 3)
    );
    // Invalid frames are refused before anything is sent or numbered.
    for (meta, data) in [
        (video_meta(2), &[][..]),
        (
            VideoFrameMeta {
                codec: 2, // H.264 is reserved for Stage B
                ..video_meta(2)
            },
            &[1, 2, 3][..],
        ),
    ] {
        let err = video.send(meta, data).unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::InvalidInput);
    }
    let second = frame_bytes(VideoFragment::MAX_DATA, 0xA5);
    assert_eq!(video.send(video_meta(2), &second).unwrap().frame_id, 2);

    let (frames, order) = receive_frames(&a, &device(), 2);
    assert_eq!(
        order,
        [(1, 0), (1, 1), (1, 2), (2, 0)],
        "index order, frame by frame"
    );
    let (info, data) = &frames[0];
    assert_eq!(data, &first);
    assert_eq!(
        *info,
        VideoFrameInfo {
            frame_id: 1,
            render_time_ns: 1_000_000,
            pose_seq: 1,
            codec: VideoFragment::CODEC_JPEG,
            color: VideoFragment::COLOR_SRGB_REC709,
            quality: 80,
            flags: 0,
        }
    );
    assert_eq!((frames[1].0.frame_id, frames[1].0.pose_seq), (2, 2));
    assert_eq!(frames[1].1, second);
    let stats = rx.stats();
    assert_eq!(
        (
            stats.video_frames_sent,
            stats.video_fragments_sent,
            stats.video_frames_failed
        ),
        (2, 4, 0)
    );

    // Roaming: the next frame follows the latest authenticated source.
    b.send_to(&datagram(&pose(2)), rx.local_addr()).unwrap();
    wait_until("roamed", || {
        rx.stats().source == Some(b.local_addr().unwrap())
    });
    drain(&a);
    video
        .send(video_meta(3), &[0xFF, 0xD8, 0xFF, 0xD9])
        .unwrap();
    let (frames, _) = receive_frames(&b, &device(), 1);
    assert_eq!(frames[0].0.frame_id, 3);
    tx_has_no_video(&a);
}

/// No `VIDEO_FRAGMENT` arrives on `tx` for 150 ms (STATUS/CLOCK may).
fn tx_has_no_video(tx: &UdpSocket) {
    tx.set_read_timeout(Some(Duration::from_millis(150)))
        .unwrap();
    let mut bytes = [0; 1200];
    while let Ok(n) = tx.recv(&mut bytes) {
        assert_ne!(
            bytes.get(5),
            Some(&0x05),
            "unexpected VIDEO_FRAGMENT ({n} bytes)"
        );
    }
}

#[test]
fn video_is_session_scoped_and_ends_with_the_receiver() {
    let mut rx = start();
    let mut video = rx.video_sender();
    let tx = sender();
    tx.send_to(&datagram(&pose(1)), rx.local_addr()).unwrap();
    wait_until("source", || rx.stats().source.is_some());
    video.send(video_meta(1), &[1; 10]).unwrap();
    video.send(video_meta(2), &[2; 10]).unwrap();
    receive_frames(&tx, &device(), 2);

    // A replacement session numbers from 1 again, under its own keys only.
    let new_host = Endpoint::new(Role::Host, SID + 1, &[3; 32], &[4; 32]).unwrap();
    let new_device = Endpoint::new(Role::Device, SID + 1, &[3; 32], &[4; 32]).unwrap();
    rx.set_session(new_host).unwrap();
    let err = video.send(video_meta(3), &[3; 10]).unwrap_err();
    assert_eq!(
        err.kind(),
        std::io::ErrorKind::NotConnected,
        "new session has no source"
    );
    let mut hello = Vec::new();
    new_device.seal(&pose(1), &mut hello).unwrap();
    tx.send_to(&hello, rx.local_addr()).unwrap();
    wait_until("new source", || rx.stats().source.is_some());
    drain(&tx);
    let sent = video.send(video_meta(3), &[3; 10]).unwrap();
    assert_eq!((sent.session_id, sent.frame_id), (SID + 1, 1));
    let (frames, _) = receive_frames(&tx, &new_device, 1);
    assert_eq!(
        (frames[0].0.frame_id, frames[0].1.as_slice()),
        (1, &[3; 10][..])
    );

    rx.clear_session(SID + 1);
    let err = video.send(video_meta(4), &[4; 10]).unwrap_err();
    assert_eq!(err.kind(), std::io::ErrorKind::NotConnected);
    tx_has_no_video(&tx);

    // A sender never keeps the socket alive: after stop the port binds again at once.
    let addr = rx.local_addr();
    rx.stop();
    let err = video.send(video_meta(5), &[5; 10]).unwrap_err();
    assert_eq!(err.kind(), std::io::ErrorKind::NotConnected);
    let again = UdpReceiver::start(addr).expect("port released");
    assert_eq!(again.local_addr(), addr);
    let err = video.send(video_meta(6), &[6; 10]).unwrap_err();
    assert_eq!(
        err.kind(),
        std::io::ErrorKind::NotConnected,
        "not rebound to a new receiver"
    );
}
