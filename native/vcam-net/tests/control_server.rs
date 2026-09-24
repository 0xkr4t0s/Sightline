//! ControlServer over real TCP with a device-side client built from vcam-protocol
//! (task 1.2.2a; vcp.md §9–§11, FR-UX-002, NFR-SEC-001, NET-004, NFR-REL-002).
#![allow(clippy::unwrap_used, clippy::expect_used)] // test code: a panic is a test failure

use std::io::{Read, Write};
use std::net::{TcpStream, UdpSocket};
use std::time::{Duration, Instant};

use vcam_net::{
    ControlEvent, ControlServer, FileStore, MemoryStore, PairedDevice, PairingStore, ServerConfig,
};
use vcam_protocol::{
    ControlErrorMsg, ControlMessage, Endpoint, HEADER_LEN, Hello, Message, Pose, Role,
    SessionHandshake, SessionKeys, device_pair,
};

const DEVICE: [u8; 16] = [7; 16];
const UDP_PORT: u16 = 0; // Each server binds an isolated ephemeral UDP port.

fn server_with(config: ServerConfig) -> ControlServer {
    ControlServer::start(
        "127.0.0.1:0".parse().unwrap(),
        config,
        Box::new(MemoryStore::default()),
    )
    .unwrap()
}

fn server() -> ControlServer {
    server_with(ServerConfig::new([0xF0; 16], UDP_PORT))
}

struct Client(TcpStream, u16);

impl Client {
    fn connect(server: &ControlServer) -> Self {
        let s = TcpStream::connect(server.local_addr()).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        Self(s, server.udp_addr().port())
    }

    fn send(&mut self, msg: &ControlMessage) {
        self.0.write_all(&msg.encode().unwrap()).unwrap();
    }

    fn send_raw(&mut self, bytes: &[u8]) {
        self.0.write_all(bytes).unwrap();
    }

    fn recv(&mut self) -> ControlMessage {
        let mut header = [0u8; HEADER_LEN];
        self.0.read_exact(&mut header).unwrap();
        let mut frame = vec![0u8; ControlMessage::frame_len(&header).unwrap()];
        frame[..HEADER_LEN].copy_from_slice(&header);
        self.0.read_exact(&mut frame[HEADER_LEN..]).unwrap();
        ControlMessage::decode(&frame).unwrap()
    }

    fn expect_error(&mut self, code: u16) {
        match self.recv() {
            ControlMessage::Error(e) => assert_eq!(e.code, code, "{e:?}"),
            other => panic!("expected ERROR {code}, got {other:?}"),
        }
        let mut rest = [0u8; 1];
        assert_eq!(
            self.0.read(&mut rest).unwrap(),
            0,
            "server must close after ERROR"
        );
    }

    /// HELLO(pair) → PAIR_CHALLENGE → PAIR_PROOF; returns the server's answer.
    fn try_pair(&mut self, code: &str) -> (ControlMessage, Option<vcam_protocol::PendingPair>) {
        let hello = hello(Hello::MODE_PAIR, [0xA1; 16]);
        self.send(&ControlMessage::Hello(hello.clone()));
        let ControlMessage::PairChallenge(challenge) = self.recv() else {
            panic!("expected PAIR_CHALLENGE")
        };
        let (proof, pending) = device_pair(code, &hello, &challenge, &[0x5E; 32]).unwrap();
        self.send(&ControlMessage::PairProof(proof));
        (self.recv(), Some(pending))
    }

    fn pair(&mut self, code: &str) -> [u8; 32] {
        let (answer, pending) = self.try_pair(code);
        let ControlMessage::PairAccept { m2 } = answer else {
            panic!("expected PAIR_ACCEPT, got {answer:?}")
        };
        pending.unwrap().finish(&m2).unwrap()
    }

