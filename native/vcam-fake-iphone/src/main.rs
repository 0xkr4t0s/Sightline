//! Test binary that behaves like the iOS app (task 1.2.7; SRS §11): pairs with a 6-digit code
//! (or reuses a stored pairing), sets up a session, then streams scripted canonical poses from
//! `testdata/motion/*.bin` over authenticated UDP. It sends a complete `CONTROL_STATE` at 2 Hz,
//! answers `CLOCK` requests from its own monotonic clock, and reports the host's `STATUS`.
//!
//! ```text
//! vcam-fake-iphone --host 127.0.0.1:47000 --state DIR/fake-iphone.key [--code 123456]
//!                  --motion testdata/motion/scripted.bin [--rate HZ] [--linger SECONDS]
//!                  [--name NAME] [--scale S] [--locks FLAGS] [--set-origin-at FRAME]
//! ```
//! Prints `FAKE_IPHONE_PAIRED`, `FAKE_IPHONE_SESSION ...` and a final `FAKE_IPHONE_DONE ...`
//! line on stdout. Any failure exits 1 with the reason on stderr.

use std::error::Error;
use std::fmt::Debug;
use std::fs;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpStream, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use vcam_protocol::{
    Clock, ControlMessage, ControlState, Endpoint, HEADER_LEN, Hello, MAX_DATAGRAM, Message, Pose,
    Role, SessionHandshake, SessionKeys, Status, device_pair,
};

type Result<T, E = Box<dyn Error>> = std::result::Result<T, E>;

/// The device resends `CONTROL_STATE` at 2 Hz (vcp.md §6.2).
const CONTROL_INTERVAL: Duration = Duration::from_millis(500);
const TCP_TIMEOUT: Duration = Duration::from_secs(5);
/// Offset of the fake device clock, so host and device clocks visibly differ (NET-003).
const DEVICE_CLOCK_OFFSET_NS: u64 = 1_000_000_000_000;

fn version_line() -> String {
    format!(
        "vcam-fake-iphone {} (vcam-protocol {})",
        env!("CARGO_PKG_VERSION"),
        vcam_protocol::VERSION
    )
}

fn dbg_err<E: Debug>(e: E) -> Box<dyn Error> {
    format!("{e:?}").into()
}

#[derive(Debug)]
struct Args {
    host: SocketAddr,
    state: PathBuf,
    code: Option<String>,
    motion: PathBuf,
    rate: Option<f64>,
    linger: Duration,
    name: String,
    /// `CONTROL_STATE.motion_scale` (vcp.md §6.2).
    scale: f32,
    /// `CONTROL_STATE.lock_flags`: bit 0 lock height, bit 1 lock roll, bit 2 pan only.
    locks: u8,
    /// Press Set origin just before sending this frame index (bumps `origin_epoch`).
    set_origin_at: Option<usize>,
}

fn parse_args(mut it: impl Iterator<Item = String>) -> Result<Args> {
    let (mut host, mut state, mut code, mut motion, mut rate, mut linger, mut name) = (
        None,
        None,
        None,
        None,
        None,
        Duration::ZERO,
        "Fake iPhone".to_owned(),
    );
    let (mut scale, mut locks, mut set_origin_at) = (1.0f32, 0u8, None);
    while let Some(flag) = it.next() {
        let mut value = || it.next().ok_or_else(|| format!("{flag} needs a value"));
        match flag.as_str() {
            "--host" => host = Some(value()?.parse()?),
            "--state" => state = Some(PathBuf::from(value()?)),
            "--code" => code = Some(value()?),
            "--motion" => motion = Some(PathBuf::from(value()?)),
            "--rate" => {
                let hz: f64 = value()?.parse()?;
                if !(hz.is_finite() && hz > 0.0) {
                    return Err("--rate must be > 0".into());
                }
                rate = Some(hz);
            }
            "--linger" => linger = Duration::try_from_secs_f64(value()?.parse()?)?,
            "--name" => name = value()?,
            "--scale" => {
                let v: f32 = value()?.parse()?;
                if !(v.is_finite() && (0.001..=1000.0).contains(&v)) {
                    return Err("--scale must be in [0.001, 1000]".into());
                }
                scale = v;
            }
            "--locks" => {
                let v: u8 = value()?.parse()?;
                if v > 7 {
                    return Err("--locks uses bits 0-2 only".into());
                }
                locks = v;
            }
            "--set-origin-at" => set_origin_at = Some(value()?.parse()?),
            other => return Err(format!("unknown argument {other}").into()),
        }
    }
    Ok(Args {
        host: host.ok_or("--host is required")?,
        state: state.ok_or("--state is required")?,
        code,
        motion: motion.ok_or("--motion is required")?,
        rate,
        linger,
        name,
        scale,
        locks,
        set_origin_at,
    })
}

