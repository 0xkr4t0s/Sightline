import Foundation

// Motion-to-photon on the device (NFR-LAT-003) and the device legs of the latency harness
// (NFR-LAT-004). Every time here is nanoseconds on CLOCK_UPTIME_RAW, the clock of ARKit capture
// times (see `DisplayClock`). Recording a sample never touches the heap: the pose ring and the
// histograms are fixed-size inline storage inside the tracking pipeline's actor.

/// Percentiles of one latency leg, in nanoseconds.
nonisolated struct LatencySummary: Equatable, Sendable {
    var count: Int
    var p50: UInt64
    var p95: UInt64
    var p99: UInt64
    var max: UInt64
}

/// A latency histogram with `binCount` fixed bins of `binWidthNs` plus an overflow count. Like
/// `SendLegMeter`, percentiles are nearest-rank and report the upper edge of their bin, capped at
/// the largest sample, so they never understate; one in the overflow is the largest sample.
nonisolated struct LatencyHistogram: Sendable {
    static let binCount = 1024

    let binWidthNs: UInt64
    private var bins = InlineArray<1024, UInt32>(repeating: 0)
    private(set) var count = 0
    private(set) var max: UInt64 = 0

    init(binWidthNs: UInt64) {
        precondition(binWidthNs > 0, "bin width must be positive")
        self.binWidthNs = binWidthNs
    }

    mutating func add(_ ns: UInt64) {
        let bin = ns / binWidthNs
        if bin < UInt64(Self.binCount) {
            bins[Int(bin)] &+= 1
        }
        count += 1
        max = Swift.max(max, ns)
    }

    /// The smallest bin edge with at least `percent` % of the samples at or below it; nil if empty.
    func percentile(_ percent: Int) -> UInt64? {
        guard count > 0 else { return nil }
        let rank = (count * percent + 99) / 100
        var seen = 0
        for i in bins.indices {
            seen += Int(bins[i])
            if seen >= rank {
                return Swift.min(UInt64(i + 1) * binWidthNs, max)
            }
        }
        return max
    }

    var summary: LatencySummary? {
        guard count > 0, let p50 = percentile(50), let p95 = percentile(95), let p99 = percentile(99) else {
            return nil
        }
        return LatencySummary(count: count, p50: p50, p95: p95, p99: p99, max: max)
    }
}

/// `POSE.seq` → capture time for the newest `capacity` poses of a run (ARC-004), so a viewfinder
/// frame's `pose_seq` finds when its pose was captured. Slot `seq % capacity` holds the seq it was
/// written for; 2³² is a multiple of `capacity`, so the slots stay in order across the u32 wrap.
/// Seq 0 means "no pose" in `VIDEO_FRAGMENT` and is never stored.
nonisolated struct PoseCaptureRing: Sendable {
    /// 4.3 s of poses at 60 Hz: far more than a frame can take and still be shown.
    static let capacity = 256

    private var seqs = InlineArray<256, UInt32>(repeating: 0)
    private var times = InlineArray<256, UInt64>(repeating: 0)

    mutating func record(seq: UInt32, captureTimeNs: UInt64) {
        guard seq != 0 else { return }
        let slot = Int(seq % UInt32(Self.capacity))
        seqs[slot] = seq
        times[slot] = captureTimeNs
    }

    /// Nil for seq 0, a seq never recorded, or one a newer pose has since replaced.
    func captureTimeNs(of seq: UInt32) -> UInt64? {
        guard seq != 0 else { return nil }
        let slot = Int(seq % UInt32(Self.capacity))
        return seqs[slot] == seq ? times[slot] : nil
    }
}

/// Converts Metal's display time to the capture clock.
///
/// `MTLDrawable.presentedTime` is a `CFTimeInterval` in seconds on the `CACurrentMediaTime()`
/// base: `mach_absolute_time()` in seconds. `ARFrame.timestamp` uses the same base (the scripted
/// QA poses use CLOCK_UPTIME_RAW, which is `mach_absolute_time()` in nanoseconds), and the pipeline
/// stores it as `captureTimeNs = timestamp × 10⁹`. So both are on one clock and the conversion is
/// only a change of unit: `presented_ns = round(presentedTime × 10⁹)`, with no offset, and
/// M2P = presented_ns − captureTimeNs. Metal reports 0 for a drawable that was never presented;
/// that gives no time.
///
/// The simulator SDK's `MTLDrawable` has neither `addPresentedHandler` nor `presentedTime`, so
/// there the display time is the frame's command buffer `GPUEndTime` (same base), which leaves out
/// the wait for the next refresh: simulator M2P is a lower bound of what a display would show.
nonisolated enum DisplayClock {
    /// What the display time is, for the report.
    static var source: String {
        #if targetEnvironment(simulator)
        "MTLCommandBuffer.GPUEndTime (the simulator SDK has no MTLDrawable.presentedTime; "
            + "excludes the wait for the next display refresh)"
        #else
        "MTLDrawable.presentedTime"
        #endif
    }

    static func uptimeNs(mediaTime seconds: Double) -> UInt64? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        return UInt64((seconds * 1e9).rounded())
    }

    /// `VIDEO_REPORT.m2p_p95_ms` (vcp.md §6.6): 0 = not measured, else whole milliseconds rounded
    /// up (so a measured value is never 0), 65535 for 65535 ms or more.
    static func reportMilliseconds(_ ns: UInt64?) -> UInt16 {
        guard let ns else { return 0 }
        let ms = ns / 1_000_000 + (ns % 1_000_000 == 0 ? 0 : 1)
        return UInt16(clamping: Swift.max(ms, 1))
    }
}

