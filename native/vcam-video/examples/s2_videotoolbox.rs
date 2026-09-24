//! Spike S-2b: H.264 encode latency with VideoToolbox (macOS), for Stage B video (NET-VID-002/003).
//!
//! Input: a directory of raw RGBA Blender readbacks (bottom-up rows) named `solid_<W>x<H>.rgba`,
//! from `blender --background --factory-startup --python tests/bench_render.py -- --dump-raw DIR`.
//!
//! Run: `cargo run --release -p vcam-video --example s2_videotoolbox -- DIR`
//!
//! Frames are submitted in real time at 30 fps (a live stream, not a batch). Each frame is the
//! Blender image shifted 2 px further right, so the encoder sees motion. Measured per frame:
//! the fill of a pool `CVPixelBuffer` (flip + optional RGBA->BGRA swizzle; this is the single
//! copy out of Blender's buffer), the `encode_frame` call, and the latency from submit to the
//! output callback. The first configuration's stream is written as Annex-B `.h264` to DIR so it
//! can be decoded independently (`ffmpeg`).
//!
//! This is an encoder-backend prototype, the one kind of module allowed to use `unsafe`
//! (NFR-QA-004). Every unsafe block carries a `// SAFETY:` comment.
#![allow(unsafe_code)]

#[cfg(target_os = "macos")]
mod vt {
    use std::error::Error;
    use std::ffi::c_void;
    use std::path::Path;
    use std::ptr::{self, NonNull};
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    use objc2_core_foundation::{CFBoolean, CFDictionary, CFNumber, CFRetained, CFString, CFType};
    use objc2_core_media::{
        CMFormatDescription, CMSampleBuffer, CMTime,
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex, kCMVideoCodecType_H264,
    };
    use objc2_core_video::{
        CVPixelBuffer, CVPixelBufferGetBaseAddress, CVPixelBufferGetBytesPerRow,
        CVPixelBufferLockBaseAddress, CVPixelBufferLockFlags, CVPixelBufferPool,
        CVPixelBufferUnlockBaseAddress, kCVPixelBufferHeightKey,
        kCVPixelBufferIOSurfacePropertiesKey, kCVPixelBufferPixelFormatTypeKey,
        kCVPixelBufferWidthKey, kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA,
        kCVReturnSuccess,
    };
    use objc2_video_toolbox::{
        VTCompressionSession, VTEncodeInfoFlags, VTSessionSetProperty,
        kVTCompressionPropertyKey_AllowFrameReordering, kVTCompressionPropertyKey_AverageBitRate,
        kVTCompressionPropertyKey_ExpectedFrameRate, kVTCompressionPropertyKey_MaxKeyFrameInterval,
        kVTCompressionPropertyKey_ProfileLevel, kVTCompressionPropertyKey_RealTime,
        kVTProfileLevel_H264_High_AutoLevel, kVTProfileLevel_H264_Main_AutoLevel,
        kVTVideoEncoderSpecification_EnableLowLatencyRateControl,
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder,
    };

    type Res<T> = Result<T, Box<dyn Error>>;

    const FPS: i32 = 30;
    const FRAMES: usize = 150;
    const WARMUP: usize = 10;
    const SHIFT_PX: usize = 2;
    const RESOLUTIONS: [(usize, usize); 3] = [(960, 540), (1280, 720), (1920, 1080)];

    #[derive(Clone, Copy)]
    struct Config {
        name: &'static str,
        low_latency: bool,
        rgba_input: bool,
        bitrate: fn(usize) -> i32,
    }

    /// Bits per second: about 0.2 bits per pixel at 30 fps, i.e. 3 Mbit/s at 540p, 5.5 at 720p,
    /// 12.4 at 1080p (NET-VID-002 targets 4-10 Mbit/s at 720p).
    fn bitrate_for(pixels: usize) -> i32 {
        i32::try_from(pixels * 6).unwrap_or(i32::MAX)
    }