/// Canonical frames from a `VCMO` file (format in `tools/gen_testdata.py`).
#[derive(Debug, PartialEq)]
struct Motion {
    rate_hz: u16,
    frames: Vec<([f32; 3], [f32; 4])>,
}

fn parse_motion(bytes: &[u8]) -> Result<Motion> {
    let rest = bytes
        .strip_prefix(b"VCMO")
        .ok_or("not a VCMO motion file")?;
    let header = rest.get(..8).ok_or("truncated motion header")?;
    let (version, rate_hz) = (
        u16::from_le_bytes([header[0], header[1]]),
        u16::from_le_bytes([header[2], header[3]]),
    );
    let count = u32::from_le_bytes([header[4], header[5], header[6], header[7]]) as usize;
    if version != 1 || rate_hz == 0 {
        return Err(format!("unsupported motion file (version {version}, rate {rate_hz})").into());
    }
    let body = &rest[8..];
    if count == 0 || body.len() != count * 28 {
        return Err(format!("motion body is {} bytes, expected {count} x 28", body.len()).into());
    }
    let frames = body
        .chunks_exact(28)
        .map(|c| {
            let f =
                |i: usize| f32::from_le_bytes([c[4 * i], c[4 * i + 1], c[4 * i + 2], c[4 * i + 3]]);
            ([f(0), f(1), f(2)], [f(3), f(4), f(5), f(6)])
        })
        .collect();
    Ok(Motion { rate_hz, frames })
}

fn random<const N: usize>() -> Result<[u8; N]> {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes).map_err(dbg_err)?;
    Ok(bytes)
}

/// `device_id` (16) ‖ `PK` (32), the fake equivalent of the iOS Keychain entry.
fn load_pairing(path: &Path) -> Result<([u8; 16], [u8; 32])> {
    let bytes =
        fs::read(path).map_err(|e| format!("no stored pairing at {}: {e}", path.display()))?;
    let bytes: [u8; 48] = bytes
        .try_into()
        .map_err(|_| "stored pairing is not 48 bytes")?;
    let (id, pk) = bytes.split_at(16);
    Ok((id.try_into()?, pk.try_into()?))
}

fn save_pairing(path: &Path, device_id: &[u8; 16], pk: &[u8; 32]) -> Result<()> {
    let tmp = path.with_extension("tmp");
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options.open(&tmp)?;
    file.write_all(device_id)?;
    file.write_all(pk)?;
    file.sync_all()?;
    fs::rename(&tmp, path)?;
    Ok(())
}

struct Control(TcpStream);

impl Control {
    fn send(&mut self, msg: &ControlMessage) -> Result<()> {
        self.0.write_all(&msg.encode().map_err(dbg_err)?)?;
        Ok(())
    }

    fn recv(&mut self) -> Result<ControlMessage> {
        let mut header = [0u8; HEADER_LEN];
        self.0.read_exact(&mut header)?;
        let mut frame = vec![0u8; ControlMessage::frame_len(&header).map_err(dbg_err)?];
        frame
            .get_mut(..HEADER_LEN)
            .ok_or("short frame")?
            .copy_from_slice(&header);
        self.0
            .read_exact(frame.get_mut(HEADER_LEN..).ok_or("short frame")?)?;
        match ControlMessage::decode(&frame).map_err(dbg_err)? {
            ControlMessage::Error(e) => {
                Err(format!("host refused: ERROR {} {}", e.code, e.message).into())
            }
            msg => Ok(msg),
        }
    }
}

fn hello(mode: u8, device_id: [u8; 16], name: &str) -> Result<Hello> {
    Ok(Hello {
        mode,
        proto_min: 1,
        proto_max: 1,
        device_id,
        nonce_d: random()?,
        device_name: name.to_owned(),
    })
}

fn pair(tcp: &mut Control, code: &str, device_id: [u8; 16], name: &str) -> Result<[u8; 32]> {
    let hello = hello(Hello::MODE_PAIR, device_id, name)?;
    tcp.send(&ControlMessage::Hello(hello.clone()))?;
    let ControlMessage::PairChallenge(challenge) = tcp.recv()? else {
        return Err("expected PAIR_CHALLENGE".into());
    };
    let (proof, pending) = device_pair(code, &hello, &challenge, &random()?).map_err(dbg_err)?;
    tcp.send(&ControlMessage::PairProof(proof))?;
    let ControlMessage::PairAccept { m2 } = tcp.recv()? else {
        return Err("expected PAIR_ACCEPT".into());
    };
    pending
        .finish(&m2)
        .map_err(|e| format!("host proof M2 rejected: {e:?}").into())
}

