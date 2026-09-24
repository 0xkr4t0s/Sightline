//! UdpReceiver over real loopback sockets (task 1.2.1; NET-002, FR-BL-004, NFR-REL-002).
#![allow(clippy::unwrap_used, clippy::expect_used)] // test code: a panic is a test failure

use std::net::{SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

use vcam_net::UdpReceiver;
use vcam_protocol::{ControlState, Endpoint, Message, Pose, Role};

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

fn pose(seq: u32) -> Message {
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
