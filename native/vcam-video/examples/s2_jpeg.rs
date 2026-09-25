//! Spike S-2a: JPEG encode timing for Stage A video (NET-VID-001).
//!
//! Input: raw RGBA frames read back from Blender (bottom-up rows), named
//! `<anything>_<W>x<H>.rgba`. Produce them with
//! `blender --background --factory-startup --python tests/bench_render.py -- --dump-raw DIR`.
//!
//! Run: `cargo run --release -p vcam-video --example s2_jpeg -- DIR/*.rgba`
//!
//! For each frame, encoder (libjpeg-turbo via `turbojpeg`; pure Rust `jpeg-encoder`), and
//! quality: encode 4:2:0 many times on one thread, and report median/p95 time, size,
//! the bitrate at 30 fps, and PSNR after decoding with libjpeg-turbo. The one-time
//! vertical flip (Blender rows are bottom-up) is timed separately: in the real pipeline it
//! is folded into the single copy out of Blender's buffer (SRS §13.1).

use std::error::Error;
use std::path::Path;
use std::time::Instant;

const ITERATIONS: usize = 100;
const WARMUP: usize = 5;
const QUALITIES: [u8; 3] = [70, 80, 90];

type Res<T> = Result<T, Box<dyn Error>>;

fn dims_from_name(path: &Path) -> Res<(usize, usize)> {
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .ok_or("bad file name")?;
    let size = stem.rsplit('_').next().ok_or("no _WxH suffix")?;
    let (w, h) = size.split_once('x').ok_or("no WxH suffix")?;
    Ok((w.parse()?, h.parse()?))
}

fn flip_rows(bottom_up: &[u8], width: usize, height: usize) -> Vec<u8> {
    let row = width * 4;
    let mut out = Vec::with_capacity(bottom_up.len());
    for y in (0..height).rev() {
        out.extend_from_slice(&bottom_up[y * row..(y + 1) * row]);
    }
    out
}

fn psnr_rgb(a: &[u8], b: &[u8]) -> f64 {
    let (mut se, mut n) = (0.0f64, 0usize);
    for (pa, pb) in a.as_chunks::<4>().0.iter().zip(b.as_chunks::<4>().0) {
        for c in 0..3 {
            let d = f64::from(pa[c]) - f64::from(pb[c]);
            se += d * d;
            n += 1;
        }
    }
    let mse = se / n as f64;
    if mse == 0.0 {
        f64::INFINITY
    } else {
        10.0 * (255.0 * 255.0 / mse).log10()
    }
}

/// Times `encode` and returns (median ms, p95 ms, last output).
fn time_it(mut encode: impl FnMut() -> Res<Vec<u8>>) -> Res<(f64, f64, Vec<u8>)> {
    let mut out = Vec::new();
    for _ in 0..WARMUP {
        out = encode()?;
    }
    let mut ms = Vec::with_capacity(ITERATIONS);
    for _ in 0..ITERATIONS {
        let t = Instant::now();
        out = encode()?;
        ms.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    ms.sort_by(f64::total_cmp);
    let p95 = ms[((ms.len() - 1) as f64 * 0.95).round() as usize];
    Ok((ms[ms.len() / 2], p95, out))
}

fn encode_turbo(rgba: &[u8], width: usize, height: usize, quality: u8) -> Res<Vec<u8>> {
    let mut c = turbojpeg::Compressor::new()?;
    c.set_quality(i32::from(quality))?;
    c.set_subsamp(turbojpeg::Subsamp::Sub2x2)?;
    let image = turbojpeg::Image {
        pixels: rgba,
        width,
        pitch: width * 4,
        height,
        format: turbojpeg::PixelFormat::RGBA,
    };
    Ok(c.compress_to_vec(image)?)
}

fn encode_pure(rgba: &[u8], width: usize, height: usize, quality: u8) -> Res<Vec<u8>> {
    let mut out = Vec::with_capacity(rgba.len() / 8);
    let mut e = jpeg_encoder::Encoder::new(&mut out, quality);
    e.set_sampling_factor(jpeg_encoder::SamplingFactor::R_4_2_0);
    e.encode(
        rgba,
        u16::try_from(width)?,
        u16::try_from(height)?,
        jpeg_encoder::ColorType::Rgba,
    )?;
    Ok(out)
}

fn main() -> Res<()> {
    let files: Vec<String> = std::env::args().skip(1).collect();
    if files.is_empty() {
        return Err("usage: s2_jpeg FRAME_WxH.rgba...".into());
    }
    println!("S2_HEADER frame,encoder,quality,median_ms,p95_ms,bytes,mbit_s_at_30fps,psnr_db");
    for file in files {
        let path = Path::new(&file);
        let (width, height) = dims_from_name(path)?;
        let raw = std::fs::read(path)?;
        if raw.len() != width * height * 4 {
            return Err(format!(
                "{file}: {} bytes, expected {}",
                raw.len(),
                width * height * 4
            )
            .into());
        }
        let name = path.file_stem().and_then(|s| s.to_str()).unwrap_or("?");
        let (flip_med, flip_p95, rgba) = time_it(|| Ok(flip_rows(&raw, width, height)))?;
        println!("S2_FLIP {name} median_ms={flip_med:.3} p95_ms={flip_p95:.3}");

        for quality in QUALITIES {
            type Enc = fn(&[u8], usize, usize, u8) -> Res<Vec<u8>>;
            let encoders: [(&str, Enc); 2] =
                [("turbojpeg", encode_turbo), ("jpeg-encoder", encode_pure)];
            for (enc_name, enc) in encoders {
                let (med, p95, jpeg) = time_it(|| enc(&rgba, width, height, quality))?;
                let decoded = turbojpeg::decompress(&jpeg, turbojpeg::PixelFormat::RGBA)?;
                if (decoded.width, decoded.height) != (width, height) {
                    return Err(format!("{name} {enc_name}: decoded size mismatch").into());
                }
                let psnr = psnr_rgb(&rgba, &decoded.pixels);
                let mbit = jpeg.len() as f64 * 8.0 * 30.0 / 1e6;
                println!(
                    "S2_ROW {name},{enc_name},{quality},{med:.3},{p95:.3},{},{mbit:.1},{psnr:.2}",
                    jpeg.len()
                );
            }
        }
    }
    Ok(())
}