fn session(
    tcp: &mut Control,
    pk: &[u8; 32],
    device_id: [u8; 16],
    name: &str,
) -> Result<(SessionKeys, u16)> {
    let hello = hello(Hello::MODE_SESSION, device_id, name)?;
    tcp.send(&ControlMessage::Hello(hello.clone()))?;
    let ControlMessage::SessionChallenge(challenge) = tcp.recv()? else {
        return Err("expected SESSION_CHALLENGE".into());
    };
    let handshake = SessionHandshake::new(pk, &hello, &challenge).map_err(dbg_err)?;
    let proof = handshake.device_proof().ok_or("session proof failed")?;
    tcp.send(&ControlMessage::SessionProof { proof })?;
    let ControlMessage::SessionAccept { proof: host_proof } = tcp.recv()? else {
        return Err("expected SESSION_ACCEPT".into());
    };
    if !handshake.verify_host_proof(&proof, &host_proof) {
        return Err("host session proof is wrong".into());
    }
    Ok((
        handshake.keys().ok_or("session key derivation failed")?,
        challenge.udp_port,
    ))
}

/// UDP side of one session.
struct Stream {
    udp: UdpSocket,
    endpoint: Endpoint,
    epoch: Instant,
    out: Vec<u8>,
    buf: [u8; MAX_DATAGRAM + 1],
    poses: u64,
    clock_replies: u64,
    status: Option<Status>,
    last_control: Option<Instant>,
    control: ControlState,
}

impl Stream {
    fn device_ns(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_nanos()).unwrap_or(u64::MAX) + DEVICE_CLOCK_OFFSET_NS
    }

    fn send(&mut self, msg: &Message) -> Result<()> {
        self.out.clear();
        self.endpoint.seal(msg, &mut self.out).map_err(dbg_err)?;
        self.udp.send(&self.out)?;
        Ok(())
    }

    /// Sends the complete v1 `CONTROL_STATE` at once after a change, then every 500 ms.
    fn control_due(&mut self) -> Result<()> {
        if self
            .last_control
            .is_none_or(|t| t.elapsed() >= CONTROL_INTERVAL)
        {
            self.send(&Message::ControlState(self.control))?;
            self.last_control = Some(Instant::now());
        }
        Ok(())
    }

    /// Answers host datagrams until `until`.
    fn service(&mut self, until: Instant) -> Result<()> {
        loop {
            let now = Instant::now();
            if now >= until {
                return Ok(());
            }
            self.udp
                .set_read_timeout(Some((until - now).max(Duration::from_millis(1))))?;
            let n = match self.udp.recv(&mut self.buf) {
                Ok(n) => n,
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) =>
                {
                    return Ok(());
                }
                // A closed host port surfaces as ConnectionRefused on some OSes; keep going.
                Err(e) if e.kind() == io::ErrorKind::ConnectionRefused => continue,
                Err(e) => return Err(e.into()),
            };
            let t2 = self.device_ns();
            match self.endpoint.open(self.buf.get(..n).unwrap_or_default()) {
                Ok(Message::Clock(Clock::Request { t1 })) => {
                    let reply = Message::Clock(Clock::Reply {
                        t1,
                        t2,
                        t3: self.device_ns(),
                    });
                    self.send(&reply)?;
                    self.clock_replies += 1;
                }
                Ok(Message::Status(s)) => {
                    if self
                        .status
                        .as_ref()
                        .is_none_or(|old| s.status_seq > old.status_seq)
                    {
                        self.status = Some(s);
                    }
                }
                Ok(_) | Err(_) => {}
            }
        }
    }
}