    const CONFIGS: [Config; 3] = [
        Config {
            name: "lowlatency-bgra",
            low_latency: true,
            rgba_input: false,
            bitrate: bitrate_for,
        },
        Config {
            name: "lowlatency-rgba",
            low_latency: true,
            rgba_input: true,
            bitrate: bitrate_for,
        },
        Config {
            name: "realtime-bgra",
            low_latency: false,
            rgba_input: false,
            bitrate: bitrate_for,
        },
    ];

    /// Filled by the VideoToolbox output callback (on a VideoToolbox thread).
    struct Collector {
        submitted: Vec<Option<Instant>>,
        latency_ms: Vec<Option<f64>>,
        sizes: Vec<usize>,
        idr_frames: usize,
        dropped: usize,
        errors: Vec<i32>,
        /// Annex-B stream (start codes + SPS/PPS before each IDR), if requested.
        annex_b: Option<Vec<u8>>,
        nal_length_size: usize,
    }

    fn check(status: i32, what: &str) -> Res<()> {
        if status == 0 {
            Ok(())
        } else {
            Err(format!("{what} failed: OSStatus {status}").into())
        }
    }

    /// Appends each length-prefixed NAL unit of `avcc` to `out` as Annex-B; returns whether
    /// any NAL unit is an IDR slice (type 5). Stops at the first malformed length.
    fn avcc_to_annex_b(avcc: &[u8], len_size: usize, out: Option<&mut Vec<u8>>) -> bool {
        let mut idr = false;
        let mut out = out;
        let mut pos = 0;
        while pos + len_size <= avcc.len() {
            let len = avcc[pos..pos + len_size]
                .iter()
                .fold(0usize, |acc, b| (acc << 8) | usize::from(*b));
            pos += len_size;
            let Some(nal) = avcc.get(pos..pos + len) else {
                break;
            };
            if nal.first().is_some_and(|h| h & 0x1f == 5) {
                idr = true;
            }
            if let Some(buf) = out.as_deref_mut() {
                buf.extend_from_slice(&[0, 0, 0, 1]);
                buf.extend_from_slice(nal);
            }
            pos += len;
        }
        idr
    }