/// One viewfinder frame on its way to the screen, with the device times of its steps.
nonisolated struct PresentedFrame: Equatable, Sendable {
    /// The pose Blender rendered the frame from (`VIDEO_FRAGMENT.pose_seq`; 0 = none).
    var poseSeq: UInt32
    /// The pipeline handed the completed frame to the decoder.
    var submittedNs: UInt64
    /// The decoded texture was ready to draw.
    var decodedNs: UInt64
    /// On screen (`DisplayClock`); nil when Metal says the drawable wasn't presented.
    var presentedNs: UInt64?

    /// This frame with its display time from Metal (seconds, `CACurrentMediaTime` base; 0 = not
    /// presented).
    func presented(atMediaTime seconds: Double) -> PresentedFrame {
        var frame = self
        frame.presentedNs = DisplayClock.uptimeNs(mediaTime: seconds)
        return frame
    }
}

/// What the HUD, Settings and the device report show of the device's latency.
nonisolated struct DeviceLatencySummary: Equatable, Sendable {
    /// The value the latest `VIDEO_REPORT` carried (0 = not measured in its interval).
    var reportedM2PMs: UInt16 = 0
    /// First fragment of a frame → the frame complete (reassembly).
    var receive: LatencySummary?
    /// Frame complete → decoded texture.
    var decode: LatencySummary?
    /// Decoded texture → on screen.
    var display: LatencySummary?
    /// Pose capture → on screen (NFR-LAT-003).
    var m2p: LatencySummary?
    var framesNotPresented = 0
    /// Shown, but its `pose_seq` wasn't in the ring (0, or older than its capacity).
    var framesWithoutCaptureTime = 0
}

/// The device legs of one session (NFR-LAT-004) and motion-to-photon (NFR-LAT-003). The legs cover
/// the whole session; `nextReportM2PMs` gives the p95 over the frames shown since the previous
/// `VIDEO_REPORT`, as vcp.md §6.6 defines `m2p_p95_ms`, and starts the next interval.
nonisolated struct DeviceLatencyMeter: Sendable {
    /// Legs in 0.1 ms bins up to 102.4 ms; M2P in 1 ms bins up to 1024 ms.
    static let legBinNs: UInt64 = 100_000
    static let m2pBinNs: UInt64 = 1_000_000

    private(set) var receive = LatencyHistogram(binWidthNs: legBinNs)
    private(set) var decode = LatencyHistogram(binWidthNs: legBinNs)
    private(set) var display = LatencyHistogram(binWidthNs: legBinNs)
    private(set) var m2p = LatencyHistogram(binWidthNs: m2pBinNs)
    private var m2pInterval = LatencyHistogram(binWidthNs: m2pBinNs)
    private(set) var reportedM2PMs: UInt16 = 0
    private(set) var framesNotPresented = 0
    private(set) var framesWithoutCaptureTime = 0

    mutating func frameReceived(firstFragmentNs: UInt64, completeNs: UInt64) {
        guard completeNs >= firstFragmentNs else { return }
        receive.add(completeNs - firstFragmentNs)
    }

    /// Times out of order (a clock that went backwards) give no sample for that leg.
    mutating func framePresented(_ frame: PresentedFrame, captureTimeNs: UInt64?) {
        if frame.decodedNs >= frame.submittedNs {
            decode.add(frame.decodedNs - frame.submittedNs)
        }
        guard let presented = frame.presentedNs else {
            framesNotPresented += 1
            return
        }
        if presented >= frame.decodedNs {
            display.add(presented - frame.decodedNs)
        }
        guard let captureTimeNs else {
            framesWithoutCaptureTime += 1
            return
        }
        guard presented >= captureTimeNs else { return }
        m2p.add(presented - captureTimeNs)
        m2pInterval.add(presented - captureTimeNs)
    }

    /// The report's `m2p_p95_ms`; the next interval starts empty.
    mutating func nextReportM2PMs() -> UInt16 {
        reportedM2PMs = DisplayClock.reportMilliseconds(m2pInterval.percentile(95))
        m2pInterval = LatencyHistogram(binWidthNs: Self.m2pBinNs)
        return reportedM2PMs
    }

    var summary: DeviceLatencySummary {
        DeviceLatencySummary(
            reportedM2PMs: reportedM2PMs, receive: receive.summary, decode: decode.summary,
            display: display.summary, m2p: m2p.summary, framesNotPresented: framesNotPresented,
            framesWithoutCaptureTime: framesWithoutCaptureTime)
    }
}