fn run(args: &Args) -> Result<String> {
    let motion = parse_motion(&fs::read(&args.motion)?)?;
    let rate = args.rate.unwrap_or(f64::from(motion.rate_hz));

    let stream = TcpStream::connect_timeout(&args.host, TCP_TIMEOUT)?;
    stream.set_read_timeout(Some(TCP_TIMEOUT))?;
    stream.set_nodelay(true)?;
    let mut tcp = Control(stream);
    let (device_id, pk) = match &args.code {
        Some(code) => {
            let device_id = random()?;
            let pk = pair(&mut tcp, code, device_id, &args.name)?;
            save_pairing(&args.state, &device_id, &pk)?;
            println!("FAKE_IPHONE_PAIRED");
            (device_id, pk)
        }
        None => load_pairing(&args.state)?,
    };
    let (keys, udp_port) = session(&mut tcp, &pk, device_id, &args.name)?;
    println!(
        "FAKE_IPHONE_SESSION session_id={} udp_port={udp_port}",
        keys.session_id
    );
    io::stdout().flush()?;

    let udp = UdpSocket::bind(if args.host.is_ipv4() {
        "0.0.0.0:0"
    } else {
        "[::]:0"
    })?;
    udp.connect(SocketAddr::new(args.host.ip(), udp_port))?;
    let mut s = Stream {
        udp,
        endpoint: Endpoint::new(Role::Device, keys.session_id, &keys.k_d2h, &keys.k_h2d)
            .ok_or("invalid session id")?,
        epoch: Instant::now(),
        out: Vec::with_capacity(MAX_DATAGRAM),
        buf: [0; MAX_DATAGRAM + 1],
        poses: 0,
        clock_replies: 0,
        status: None,
        last_control: None,
        control: ControlState {
            state_seq: 1,
            motion_scale: Some(args.scale),
            lock_flags: Some(args.locks),
            origin_epoch: Some(0),
        },
    };
    let period = Duration::from_secs_f64(1.0 / rate);
    let mut next = Instant::now();
    for (i, (position_m, orientation)) in motion.frames.iter().enumerate() {
        s.service(next)?;
        if args.set_origin_at == Some(i) {
            // Set origin: a new complete state with the next epoch, sent before this frame.
            s.control.state_seq += 1;
            s.control.origin_epoch = s.control.origin_epoch.map(|e| e.wrapping_add(1));
            s.last_control = None;
        }
        s.control_due()?;
        let pose = Pose {
            seq: u32::try_from(i + 1)?,
            capture_time_ns: s.device_ns(),
            position_m: *position_m,
            orientation: *orientation,
            tracking_state: Pose::TRACKING_NORMAL,
            flags: 0,
        };
        s.send(&Message::Pose(pose))?;
        s.poses += 1;
        next += period;
    }
    let end = Instant::now() + args.linger;
    while Instant::now() < end {
        s.service(end.min(Instant::now() + CONTROL_INTERVAL))?;
        s.control_due()?;
    }
    drop(tcp); // closing TCP ends the session on the host
    let status = s.status.unwrap_or(Status {
        status_seq: 0,
        applied_pose_seq: 0,
        control_ack: 0,
        error_code: 0,
        flags: 0,
        camera_name: String::new(),
    });
    Ok(format!(
        "FAKE_IPHONE_DONE session_id={} poses={} clock_replies={} status_seq={} applied_pose_seq={} control_ack={} camera={}",
        keys.session_id,
        s.poses,
        s.clock_replies,
        status.status_seq,
        status.applied_pose_seq,
        status.control_ack,
        status.camera_name
    ))
}

fn main() -> ExitCode {
    let mut argv = std::env::args().skip(1).peekable();
    if argv.peek().is_some_and(|a| a == "--version") {
        println!("{}", version_line());
        return ExitCode::SUCCESS;
    }
    match parse_args(argv).and_then(|args| run(&args)) {
        Ok(summary) => {
            println!("{summary}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("vcam-fake-iphone: error: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)] // test code: a panic is a test failure

    use super::*;

    #[test]
    fn version_line_names_binary_and_protocol() {
        let line = super::version_line();
        assert!(line.starts_with("vcam-fake-iphone "), "{line}");
        assert!(
            line.contains(&format!("vcam-protocol {}", vcam_protocol::VERSION)),
            "{line}"
        );
    }

    #[test]
    fn scripted_motion_file_parses_and_malformed_files_are_rejected() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../testdata/motion/scripted.bin"
        );
        let bytes = fs::read(path).unwrap();
        let motion = parse_motion(&bytes).unwrap();
        assert_eq!((motion.rate_hz, motion.frames.len()), (60, 390));
        assert_eq!(motion.frames[389].0, [-2.0, 0.0, 3.1]);
        assert!(
            parse_motion(&bytes[..bytes.len() - 1]).is_err(),
            "truncated"
        );
        assert!(parse_motion(b"XXXX").is_err(), "magic");
        let mut wrong_count = bytes.clone();
        wrong_count[8] = wrong_count[8].wrapping_add(1);
        assert!(parse_motion(&wrong_count).is_err(), "count");
    }
}