    /// HELLO(session) → … → SESSION_ACCEPT; returns the client's session keys.
    fn session(&mut self, pk: &[u8; 32]) -> SessionKeys {
        let hello = hello(Hello::MODE_SESSION, [0xB2; 16]);
        self.send(&ControlMessage::Hello(hello.clone()));
        let ControlMessage::SessionChallenge(challenge) = self.recv() else {
            panic!("expected SESSION_CHALLENGE")
        };
        assert_eq!(challenge.udp_port, self.1);
        let hs = SessionHandshake::new(pk, &hello, &challenge).unwrap();
        let proof_d = hs.device_proof().unwrap();
        self.send(&ControlMessage::SessionProof { proof: proof_d });
        let ControlMessage::SessionAccept { proof: proof_h } = self.recv() else {
            panic!("expected SESSION_ACCEPT")
        };
        assert!(
            hs.verify_host_proof(&proof_d, &proof_h),
            "host proof must verify"
        );
        hs.keys().unwrap()
    }
}

fn hello(mode: u8, nonce_d: [u8; 16]) -> Hello {
    Hello {
        mode,
        proto_min: 1,
        proto_max: 1,
        device_id: DEVICE,
        nonce_d,
        device_name: "iPhone".into(),
    }
}

fn next_event(server: &ControlServer) -> ControlEvent {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(e) = server.try_event() {
            return e;
        }
        assert!(Instant::now() < deadline, "no event");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn wrong(code: &str) -> String {
    format!("{:06}", (code.parse::<u32>().unwrap() + 1) % 1_000_000)
}

fn wait_until(what: &str, mut cond: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(2);
    while !cond() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn pose(seq: u32) -> Message {
    Message::Pose(Pose {
        seq,
        capture_time_ns: 1,
        position_m: [0.0; 3],
        orientation: [0.0, 0.0, 0.0, 1.0],
        tracking_state: Pose::TRACKING_NORMAL,
        flags: 0,
    })
}

fn datagram(keys: &SessionKeys, message: &Message) -> Vec<u8> {
    let mut bytes = Vec::new();
    Endpoint::new(Role::Device, keys.session_id, &keys.k_d2h, &keys.k_h2d)
        .unwrap()
        .seal(message, &mut bytes)
        .unwrap();
    bytes
}

fn send_pose(tx: &UdpSocket, server: &ControlServer, keys: &SessionKeys, seq: u32) {
    tx.send_to(&datagram(keys, &pose(seq)), server.udp_addr())
        .unwrap();
}

#[test]
fn unverified_session_cannot_activate_udp_or_replace_an_active_session() {
    let server = server();
    let mut paired = Client::connect(&server);
    let pk = paired.pair(&server.enable_pairing().unwrap());
    let mut intruder = Client::connect(&server);
    let h = hello(Hello::MODE_SESSION, [1; 16]);
    intruder.send(&ControlMessage::Hello(h.clone()));
    let ControlMessage::SessionChallenge(challenge) = intruder.recv() else {
        panic!()
    };
    let pending = SessionHandshake::new(&pk, &h, &challenge)
        .unwrap()
        .keys()
        .unwrap();
    let tx = UdpSocket::bind("127.0.0.1:0").unwrap();
    // Even correctly keyed UDP cannot arrive before SESSION_PROOF is verified.
    send_pose(&tx, &server, &pending, 50);
    wait_until("pending UDP rejected", || {
        server.stats().dropped.session > 0
    });
    assert_eq!(server.latest_pose(), None);
    assert_eq!(server.stats().session_id, None);
    let active = paired.session(&pk);
    send_pose(&tx, &server, &active, 1);
    wait_until("active pose", || server.latest_pose().is_some());
    intruder.send(&ControlMessage::SessionProof { proof: [0; 32] });
    intruder.expect_error(ControlErrorMsg::PROOF_FAILED);
    assert_eq!(server.stats().session_id, Some(active.session_id));
    send_pose(&tx, &server, &active, 2);
    wait_until("active survives invalid proof", || {
        server.latest_pose().is_some_and(|p| p.pose.seq == 2)
    });
}

#[test]
fn authenticated_control_refreshes_idle_timeout_but_forged_udp_does_not() {
    let server = server();
    let mut client = Client::connect(&server);
    let pk = client.pair(&server.enable_pairing().unwrap());
    let keys = client.session(&pk);
    next_event(&server); // Paired
    next_event(&server); // SessionStarted
    let tx = UdpSocket::bind("127.0.0.1:0").unwrap();
    send_pose(&tx, &server, &keys, 100);
    wait_until("first pose", || server.latest_pose().is_some());
    let started = Instant::now();
    let mut refreshed = None;
    let mut forged = datagram(&keys, &pose(101));
    *forged.last_mut().unwrap() ^= 1;
    client
        .0
        .set_read_timeout(Some(Duration::from_millis(100)))
        .unwrap();
    loop {
        assert!(
            started.elapsed() < Duration::from_secs(15),
            "idle session did not close"
        );
        if refreshed.is_none() && started.elapsed() >= Duration::from_secs(2) {
            let control = Message::ControlState(vcam_protocol::ControlState {
                state_seq: 1,
                motion_scale: Some(2.0),
                lock_flags: Some(0),
                origin_epoch: Some(1),
            });
            tx.send_to(&datagram(&keys, &control), server.udp_addr())
                .unwrap();
            wait_until("control refresh", || server.latest_control().is_some());
            refreshed = Some(Instant::now());
        }
        tx.send_to(&forged, server.udp_addr()).unwrap();
        match client.0.read(&mut [0]) {
            Ok(0) => break,
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            other => panic!("unexpected TCP read: {other:?}"),
        }
    }
    assert!(
        refreshed.unwrap().elapsed() >= Duration::from_millis(9700),
        "valid CONTROL_STATE must extend liveness"
    );
    assert!(
        matches!(next_event(&server), ControlEvent::SessionEnded { session_id, .. } if session_id == keys.session_id)
    );
    assert_eq!(server.stats().session_id, None);
    assert_eq!(server.latest_pose(), None);
    assert_eq!(server.latest_control(), None);
    assert_eq!(server.stats().source, None);
    let mut reconnected = Client::connect(&server);
    let fresh = reconnected.session(&pk);
    send_pose(&tx, &server, &fresh, 1);
    wait_until("reconnect after timeout", || server.latest_pose().is_some());
    assert_eq!(server.latest_pose().unwrap().pose.seq, 1);
}

#[test]
fn paired_session_drives_real_udp_and_disconnect_revokes_it() {
    let server = server();
    let code = server.enable_pairing().unwrap();
    assert_eq!(code.len(), 6);
    assert!(code.bytes().all(|b| b.is_ascii_digit()));

    let mut client = Client::connect(&server);
    let pk = client.pair(&code);
    assert_eq!(
        next_event(&server),
        ControlEvent::Paired {
            device_id: DEVICE,
            device_name: "iPhone".into()
        }
    );
    assert_eq!(server.pairing_code(), None, "a code is single-use");

    let keys = client.session(&pk);
    let ControlEvent::SessionStarted {
        device_id,
        session_id,
        peer,
        ..
    } = next_event(&server)
    else {
        panic!("expected SessionStarted")
    };
    assert_eq!((device_id, session_id), (DEVICE, keys.session_id));
    assert_eq!(peer, client.0.local_addr().unwrap());

    // The keys drive the UDP channel.
    let device = Endpoint::new(Role::Device, keys.session_id, &keys.k_d2h, &keys.k_h2d).unwrap();
    let tx = UdpSocket::bind("127.0.0.1:0").unwrap();
    let pose = Message::Pose(Pose {
        seq: 1,
        capture_time_ns: 1,
        position_m: [0.0; 3],
        orientation: [0.0, 0.0, 0.0, 1.0],
        tracking_state: 5,
        flags: 0,
    });
    let mut datagram = Vec::new();
    device.seal(&pose, &mut datagram).unwrap();
    tx.send_to(&datagram, server.udp_addr()).unwrap();
    wait_until("UDP pose", || server.latest_pose().is_some());
    assert_eq!(
        server.latest_pose().unwrap().pose,
        match pose {
            Message::Pose(p) => p,
            _ => unreachable!(),
        }
    );

    drop(client);
    assert_eq!(
        next_event(&server),
        ControlEvent::SessionEnded {
            device_id: DEVICE,
            session_id: keys.session_id
        }
    );
    assert_eq!(server.latest_pose(), None);
    assert_eq!(server.latest_control(), None);
    assert_eq!(server.stats().source, None);
    tx.send_to(&datagram, server.udp_addr()).unwrap();
    wait_until("revoked datagram dropped", || {
        server.stats().dropped.session > 0
    });
    assert_eq!(server.latest_pose(), None);
}

#[test]
fn reconnect_replaces_keys_closes_old_tcp_and_resets_samples() {
    let server = server();
    let code = server.enable_pairing().unwrap();
    let mut first = Client::connect(&server);
    let pk = first.pair(&code);
    let k1 = first.session(&pk);
    let tx = UdpSocket::bind("127.0.0.1:0").unwrap();
    send_pose(&tx, &server, &k1, 100);
    wait_until("old pose", || server.latest_pose().is_some());
    let mut second = Client::connect(&server);
    let k2 = second.session(&pk);
    assert_ne!(k1.session_id, k2.session_id);
    assert_ne!(k1.k_d2h, k2.k_d2h, "fresh nonces must give fresh keys");
    let mut byte = [0];
    assert_eq!(
        first.0.read(&mut byte).unwrap(),
        0,
        "replaced TCP must close"
    );
    assert_eq!(server.latest_pose(), None);
    assert_eq!(server.stats().source, None);
    send_pose(&tx, &server, &k1, 101);
    wait_until("old keys rejected", || server.stats().dropped.total() > 0);
    assert_eq!(server.latest_pose(), None);
    send_pose(&tx, &server, &k2, 1);
    wait_until("new seq starts at one", || server.latest_pose().is_some());
    assert_eq!(server.latest_pose().unwrap().pose.seq, 1);
    assert_eq!(server.stats().session_id, Some(k2.session_id));
}

#[test]
fn three_wrong_codes_lock_pairing() {
    let server = server();
    let code = server.enable_pairing().unwrap();
    for attempt in 1..=3 {
        let mut c = Client::connect(&server);
        let (answer, _) = c.try_pair(&wrong(&code));
        assert!(
            matches!(&answer, ControlMessage::Error(e) if e.code == ControlErrorMsg::PROOF_FAILED),
            "attempt {attempt}: {answer:?}"
        );
    }
    assert_eq!(
        server.pairing_code(),
        None,
        "3 failures must invalidate the code"
    );
    let mut c = Client::connect(&server);
    c.send(&ControlMessage::Hello(hello(Hello::MODE_PAIR, [0; 16])));
    c.expect_error(ControlErrorMsg::PAIRING_DISABLED);
    assert!(
        server.try_event().is_none(),
        "no Paired event for failed attempts"
    );
}

#[test]
fn expired_code_is_refused() {
    let mut config = ServerConfig::new([0xF0; 16], UDP_PORT);
    config.code_lifetime = Duration::from_millis(50);
    let server = server_with(config);
    server.enable_pairing().unwrap();
    std::thread::sleep(Duration::from_millis(80));
    assert_eq!(server.pairing_code(), None);
    let mut c = Client::connect(&server);
    c.send(&ControlMessage::Hello(hello(Hello::MODE_PAIR, [0; 16])));
    c.expect_error(ControlErrorMsg::PAIRING_DISABLED);
}

#[test]
fn unpaired_device_and_bad_session_proof_are_refused() {
    let server = server();
    let mut c = Client::connect(&server);
    c.send(&ControlMessage::Hello(hello(Hello::MODE_SESSION, [0; 16])));
    c.expect_error(ControlErrorMsg::NOT_PAIRED);

    let code = server.enable_pairing().unwrap();
    let mut c = Client::connect(&server);
    c.pair(&code);
    c.send(&ControlMessage::Hello(hello(Hello::MODE_SESSION, [3; 16])));
    let ControlMessage::SessionChallenge(_) = c.recv() else {
        panic!()
    };
    c.send(&ControlMessage::SessionProof { proof: [0; 32] });
    c.expect_error(ControlErrorMsg::PROOF_FAILED);
}

#[test]
fn malformed_and_wrong_version_hello_are_refused() {
    let server = server();
    let mut c = Client::connect(&server);
    c.send_raw(b"VCP1\x01\x40\x00\x00\x00\x00\x02\x00xx"); // HELLO with a 2-byte payload
    c.expect_error(ControlErrorMsg::MALFORMED);

    let mut c = Client::connect(&server);
    let mut h = hello(Hello::MODE_SESSION, [0; 16]);
    (h.proto_min, h.proto_max) = (2, 3);
    c.send(&ControlMessage::Hello(h));
    c.expect_error(ControlErrorMsg::UNSUPPORTED_VERSION);

    let mut c = Client::connect(&server);
    let mut frame = ControlMessage::Hello(hello(Hello::MODE_SESSION, [0; 16]))
        .encode()
        .unwrap();
    frame[4] = 2; // header version 2
    c.send_raw(&frame);
    c.expect_error(ControlErrorMsg::UNSUPPORTED_VERSION);
}

#[test]
fn a_second_concurrent_pairing_is_busy() {
    let server = server();
    server.enable_pairing().unwrap();
    let mut first = Client::connect(&server);
    first.send(&ControlMessage::Hello(hello(Hello::MODE_PAIR, [1; 16])));
    let ControlMessage::PairChallenge(_) = first.recv() else {
        panic!()
    }; // first is mid-pairing
    let mut second = Client::connect(&server);
    second.send(&ControlMessage::Hello(hello(Hello::MODE_PAIR, [2; 16])));
    second.expect_error(ControlErrorMsg::BUSY);
}

#[test]
fn stop_closes_active_and_idle_connections_and_releases_both_ports() {
    let mut server = server();
    let mut active = Client::connect(&server);
    let pk = active.pair(&server.enable_pairing().unwrap());
    let keys = active.session(&pk);
    let tx = UdpSocket::bind("127.0.0.1:0").unwrap();
    send_pose(&tx, &server, &keys, 1);
    wait_until("active before stop", || server.latest_pose().is_some());
    let mut idle = Client::connect(&server); // never sends anything
    let _other = Client::connect(&server);
    std::thread::sleep(Duration::from_millis(100));
    let t = Instant::now();
    server.stop();
    assert!(
        t.elapsed() < Duration::from_secs(1),
        "stop took {:?} (NFR-REL-002)",
        t.elapsed()
    );
    let mut buf = [0u8; 1];
    assert_eq!(
        idle.0.read(&mut buf).unwrap(),
        0,
        "connection must be closed"
    );
    assert!(
        TcpStream::connect(server.local_addr()).is_err(),
        "listener must be closed"
    );
    assert_eq!(active.0.read(&mut buf).unwrap(), 0);
    assert_eq!(server.latest_pose(), None);
    assert_eq!(server.stats().session_id, None);
    let mut restarted = ControlServer::start(
        server.local_addr(),
        ServerConfig::new([0xF0; 16], server.udp_addr().port()),
        Box::new(MemoryStore::default()),
    )
    .expect("TCP and UDP ports must be released even while the stopped handle lives");
    let mut client = Client::connect(&restarted);
    let pk = client.pair(&restarted.enable_pairing().unwrap());
    let keys = client.session(&pk);
    send_pose(&tx, &restarted, &keys, 1);
    wait_until("pose after re-enable", || restarted.latest_pose().is_some());
    restarted.stop();
}

#[test]
fn codes_are_six_digits_and_vary() {
    let server = server();
    let codes: std::collections::HashSet<String> =
        (0..50).map(|_| server.enable_pairing().unwrap()).collect();
    assert!(
        codes
            .iter()
            .all(|c| c.len() == 6 && c.bytes().all(|b| b.is_ascii_digit()))
    );
    assert!(
        codes.len() > 45,
        "50 random codes should almost never collide ({} distinct)",
        codes.len()
    );
}

// A unique config root, removed after all FileStore/server handles in the test are dropped.
struct ConfigDir(std::path::PathBuf);

impl ConfigDir {
    fn new() -> Self {
        let mut nonce = [0u8; 16];
        getrandom::fill(&mut nonce).unwrap();
        let path = std::env::temp_dir().join(format!(
            "vcam-pairings-test-{:032x}",
            u128::from_le_bytes(nonce)
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }

    fn snapshot(&self) -> std::path::PathBuf {
        self.0.join("vcam-pairings/pairings.v1")
    }

    fn server(&self) -> ControlServer {
        ControlServer::start(
            "127.0.0.1:0".parse().unwrap(),
            ServerConfig::new([0xF0; 16], UDP_PORT),
            Box::new(FileStore::open(&self.0).unwrap()),
        )
        .unwrap()
    }
}

impl Drop for ConfigDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn paired(id: u8, name: &str, key: u8) -> PairedDevice {
    PairedDevice {
        device_id: [id; 16],
        device_name: name.into(),
        pk: [key; 32],
    }
}

#[test]
fn file_pairing_survives_server_restart_without_a_new_code() {
    let config = ConfigDir::new();
    let mut first = config.server();
    let mut client = Client::connect(&first);
    let pk = client.pair(&first.enable_pairing().unwrap());
    // Receipt of PAIR_ACCEPT guarantees the key is already on disk, not merely queued.
    assert_eq!(
        FileStore::open(&config.0).unwrap().get(&DEVICE).unwrap().pk,
        pk
    );
    let old_keys = client.session(&pk);
    drop(client);
    first.stop();
    drop(first);

    let second = config.server();
    assert_eq!(second.pairing_code(), None);
    let new_keys = Client::connect(&second).session(&pk);
    assert_ne!(old_keys.k_d2h, new_keys.k_d2h);
    assert!(
        matches!(next_event(&second), ControlEvent::SessionStarted { session_id, .. } if session_id == new_keys.session_id)
    );
}

#[test]
fn storage_failure_closes_without_accepting_and_allows_retry() {
    let config = ConfigDir::new();
    let server = config.server();
    let code = server.enable_pairing().unwrap();
    // A directory at the target forces a real rename failure on all supported OSes.
    std::fs::create_dir(config.snapshot()).unwrap();
    let mut client = Client::connect(&server);
    let h = hello(Hello::MODE_PAIR, [0xA1; 16]);
    client.send(&ControlMessage::Hello(h.clone()));
    let ControlMessage::PairChallenge(challenge) = client.recv() else {
        panic!("expected challenge")
    };
    let (proof, _) = device_pair(&code, &h, &challenge, &[0x5E; 32]).unwrap();
    client.send(&ControlMessage::PairProof(proof));
    let mut byte = [0];
    assert_eq!(
        client.0.read(&mut byte).unwrap(),
        0,
        "must not send PAIR_ACCEPT on storage failure"
    );
    assert!(matches!(
        next_event(&server),
        ControlEvent::PairingStorageFailed {
            device_id: DEVICE,
            ..
        }
    ));
    assert!(
        server.try_event().is_none(),
        "failed persistence must not emit Paired"
    );
    let mut unknown = Client::connect(&server);
    unknown.send(&ControlMessage::Hello(hello(Hello::MODE_SESSION, [0; 16])));
    unknown.expect_error(ControlErrorMsg::NOT_PAIRED);
    assert_eq!(server.pairing_code().as_deref(), Some(code.as_str()));

    std::fs::remove_dir(config.snapshot()).unwrap();
    let mut retry = Client::connect(&server);
    let pk = retry.pair(&code);
    let keys = retry.session(&pk);
    assert!(matches!(
        next_event(&server),
        ControlEvent::Paired {
            device_id: DEVICE,
            ..
        }
    ));
    assert!(
        matches!(next_event(&server), ControlEvent::SessionStarted { session_id, .. } if session_id == keys.session_id)
    );
}

#[test]
fn file_store_replaces_one_pairing_without_losing_other_devices() {
    let config = ConfigDir::new();
    let mut store = FileStore::open(&config.0).unwrap();
    let original = paired(1, "phone", 2);
    let other = paired(3, "", 4);
    let replacement = paired(1, &"é\n".repeat(21), 5); // 63 UTF-8 bytes, including newlines
    store.put(original).unwrap();
    store.put(other.clone()).unwrap();
    store.put(replacement.clone()).unwrap();
    drop(store);
    let reopened = FileStore::open(&config.0).unwrap();
    assert_eq!(reopened.get(&replacement.device_id), Some(replacement));
    assert_eq!(reopened.get(&other.device_id), Some(other));
    assert_eq!(reopened.get(&[9; 16]), None);
}

#[test]
fn failed_replace_keeps_previous_key_in_memory_and_on_disk() {
    let config = ConfigDir::new();
    let mut store = FileStore::open(&config.0).unwrap();
    let original = paired(1, "phone", 2);
    store.put(original.clone()).unwrap();
    let backup = config.0.join("saved");
    std::fs::rename(config.snapshot(), &backup).unwrap();
    std::fs::create_dir(config.snapshot()).unwrap();
    assert!(store.put(paired(1, "replacement", 3)).is_err());
    assert_eq!(store.get(&original.device_id), Some(original.clone()));
    std::fs::remove_dir(config.snapshot()).unwrap();
    std::fs::rename(backup, config.snapshot()).unwrap();
    drop(store);
    assert_eq!(
        FileStore::open(&config.0).unwrap().get(&original.device_id),
        Some(original)
    );
    assert_eq!(
        std::fs::read_dir(config.0.join("vcam-pairings"))
            .unwrap()
            .count(),
        1,
        "failed write must remove its temporary key file"
    );
}

#[test]
fn corrupt_store_is_rejected_without_overwriting_keys() {
    let config = ConfigDir::new();
    let mut store = FileStore::open(&config.0).unwrap();
    store.put(paired(1, "phone", 2)).unwrap();
    drop(store);
    let good = std::fs::read(config.snapshot()).unwrap();
    // Every truncated prefix, including the header and full-record boundary, must fail closed.
    let mut invalid: Vec<Vec<u8>> = (0..good.len()).map(|n| good[..n].to_vec()).collect();
    let mut unknown_version = good.clone();
    unknown_version[6] = b'2';
    invalid.push(unknown_version);
    let mut trailing = good.clone();
    trailing.push(0);
    invalid.push(trailing);
    let mut duplicate = good.clone();
    duplicate[8..12].copy_from_slice(&2u32.to_le_bytes());
    duplicate.extend_from_slice(&good[12..]);
    invalid.push(duplicate);
    let mut bad_utf8 = good.clone();
    bad_utf8[61] = 0xff;
    invalid.push(bad_utf8);
    let mut long_name = good.clone();
    long_name[60] = 65;
    invalid.push(long_name);
    for bytes in invalid {
        std::fs::write(config.snapshot(), &bytes).unwrap();
        assert!(FileStore::open(&config.0).is_err());
        assert_eq!(
            std::fs::read(config.snapshot()).unwrap(),
            bytes,
            "corruption must not reset the store"
        );
    }
}

#[cfg(unix)]
#[test]
fn key_files_are_private_and_symlink_stores_are_rejected() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let config = ConfigDir::new();
    let mut store = FileStore::open(&config.0).unwrap();
    store.put(paired(1, "phone", 2)).unwrap();
    store.put(paired(1, "new phone", 3)).unwrap();
    let directory = config.0.join("vcam-pairings");
    assert_eq!(
        std::fs::metadata(directory).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert_eq!(
        std::fs::metadata(config.snapshot())
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    drop(store);
    let outside = config.0.join("outside");
    std::fs::rename(config.snapshot(), &outside).unwrap();
    symlink(&outside, config.snapshot()).unwrap();
    assert!(FileStore::open(&config.0).is_err());
}