    /// SPS/PPS of the stream as Annex-B, plus the NAL length-prefix size.
    fn parameter_sets(desc: &CMFormatDescription) -> Option<(Vec<u8>, usize)> {
        let mut count = 0usize;
        let mut len_size: i32 = 0;
        // SAFETY: `desc` is a valid H.264 format description kept alive by the caller; the out
        // pointers are valid locals; data/size pointers may be null for a count-only query.
        let status = unsafe {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc,
                0,
                ptr::null_mut(),
                ptr::null_mut(),
                &mut count,
                &mut len_size,
            )
        };
        if status != 0 {
            return None;
        }
        let mut out = Vec::new();
        for i in 0..count {
            let (mut p, mut n): (*const u8, usize) = (ptr::null(), 0);
            // SAFETY: as above; `i < count`. On success `p` points at `n` bytes inside `desc`,
            // which stays retained for this whole function.
            let status = unsafe {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    desc,
                    i,
                    &mut p,
                    &mut n,
                    ptr::null_mut(),
                    ptr::null_mut(),
                )
            };
            if status != 0 || p.is_null() {
                return None;
            }
            out.extend_from_slice(&[0, 0, 0, 1]);
            // SAFETY: VideoToolbox returned a non-null pointer to `n` readable bytes (see above).
            out.extend_from_slice(unsafe { std::slice::from_raw_parts(p, n) });
        }
        Some((out, usize::try_from(len_size).ok()?))
    }

    /// VTCompressionOutputCallback.
    ///
    /// # Safety
    /// `ctx` is the `Mutex<Collector>` passed to `VTCompressionSession::create`, alive until the
    /// session is invalidated; `frame_ref` is the frame index cast to a pointer; `sample` is
    /// null or a valid `CMSampleBuffer` for the duration of the call.
    unsafe extern "C-unwind" fn on_output(
        ctx: *mut c_void,
        frame_ref: *mut c_void,
        status: i32,
        flags: VTEncodeInfoFlags,
        sample: *mut CMSampleBuffer,
    ) {
        let now = Instant::now();
        // SAFETY: see the function's safety contract; the collector outlives the session.
        let collector = unsafe { &*ctx.cast::<Mutex<Collector>>() };
        let Ok(mut c) = collector.lock() else { return };
        let index = frame_ref as usize;
        if status != 0 {
            c.errors.push(status);
            return;
        }
        if flags.contains(VTEncodeInfoFlags::FrameDropped) || sample.is_null() {
            c.dropped += 1;
            return;
        }
        // SAFETY: `sample` is non-null and valid for this call (contract above).
        let sample = unsafe { &*sample };
        // SAFETY: `sample` is a valid CMSampleBuffer produced by the encoder.
        let (Some(block), Some(desc)) = (unsafe { sample.data_buffer() }, unsafe {
            sample.format_description()
        }) else {
            c.errors.push(-1);
            return;
        };
        // SAFETY: `block` is a valid CMBlockBuffer retained above.
        let len = unsafe { block.data_length() };
        let mut avcc = vec![0u8; len];
        if let Some(dst) = NonNull::new(avcc.as_mut_ptr().cast::<c_void>()) {
            // SAFETY: `dst` points at `len` writable bytes; the range [0, len) is within `block`.
            if unsafe { block.copy_data_bytes(0, len, dst) } != 0 {
                c.errors.push(-2);
                return;
            }
        }
        if c.nal_length_size == 0 {
            match parameter_sets(&desc) {
                Some((_, n)) => c.nal_length_size = n,
                None => {
                    c.errors.push(-3);
                    return;
                }
            }
        }
        let len_size = c.nal_length_size;
        let idr = avcc_to_annex_b(&avcc, len_size, None);
        if let Some(mut stream) = c.annex_b.take() {
            if idr && let Some((ps, _)) = parameter_sets(&desc) {
                stream.extend_from_slice(&ps);
            }
            avcc_to_annex_b(&avcc, len_size, Some(&mut stream));
            c.annex_b = Some(stream);
        }
        if idr {
            c.idr_frames += 1;
        }
        c.sizes.push(len);
        if let Some(Some(t0)) = c.submitted.get(index).copied()
            && let Some(slot) = c.latency_ms.get_mut(index)
        {
            *slot = Some((now - t0).as_secs_f64() * 1000.0);
        }
    }

    fn set_prop(session: &VTCompressionSession, key: &CFString, value: &CFType) -> Res<()> {
        // SAFETY: `session` is a live compression session; key/value are valid CF objects of the
        // types VideoToolbox documents for these keys.
        check(
            unsafe { VTSessionSetProperty(session, key, Some(value)) },
            "VTSessionSetProperty",
        )
    }

    fn create_session(
        width: usize,
        height: usize,
        cfg: Config,
        collector: &Mutex<Collector>,
    ) -> Res<CFRetained<VTCompressionSession>> {
        // SAFETY: reading immutable framework constants.
        let (k_hw, k_ll) = unsafe {
            (
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder,
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl,
            )
        };
        let t: &CFType = CFBoolean::new(true);
        let spec = if cfg.low_latency {
            CFDictionary::<CFString, CFType>::from_slices(&[k_hw, k_ll], &[t, t])
        } else {
            CFDictionary::<CFString, CFType>::from_slices(&[k_hw], &[t])
        };
        let pixel_format = if cfg.rgba_input {
            kCVPixelFormatType_32RGBA
        } else {
            kCVPixelFormatType_32BGRA
        };
        let fmt = CFNumber::new_i64(i64::from(pixel_format));
        let w = CFNumber::new_i64(i64::try_from(width)?);
        let h = CFNumber::new_i64(i64::try_from(height)?);
        let iosurface = CFDictionary::<CFString, CFType>::empty();
        // SAFETY: reading immutable framework constants.
        let (k_fmt, k_w, k_h, k_ios) = unsafe {
            (
                kCVPixelBufferPixelFormatTypeKey,
                kCVPixelBufferWidthKey,
                kCVPixelBufferHeightKey,
                kCVPixelBufferIOSurfacePropertiesKey,
            )
        };
        let source_attrs = CFDictionary::<CFString, CFType>::from_slices(
            &[k_fmt, k_w, k_h, k_ios],
            &[&fmt, &w, &h, &iosurface],
        );

        let mut out: *mut VTCompressionSession = ptr::null_mut();
        // SAFETY: all CF arguments are valid for the call; `on_output` matches
        // VTCompressionOutputCallback; `collector` outlives the session (the caller invalidates
        // the session before dropping it); `out` is a valid out-pointer.
        let status = unsafe {
            VTCompressionSession::create(
                None,
                i32::try_from(width)?,
                i32::try_from(height)?,
                kCMVideoCodecType_H264,
                Some(spec.as_ref()),
                Some(source_attrs.as_ref()),
                None,
                Some(on_output),
                ptr::from_ref(collector).cast_mut().cast::<c_void>(),
                NonNull::from(&mut out),
            )
        };
        check(status, "VTCompressionSessionCreate")?;
        let session = NonNull::new(out).ok_or("VTCompressionSessionCreate returned null")?;
        // SAFETY: `create` follows the Create rule, so we own this +1 reference.
        let session = unsafe { CFRetained::from_raw(session) };

        // SAFETY: reading immutable framework constants.
        let (k_rt, k_reorder, k_profile, k_rate, k_fps, k_gop, main, high) = unsafe {
            (
                kVTCompressionPropertyKey_RealTime,
                kVTCompressionPropertyKey_AllowFrameReordering,
                kVTCompressionPropertyKey_ProfileLevel,
                kVTCompressionPropertyKey_AverageBitRate,
                kVTCompressionPropertyKey_ExpectedFrameRate,
                kVTCompressionPropertyKey_MaxKeyFrameInterval,
                kVTProfileLevel_H264_Main_AutoLevel,
                kVTProfileLevel_H264_High_AutoLevel,
            )
        };
        set_prop(&session, k_rt, CFBoolean::new(true))?;
        set_prop(&session, k_reorder, CFBoolean::new(false))?; // no B-frames (NET-VID-002)
        // Apple documents low-latency rate control for Constrained Baseline/High; Main is tried
        // first because NET-VID-002 names it, then High.
        if set_prop(&session, k_profile, main).is_err() {
            set_prop(&session, k_profile, high)?;
        }
        set_prop(
            &session,
            k_rate,
            &CFNumber::new_i32((cfg.bitrate)(width * height)),
        )?;
        set_prop(&session, k_fps, &CFNumber::new_i32(FPS))?;
        set_prop(&session, k_gop, &CFNumber::new_i32(FPS * 2))?;
        // SAFETY: `session` is live.
        let status = unsafe { session.prepare_to_encode_frames() };
        check(status, "PrepareToEncodeFrames")?;
        Ok(session)
    }

    /// Copies the bottom-up RGBA frame into `pb` top-down, shifted right by `shift` px, as
    /// RGBA or BGRA. This is the single copy out of Blender's buffer.
    fn fill(
        pb: &CVPixelBuffer,
        src: &[u8],
        width: usize,
        height: usize,
        shift: usize,
        bgra: bool,
    ) -> Res<()> {
        // SAFETY: `pb` is a valid pixel buffer from the session's pool.
        let status = unsafe { CVPixelBufferLockBaseAddress(pb, CVPixelBufferLockFlags(0)) };
        check(status, "lock")?;
        let base = CVPixelBufferGetBaseAddress(pb).cast::<u8>();
        let stride = CVPixelBufferGetBytesPerRow(pb);
        if base.is_null() || stride < width * 4 {
            // SAFETY: balanced with the lock above.
            unsafe { CVPixelBufferUnlockBaseAddress(pb, CVPixelBufferLockFlags(0)) };
            return Err("pixel buffer has no base address or a short stride".into());
        }
        // SAFETY: the buffer is locked and is `height` rows of `stride >= width * 4` bytes.
        let dst = unsafe { std::slice::from_raw_parts_mut(base, stride * height) };
        let row = width * 4;
        let split = (shift % width) * 4;
        for y in 0..height {
            let s = &src[(height - 1 - y) * row..(height - y) * row];
            let d = &mut dst[y * stride..y * stride + row];
            d[split..].copy_from_slice(&s[..row - split]);
            d[..split].copy_from_slice(&s[row - split..]);
            if bgra {
                for px in d.chunks_exact_mut(4) {
                    px.swap(0, 2);
                }
            }
        }
        // SAFETY: balanced with the lock above.
        check(
            unsafe { CVPixelBufferUnlockBaseAddress(pb, CVPixelBufferLockFlags(0)) },
            "unlock",
        )
    }

    fn stats(mut v: Vec<f64>) -> (f64, f64, f64) {
        if v.is_empty() {
            return (f64::NAN, f64::NAN, f64::NAN);
        }
        v.sort_by(f64::total_cmp);
        let at = |q: f64| v[((v.len() - 1) as f64 * q).round() as usize];
        (at(0.5), at(0.95), at(1.0))
    }

    fn run(dir: &Path, width: usize, height: usize, cfg: Config, dump: bool) -> Res<()> {
        let src = std::fs::read(dir.join(format!("solid_{width}x{height}.rgba")))?;
        if src.len() != width * height * 4 {
            return Err(format!("{width}x{height}: wrong frame size").into());
        }
        let total = WARMUP + FRAMES;
        let collector = Mutex::new(Collector {
            submitted: vec![None; total],
            latency_ms: vec![None; total],
            sizes: Vec::with_capacity(total),
            idr_frames: 0,
            dropped: 0,
            errors: Vec::new(),
            annex_b: dump.then(Vec::new),
            nal_length_size: 0,
        });
        let session = create_session(width, height, cfg, &collector)?;
        // SAFETY: `session` is live.
        let pool =
            unsafe { session.pixel_buffer_pool() }.ok_or("session has no pixel buffer pool")?;

        let (mut fill_ms, mut call_ms) = (Vec::new(), Vec::new());
        let period = Duration::from_secs_f64(1.0 / f64::from(FPS));
        let start = Instant::now();
        for i in 0..total {
            let due = start + period * u32::try_from(i)?;
            if let Some(wait) = due.checked_duration_since(Instant::now()) {
                std::thread::sleep(wait);
            }
            let t0 = Instant::now();
            let mut raw: *mut CVPixelBuffer = ptr::null_mut();
            // SAFETY: `pool` is the session's live pool; `raw` is a valid out-pointer.
            let status = unsafe {
                CVPixelBufferPool::create_pixel_buffer(None, &pool, NonNull::from(&mut raw))
            };
            if status != kCVReturnSuccess {
                return Err(format!("CVPixelBufferPoolCreatePixelBuffer: {status}").into());
            }
            let raw = NonNull::new(raw).ok_or("pool returned a null pixel buffer")?;
            // SAFETY: Create rule: we own this +1 reference.
            let pb = unsafe { CFRetained::<CVPixelBuffer>::from_raw(raw) };
            fill(&pb, &src, width, height, i * SHIFT_PX, !cfg.rgba_input)?;
            let t1 = Instant::now();
            if let Ok(mut c) = collector.lock() {
                c.submitted[i] = Some(t1);
            }
            // SAFETY: plain value constructor.
            let (pts, dur) = unsafe { (CMTime::new(i64::try_from(i)?, FPS), CMTime::new(1, FPS)) };
            // SAFETY: session, pixel buffer, and times are valid; the frame index is carried as
            // an opaque refcon and never dereferenced; info flags may be null.
            let status = unsafe {
                session.encode_frame(&pb, pts, dur, None, i as *mut c_void, ptr::null_mut())
            };
            check(status, "VTCompressionSessionEncodeFrame")?;
            let t2 = Instant::now();
            if i >= WARMUP {
                fill_ms.push((t1 - t0).as_secs_f64() * 1000.0);
                call_ms.push((t2 - t1).as_secs_f64() * 1000.0);
            }
        }
        // SAFETY: a non-numeric (invalid) time flushes all pending frames.
        let status = unsafe { session.complete_frames(CMTime::new(0, 0)) };
        check(status, "CompleteFrames")?;
        // SAFETY: stops callbacks; after this the collector may be dropped.
        unsafe { session.invalidate() };

        let c = collector.into_inner().map_err(|_| "collector poisoned")?;
        if !c.errors.is_empty() {
            return Err(format!("{}: encoder errors {:?}", cfg.name, c.errors).into());
        }
        let latencies: Vec<f64> = c.latency_ms[WARMUP..].iter().flatten().copied().collect();
        let emitted = c.sizes.len();
        let bytes: usize = c.sizes.iter().skip(WARMUP).sum();
        let mbit = bytes as f64 * 8.0 / (FRAMES as f64 / f64::from(FPS)) / 1e6;
        let (lat_med, lat_p95, lat_max) = stats(latencies.clone());
        let (fill_med, fill_p95, _) = stats(fill_ms);
        let (call_med, call_p95, _) = stats(call_ms);
        println!(
            "S2B_ROW {},{width}x{height},{},{lat_med:.2},{lat_p95:.2},{lat_max:.2},{fill_med:.2},{fill_p95:.2},{call_med:.3},{call_p95:.3},{mbit:.2},{},{},{}",
            cfg.name,
            f64::from((cfg.bitrate)(width * height)) / 1e6,
            emitted,
            c.idr_frames,
            c.dropped,
        );
        if latencies.len() != FRAMES {
            return Err(format!(
                "{}: only {} of {FRAMES} timed frames came back",
                cfg.name,
                latencies.len()
            )
            .into());
        }
        if let Some(stream) = c.annex_b {
            let path = dir.join(format!("vt_{}_{width}x{height}.h264", cfg.name));
            std::fs::write(&path, stream)?;
            println!("S2B_STREAM {}", path.display());
        }
        Ok(())
    }

    pub fn main() -> Res<()> {
        let dir = std::env::args()
            .nth(1)
            .ok_or("usage: s2_videotoolbox DIR")?;
        let dir = Path::new(&dir);
        println!(
            "S2B_HEADER config,res,target_mbit,latency_med_ms,latency_p95_ms,latency_max_ms,fill_med_ms,fill_p95_ms,encode_call_med_ms,encode_call_p95_ms,actual_mbit,frames_out,idr_frames,dropped"
        );
        for (width, height) in RESOLUTIONS {
            for (n, cfg) in CONFIGS.into_iter().enumerate() {
                match run(dir, width, height, cfg, n == 0) {
                    Ok(()) => {}
                    // RGBA input is an experiment: report it instead of aborting the run.
                    Err(e) if cfg.rgba_input => {
                        println!("S2B_UNSUPPORTED {},{width}x{height},{e}", cfg.name);
                    }
                    Err(e) => return Err(e),
                }
            }
        }
        Ok(())
    }
}

#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    vt::main()
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("s2_videotoolbox: VideoToolbox is macOS-only");
}
