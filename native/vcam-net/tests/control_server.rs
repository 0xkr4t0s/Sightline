//! ControlServer over real TCP with a device-side client built from vcam-protocol
//! (task 1.2.2a; vcp.md §9–§11, FR-UX-002, NFR-SEC-001, NET-004, NFR-REL-002).
#![allow(clippy::unwrap_used, clippy::expect_used)] // test code: a panic is a test failure

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::{Duration, Instant};

use vcam_net::{ControlEvent, ControlServer, MemoryStore, ServerConfig};
use vcam_protocol::{
    ControlErrorMsg, ControlMessage, Endpoint, HEADER_LEN, Hello, Message, Pose, Role,
    SessionHandshake, SessionKeys, device_pair,
};

const DEVICE: [u8; 16] = [7; 16];
const UDP_PORT: u16 = 47_000;

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

struct Client(TcpStream);

impl Client {
    fn connect(server: &ControlServer) -> Self {
        let s = TcpStream::connect(server.local_addr()).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        Self(s)
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
        assert_eq!(challenge.udp_port, UDP_PORT);
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

#[test]
fn pair_then_session_yields_matching_keys_and_a_working_udp_endpoint() {
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
        keys: host_keys,
        peer,
        ..
    } = next_event(&server)
    else {
        panic!("expected SessionStarted")
    };
    assert_eq!((device_id, &host_keys), (DEVICE, &keys));
    assert_eq!(peer, client.0.local_addr().unwrap());

    // The keys drive the UDP channel.
    let device = Endpoint::new(Role::Device, keys.session_id, &keys.k_d2h, &keys.k_h2d).unwrap();
    let host = Endpoint::new(
        Role::Host,
        host_keys.session_id,
        &host_keys.k_d2h,
        &host_keys.k_h2d,
    )
    .unwrap();
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
    assert_eq!(host.open(&datagram).unwrap(), pose);

    drop(client);
    assert_eq!(
        next_event(&server),
        ControlEvent::SessionEnded {
            device_id: DEVICE,
            session_id: keys.session_id
        }
    );
}

#[test]
fn reconnect_uses_the_stored_pairing_and_a_new_session_id() {
    let server = server();
    let code = server.enable_pairing().unwrap();
    let mut first = Client::connect(&server);
    let pk = first.pair(&code);
    let k1 = first.session(&pk);
    drop(first);
    let mut second = Client::connect(&server);
    let k2 = second.session(&pk);
    assert_ne!(k1.session_id, k2.session_id);
    assert_ne!(k1.k_d2h, k2.k_d2h, "fresh nonces must give fresh keys");
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
fn stop_closes_idle_connections_promptly() {
    let mut server = server();
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
        idle.0.read(&mut buf).unwrap_or(0),
        0,
        "connection must be closed"
    );
    assert!(
        TcpStream::connect(server.local_addr()).is_err(),
        "listener must be closed"
    );
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