/// The device half of the NFR-LAT-004 report, written as JSON into the app's Documents folder
/// (`tools/mission/qa_ios.sh latency` copies it out of the simulator).
nonisolated enum DeviceLatencyReport {
    static let fileName = "latency-device.json"
    static let kind = "vcam-latency-device"
    static let format = 1

    /// How each leg is measured, carried in the report so a reader needn't find this file.
    static let methods: [String: String] = [
        "clock": "CLOCK_UPTIME_RAW (mach_absolute_time) in ns; ARFrame.timestamp and the Metal "
            + "display time (CACurrentMediaTime base) are seconds on the same clock, converted by "
            + "x 1e9 with no offset",
        "display_time": DisplayClock.source,
        "receive_ms": "tracking queue: first VIDEO_FRAGMENT of a frame read -> its last fragment read "
            + "(reassembly; the network transit before the first fragment needs the host clock)",
        "decode_ms": "complete frame handed to the decoder -> ImageIO JPEG decode into the Metal "
            + "texture done (includes the wait behind a decode in progress)",
        "display_ms": "texture ready -> display time of the first drawable showing it",
        "m2p_ms": "display time - capture time of the frame's pose_seq (pose ring on the tracking "
            + "queue); frames not presented or without a capture time give no sample",
        "m2p_p95_ms_report": "VIDEO_REPORT: p95 over the frames shown since the previous report, "
            + "ms rounded up, 0 = none shown, 65535 = saturated",
    ]

    /// Milliseconds with microsecond precision.
    private static func ms(_ ns: UInt64) -> Double {
        (Double(ns) / 1_000).rounded() / 1_000
    }

    private static func leg(_ summary: LatencySummary?) -> Any {
        guard let summary else { return NSNull() }
        return [
            "count": summary.count, "p50": ms(summary.p50), "p95": ms(summary.p95),
            "p99": ms(summary.p99), "max": ms(summary.max),
        ] as [String: Any]
    }

    /// The report as a JSON object; no device name or other identifying data.
    static func object(
        _ summary: DeviceLatencySummary, sessionID: UInt32?, environment: String, date: Date
    ) -> [String: Any] {
        [
            "kind": kind,
            "format": format,
            "environment": environment,
            "date": date.formatted(.iso8601),
            "session_id": sessionID.map { Int($0) as Any } ?? NSNull(),
            "frames_not_presented": summary.framesNotPresented,
            "frames_without_capture_time": summary.framesWithoutCaptureTime,
            "last_report_m2p_p95_ms": Int(summary.reportedM2PMs),
            "legs": [
                "receive_ms": leg(summary.receive),
                "decode_ms": leg(summary.decode),
                "display_ms": leg(summary.display),
                "m2p_ms": leg(summary.m2p),
            ] as [String: Any],
            "methods": methods,
        ]
    }

    static func data(
        _ summary: DeviceLatencySummary, sessionID: UInt32?, environment: String, date: Date
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object(summary, sessionID: sessionID, environment: environment, date: date),
            options: [.prettyPrinted, .sortedKeys])
    }

    /// "simulator" in the Simulator; M2P there says nothing about a real iPhone's display.
    static var environment: String {
        #if targetEnvironment(simulator)
        "simulator"
        #else
        "device"
        #endif
    }
}

/// Writes the device report at most every `interval` while a session measures, and at once when
/// asked to flush (a run stopped), on a utility queue so neither the UI nor tracking waits for it.
@MainActor
final class DeviceLatencyReportWriter {
    static let interval: Duration = .seconds(2)

    let url: URL?
    private let queue = DispatchQueue(label: "Sightline.LatencyReport", qos: .utility)
    private let onError: @Sendable (String) -> Void
    private var lastWrite: ContinuousClock.Instant?
    private var pending: (summary: DeviceLatencySummary, sessionID: UInt32?)?

    /// `onError` hears a failed write, on the writer's queue.
    init(
        directory: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
        onError: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        url = directory?.appending(path: DeviceLatencyReport.fileName)
        self.onError = onError
    }

    /// Keeps the newest summary; nothing is written before a frame was shown.
    func update(_ summary: DeviceLatencySummary, sessionID: UInt32?, now: ContinuousClock.Instant = .now) {
        guard summary.m2p != nil || summary.display != nil else { return }
        pending = (summary, sessionID)
        if let lastWrite, now - lastWrite < Self.interval { return }
        write(now: now)
    }

    func flush(now: ContinuousClock.Instant = .now) {
        write(now: now)
    }

    private func write(now: ContinuousClock.Instant) {
        guard let url, let pending else { return }
        self.pending = nil
        lastWrite = now
        let date = Date()
        let onError = onError
        queue.async {
            do {
                let data = try DeviceLatencyReport.data(
                    pending.summary, sessionID: pending.sessionID, environment: DeviceLatencyReport.environment,
                    date: date)
                try data.write(to: url, options: .atomic)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    /// Blocks until queued writes are done (tests).
    func waitForWrites() {
        queue.sync {}
    }
}
