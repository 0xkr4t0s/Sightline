//! Spike S-2c: OpenH264 as the software H.264 fallback (NET-VID-003).
//!
//! Input: a directory of raw RGBA Blender readbacks (bottom-up rows) named `solid_<W>x<H>.rgba`,
//! from `blender --background --factory-startup --python tests/bench_render.py -- --dump-raw DIR`.
//!
//! Run: `cargo run --release -p vcam-video --example s2_openh264 -- DIR [CISCO_LIB]`
//!
//! Backends:
//! - `source`: the OpenH264 C source bundled in `openh264-sys2`, compiled into this binary. On
//!   arm64 the crate compiles no assembly, so this is plain C.
//! - `cisco`: Cisco's prebuilt library at CISCO_LIB, loaded at runtime after the crate checks its
//!   SHA-256 against its list of known Cisco releases (`from_blob_path`).
//!
//! Same pacing and motion as `s2_videotoolbox`: 30 fps real time, the image shifted 2 px per
//! frame. The encoder is synchronous, so its latency is the `encode` call itself. The RGBA->YUV
//! 4:2:0 conversion (plus the flip and shift) is timed separately. With threads = 1 the stream is
//! written as Annex-B `.h264` to DIR so it can be decoded independently.

use std::error::Error;
use std::path::Path;
use std::time::{Duration, Instant};

use openh264::OpenH264API;
use openh264::encoder::{
    BitRate, Encoder, EncoderConfig, FrameRate, FrameType, IntraFramePeriod, RateControlMode,
    UsageType,
};
use openh264::formats::{RgbaSliceU8, YUVBuffer};

type Res<T> = Result<T, Box<dyn Error>>;

const FPS: u32 = 30;
const FRAMES: usize = 150;
const WARMUP: usize = 10;
const SHIFT_PX: usize = 2;
const RESOLUTIONS: [(usize, usize); 3] = [(960, 540), (1280, 720), (1920, 1080)];
const THREADS: [u16; 2] = [1, 4];

/// Same target as S-2b: about 0.2 bits per pixel at 30 fps.
fn bitrate_for(pixels: usize) -> u32 {
    u32::try_from(pixels * 6).unwrap_or(u32::MAX)
}

/// Bottom-up RGBA -> top-down RGBA shifted right by `shift` px (wrapping) into `dst`.
fn flip_shift(src: &[u8], dst: &mut [u8], width: usize, height: usize, shift: usize) {
    let row = width * 4;
    let split = (shift % width) * 4;
    for y in 0..height {
        let s = &src[(height - 1 - y) * row..(height - y) * row];
        let d = &mut dst[y * row..(y + 1) * row];
        d[split..].copy_from_slice(&s[..row - split]);
        d[..split].copy_from_slice(&s[row - split..]);
    }
}

fn stats(mut v: Vec<f64>) -> (f64, f64, f64) {
    if v.is_empty() {
        return (f64::NAN, f64::NAN, f64::NAN);
    }
    v.sort_by(f64::total_cmp);
    let at = |q: f64| v[((v.len() - 1) as f64 * q).round() as usize];
    (at(0.5), at(0.95), at(1.0))
}

fn api(backend: &str, cisco: Option<&str>) -> Res<OpenH264API> {
    match backend {
        "source" => Ok(OpenH264API::from_source()),
        "cisco" => Ok(OpenH264API::from_blob_path(
            cisco.ok_or("no Cisco library path")?,
        )?),
        _ => Err(format!("unknown backend {backend}").into()),
    }
}

fn run(
    dir: &Path,
    width: usize,
    height: usize,
    backend: &str,
    cisco: Option<&str>,
    threads: u16,
) -> Res<()> {
    let src = std::fs::read(dir.join(format!("solid_{width}x{height}.rgba")))?;
    if src.len() != width * height * 4 {
        return Err(format!("{width}x{height}: wrong frame size").into());
    }
    let target = bitrate_for(width * height);
    let config = EncoderConfig::new()
        .usage_type(UsageType::CameraVideoRealTime)
        .rate_control_mode(RateControlMode::Bitrate)
        .bitrate(BitRate::from_bps(target))
        .max_frame_rate(FrameRate::from_hz(FPS as f32))
        .intra_frame_period(IntraFramePeriod::from_num_frames(FPS * 2))
        .skip_frames(false)
        .num_threads(threads);
    let mut encoder = Encoder::with_api_config(api(backend, cisco)?, config)?;

    let mut rgba = vec![0u8; width * height * 4];
    let mut yuv = YUVBuffer::new(width, height);
    let mut stream = (threads == 1).then(Vec::new);
    let (mut convert_ms, mut encode_ms) = (Vec::new(), Vec::new());
    let (mut bytes, mut idr, mut empty) = (0usize, 0usize, 0usize);
    let period = Duration::from_secs_f64(1.0 / f64::from(FPS));
    let start = Instant::now();
    for i in 0..WARMUP + FRAMES {
        let due = start + period * u32::try_from(i)?;
        if let Some(wait) = due.checked_duration_since(Instant::now()) {
            std::thread::sleep(wait);
        }
        let t0 = Instant::now();
        flip_shift(&src, &mut rgba, width, height, i * SHIFT_PX);
        yuv.read_rgb8(RgbaSliceU8::new(&rgba, (width, height)));
        let t1 = Instant::now();
        let bitstream = encoder.encode(&yuv)?;
        let t2 = Instant::now();
        let frame_type = bitstream.frame_type();
        let out = bitstream.to_vec();
        if out.is_empty() {
            empty += 1;
        }
        if matches!(frame_type, FrameType::IDR) {
            idr += 1;
        }
        if let Some(s) = stream.as_mut() {
            s.extend_from_slice(&out);
        }
        if i >= WARMUP {
            convert_ms.push((t1 - t0).as_secs_f64() * 1000.0);
            encode_ms.push((t2 - t1).as_secs_f64() * 1000.0);
            bytes += out.len();
        }
    }
    let mbit = bytes as f64 * 8.0 / (FRAMES as f64 / f64::from(FPS)) / 1e6;
    let (enc_med, enc_p95, enc_max) = stats(encode_ms);
    let (conv_med, conv_p95, _) = stats(convert_ms);
    println!(
        "S2C_ROW {backend},{threads},{width}x{height},{:.2},{enc_med:.2},{enc_p95:.2},{enc_max:.2},{conv_med:.2},{conv_p95:.2},{mbit:.2},{idr},{empty}",
        f64::from(target) / 1e6,
    );
    if let Some(s) = stream {
        let path = dir.join(format!("oh264_{backend}_{width}x{height}.h264"));
        std::fs::write(&path, s)?;
        println!("S2C_STREAM {}", path.display());
    }
    Ok(())
}

fn main() -> Res<()> {
    let mut args = std::env::args().skip(1);
    let dir = args.next().ok_or("usage: s2_openh264 DIR [CISCO_LIB]")?;
    let cisco = args.next();
    let dir = Path::new(&dir);
    println!(
        "S2C_HEADER backend,threads,res,target_mbit,encode_med_ms,encode_p95_ms,encode_max_ms,convert_med_ms,convert_p95_ms,actual_mbit,idr_frames,empty_frames"
    );
    let backends: &[&str] = if cisco.is_some() {
        &["source", "cisco"]
    } else {
        &["source"]
    };
    for (width, height) in RESOLUTIONS {
        for backend in backends {
            for threads in THREADS {
                run(dir, width, height, backend, cisco.as_deref(), threads)?;
            }
        }
    }
    Ok(())
}
