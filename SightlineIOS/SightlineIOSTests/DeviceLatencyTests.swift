import Darwin
import Foundation
import QuartzCore
import XCTest

/// Motion-to-photon on the device (NFR-LAT-003) and its legs (NFR-LAT-004): the pose ring, the
/// display clock, the meter behind `VIDEO_REPORT.m2p_p95_ms` and the device report.
final class DeviceLatencyTests: XCTestCase {
    private static let ms: UInt64 = 1_000_000

    // MARK: - Pose ring

    func testPoseRingFindsRecentPosesAndForgetsEvictedAndUnknownOnes() {
        var ring = PoseCaptureRing()
        XCTAssertNil(ring.captureTimeNs(of: 1), "nothing recorded yet")
        for seq: UInt32 in 1...300 {
            ring.record(seq: seq, captureTimeNs: UInt64(seq) * 1_000)
        }
        XCTAssertEqual(ring.captureTimeNs(of: 300), 300_000)
        XCTAssertEqual(ring.captureTimeNs(of: 45), 45_000, "the oldest pose still held")
        XCTAssertNil(ring.captureTimeNs(of: 44), "replaced by pose 300 (same slot)")
        XCTAssertNil(ring.captureTimeNs(of: 1))
        XCTAssertNil(ring.captureTimeNs(of: 301), "never recorded")
        XCTAssertNil(ring.captureTimeNs(of: 556), "same slot as 300, different pose")
        XCTAssertNil(ring.captureTimeNs(of: 0), "pose_seq 0 means no pose")
    }

    func testPoseRingKeepsOrderAcrossTheU32Wrap() {
        var ring = PoseCaptureRing()
        var seq = UInt32.max - 9
        for i: UInt64 in 0..<20 {
            ring.record(seq: seq, captureTimeNs: 5_000 + i)
            seq &+= 1
        }
        XCTAssertEqual(ring.captureTimeNs(of: UInt32.max - 9), 5_000)
        XCTAssertEqual(ring.captureTimeNs(of: UInt32.max), 5_009)
        XCTAssertNil(ring.captureTimeNs(of: 0), "seq 0 after the wrap isn't stored")
        XCTAssertEqual(ring.captureTimeNs(of: 1), 5_011)
        XCTAssertEqual(ring.captureTimeNs(of: 9), 5_019)
    }

    /// Fixed inline storage: the ring and a histogram are plain values of a known size, with no
    /// array, dictionary or other reference inside that could grow.
    func testRingAndHistogramStorageIsInline() {
        XCTAssertEqual(MemoryLayout<PoseCaptureRing>.size, PoseCaptureRing.capacity * (4 + 8))
        XCTAssertGreaterThanOrEqual(MemoryLayout<LatencyHistogram>.size, LatencyHistogram.binCount * 4)
        XCTAssertTrue(_isPOD(PoseCaptureRing.self), "no references in the ring")
        XCTAssertTrue(_isPOD(DeviceLatencyMeter.self), "no references in the meter")
    }

    /// Recording poses and frames is on the tracking queue for every pose and frame, so it must
    /// not allocate. Checked on optimised code, like the send path (CI runs it in Release).
    func testRecordingPosesAndFramesAllocatesNothing() throws {
        #if DEBUG
        throw XCTSkip("allocation-free only when optimised: run with -configuration Release")
        #else
        var ring = PoseCaptureRing()
        var meter = DeviceLatencyMeter()
        var reported: UInt16 = 0
        let allocations = heapAllocations {
            for seq: UInt32 in 1...1_000 {
                ring.record(seq: seq, captureTimeNs: UInt64(seq) * 16 * Self.ms)
                meter.frameReceived(firstFragmentNs: UInt64(seq), completeNs: UInt64(seq) + Self.ms)
                let frame = PresentedFrame(
                    poseSeq: seq, submittedNs: UInt64(seq) * 16 * Self.ms, decodedNs: UInt64(seq) * 17 * Self.ms,
                    presentedNs: UInt64(seq) * 18 * Self.ms)
                meter.framePresented(frame, captureTimeNs: ring.captureTimeNs(of: seq))
                if seq % 15 == 0 { reported = meter.nextReportM2PMs() }
            }
        }
        XCTAssertEqual(allocations, 0, "heap allocations over 1000 poses and frames")
        XCTAssertGreaterThan(reported, 0)
        print("VCAM_M2P_ALLOCATIONS frames=1000 allocations=\(allocations)")
        #endif
    }

    // MARK: - Display clock

    /// The Metal display time is `CACurrentMediaTime()` seconds; the capture clock is
    /// CLOCK_UPTIME_RAW nanoseconds. Read between two uptime readings, the converted media time
    /// lands between them: same base, no offset.
    func testMediaTimeIsTheCaptureClockInSeconds() throws {
        for _ in 0..<100 {
            let before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let media = CACurrentMediaTime()
            let after = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let converted = try XCTUnwrap(DisplayClock.uptimeNs(mediaTime: media))
            // A double holds uptime seconds to well under a microsecond.
            XCTAssertGreaterThanOrEqual(converted + 1_000, before)
            XCTAssertLessThanOrEqual(converted, after + 1_000)
        }
    }

    func testDisplayTimeConversionAndNotPresentedFrames() {
        XCTAssertEqual(DisplayClock.uptimeNs(mediaTime: 10.085), 10_085_000_000)
        XCTAssertEqual(DisplayClock.uptimeNs(mediaTime: 0.000_000_001), 1)
        XCTAssertNil(DisplayClock.uptimeNs(mediaTime: 0), "Metal's 0: not presented")
        XCTAssertNil(DisplayClock.uptimeNs(mediaTime: -1))
        XCTAssertNil(DisplayClock.uptimeNs(mediaTime: .nan))
        XCTAssertNil(DisplayClock.uptimeNs(mediaTime: .infinity))

        // ARFrame.timestamp 10.0 s becomes captureTimeNs as the pipeline stores it; shown at
        // 10.085 s (presentedTime), that is 85 ms motion-to-photon.
        let capture = UInt64((10.0 * 1e9).rounded())
        let frame = PresentedFrame(poseSeq: 1, submittedNs: 10_050_000_000, decodedNs: 10_060_000_000)
        var meter = DeviceLatencyMeter()
        meter.framePresented(frame.presented(atMediaTime: 10.085), captureTimeNs: capture)
        XCTAssertEqual(meter.m2p.max, 85 * Self.ms)
        XCTAssertEqual(meter.display.max, 25 * Self.ms)
        XCTAssertEqual(meter.decode.max, 10 * Self.ms)
        XCTAssertEqual(meter.nextReportM2PMs(), 85)

        meter.framePresented(frame.presented(atMediaTime: 0), captureTimeNs: capture)
        XCTAssertEqual(meter.m2p.count, 1, "a frame that wasn't presented is no M2P sample")
        XCTAssertEqual(meter.display.count, 1)
        XCTAssertEqual(meter.decode.count, 2, "it was decoded, though")
        XCTAssertEqual(meter.framesNotPresented, 1)
        XCTAssertEqual(meter.nextReportM2PMs(), 0, "nothing shown in the interval: not measured")
    }

    // MARK: - VIDEO_REPORT value

    func testReportMillisecondsRoundUpAndSaturate() {
        XCTAssertEqual(DisplayClock.reportMilliseconds(nil), 0, "not measured")
        XCTAssertEqual(DisplayClock.reportMilliseconds(0), 1, "measured is never 0")
        XCTAssertEqual(DisplayClock.reportMilliseconds(1), 1)
        XCTAssertEqual(DisplayClock.reportMilliseconds(85 * Self.ms), 85)
        XCTAssertEqual(DisplayClock.reportMilliseconds(85 * Self.ms + 1), 86)
        XCTAssertEqual(DisplayClock.reportMilliseconds(65_534 * Self.ms + 1), 65_535)
        XCTAssertEqual(DisplayClock.reportMilliseconds(65_535 * Self.ms), 65_535)
        XCTAssertEqual(DisplayClock.reportMilliseconds(70_000 * Self.ms), 65_535, "65535 = at least")
        XCTAssertEqual(DisplayClock.reportMilliseconds(UInt64.max), 65_535)
    }

    // MARK: - Meter

    private func shown(
        _ seq: UInt32, capture: UInt64, m2pMS: UInt64, decodeMS: UInt64 = 4, displayMS: UInt64 = 8
    )
        -> (PresentedFrame, UInt64)
    {
        let presented = capture + m2pMS * Self.ms
        let decoded = presented - displayMS * Self.ms
        let frame = PresentedFrame(
            poseSeq: seq, submittedNs: decoded - decodeMS * Self.ms, decodedNs: decoded, presentedNs: presented)
        return (frame, capture)
    }

    /// Each leg has p50/p95/p99 over the session; the report's p95 is over the frames shown since
    /// the previous report, and the next interval starts empty.
    func testMeterLegsAndReportIntervals() throws {
        var meter = DeviceLatencyMeter()
        XCTAssertEqual(meter.summary, DeviceLatencySummary(), "nothing measured")
        XCTAssertEqual(meter.nextReportM2PMs(), 0)

        for i in 0..<20 {
            // 0.05 … 1.95 ms: one sample in each of the first 20 bins of 0.1 ms.
            meter.frameReceived(firstFragmentNs: 1_000, completeNs: 1_000 + UInt64(i + 1) * 100_000 - 50_000)
            let (frame, capture) = shown(UInt32(i + 1), capture: 5_000 * Self.ms, m2pMS: 60 + UInt64(i))
            meter.framePresented(frame, captureTimeNs: capture)
        }
        let summary = meter.summary
        XCTAssertEqual(
            summary.receive, LatencySummary(count: 20, p50: 1_000_000, p95: 1_900_000, p99: 1_950_000, max: 1_950_000))
        XCTAssertEqual(
            summary.decode,
            LatencySummary(count: 20, p50: 4 * Self.ms, p95: 4 * Self.ms, p99: 4 * Self.ms, max: 4 * Self.ms))
        XCTAssertEqual(summary.display?.p95, 8 * Self.ms)
        XCTAssertEqual(
            summary.m2p,
            LatencySummary(count: 20, p50: 70 * Self.ms, p95: 79 * Self.ms, p99: 79 * Self.ms, max: 79 * Self.ms))
        XCTAssertEqual(summary.reportedM2PMs, 0, "no report taken yet")

        XCTAssertEqual(meter.nextReportM2PMs(), 79)
        XCTAssertEqual(meter.summary.reportedM2PMs, 79)
        let (fast, capture) = shown(21, capture: 9_000 * Self.ms, m2pMS: 40)
        meter.framePresented(fast, captureTimeNs: capture)
        XCTAssertEqual(meter.nextReportM2PMs(), 40, "only the new interval's frames")
        XCTAssertEqual(meter.summary.m2p?.count, 21, "the session's legs keep every frame")
        XCTAssertEqual(meter.nextReportM2PMs(), 0)
    }

    func testFramesWithoutACaptureTimeOrOutOfOrderGiveNoM2P() {
        var meter = DeviceLatencyMeter()
        let (frame, capture) = shown(3, capture: 5_000 * Self.ms, m2pMS: 50)
        meter.framePresented(frame, captureTimeNs: nil)
        XCTAssertEqual(meter.framesWithoutCaptureTime, 1)
        XCTAssertEqual(meter.m2p.count, 0)
        XCTAssertEqual(meter.display.count, 1, "the display leg doesn't need the pose")

        // Shown "before" its pose was captured: another run's frame or a clock error.
        meter.framePresented(frame, captureTimeNs: capture + 51 * Self.ms)
        XCTAssertEqual(meter.m2p.count, 0)
        var backwards = frame
        backwards.decodedNs = frame.submittedNs - 1
        backwards.presentedNs = backwards.decodedNs - 1
        meter.framePresented(backwards, captureTimeNs: nil)
        XCTAssertEqual(meter.decode.count, 2, "no sample from a backwards decode")
        XCTAssertEqual(meter.display.count, 2)
        XCTAssertEqual(meter.framesWithoutCaptureTime, 2)
        meter.frameReceived(firstFragmentNs: 10, completeNs: 9)
        XCTAssertEqual(meter.receive.count, 0)
        XCTAssertEqual(meter.nextReportM2PMs(), 0)
    }

    func testSaturatedM2PReportsAtLeast65535() {
        var meter = DeviceLatencyMeter()
        let (frame, capture) = shown(1, capture: Self.ms, m2pMS: 70_000)
        meter.framePresented(frame, captureTimeNs: capture)
        XCTAssertEqual(meter.m2p.max, 70_000 * Self.ms)
        XCTAssertEqual(meter.nextReportM2PMs(), 65_535)
        XCTAssertEqual(HUDFields.m2p(meter.summary), "≥ 65535 ms")
    }

    func testHistogramPercentilesUseBinEdgesCappedAtTheMaximum() {
        var histogram = LatencyHistogram(binWidthNs: 1_000)
        XCTAssertNil(histogram.summary)
        XCTAssertNil(histogram.percentile(50))
        for i: UInt64 in 0..<100 {
            histogram.add(i * 1_000 + 500)
        }
        XCTAssertEqual(
            histogram.summary, LatencySummary(count: 100, p50: 50_000, p95: 95_000, p99: 99_000, max: 99_500))
        histogram.add(10_000_000)  // past the last bin
        XCTAssertEqual(histogram.percentile(100), 10_000_000)
        XCTAssertEqual(histogram.count, 101)
    }

    // MARK: - Device report

    private func summary() -> DeviceLatencySummary {
        var meter = DeviceLatencyMeter()
        meter.frameReceived(firstFragmentNs: 0, completeNs: Self.ms)
        let (frame, capture) = shown(1, capture: 5_000 * Self.ms, m2pMS: 90)
        meter.framePresented(frame, captureTimeNs: capture)
        _ = meter.nextReportM2PMs()
        return meter.summary
    }

    func testReportHasEveryLegWithPercentilesAndTheMethods() throws {
        let data = try DeviceLatencyReport.data(
            summary(), sessionID: 7, environment: "simulator", date: Date(timeIntervalSince1970: 0))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "vcam-latency-device")
        XCTAssertEqual(json["format"] as? Int, 1)
        XCTAssertEqual(json["environment"] as? String, "simulator")
        XCTAssertEqual(json["date"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(json["session_id"] as? Int, 7)
        XCTAssertEqual(json["last_report_m2p_p95_ms"] as? Int, 90)
        let legs = try XCTUnwrap(json["legs"] as? [String: [String: Any]])
        XCTAssertEqual(Set(legs.keys), ["receive_ms", "decode_ms", "display_ms", "m2p_ms"])
        for (name, leg) in legs {
            for key in ["p50", "p95", "p99", "max"] {
                XCTAssertNotNil(leg[key] as? Double, "\(name).\(key)")
            }
            XCTAssertEqual(leg["count"] as? Int, 1, name)
        }
        XCTAssertEqual(legs["m2p_ms"]?["p95"] as? Double, 90)
        XCTAssertEqual(legs["receive_ms"]?["p95"] as? Double, 1)
        let methods = try XCTUnwrap(json["methods"] as? [String: String])
        for key in ["clock", "display_time", "receive_ms", "decode_ms", "display_ms", "m2p_ms"] {
            XCTAssertFalse(methods[key, default: ""].isEmpty, key)
        }
        XCTAssertEqual(DeviceLatencyReport.environment, "simulator")
        XCTAssertTrue(methods["display_time"]?.contains("GPUEndTime") == true, "the simulator's display time")

        let empty = DeviceLatencyReport.object(
            DeviceLatencySummary(), sessionID: nil, environment: "device", date: .now)
        XCTAssertTrue(empty["session_id"] is NSNull)
        XCTAssertTrue((empty["legs"] as? [String: Any])?["m2p_ms"] is NSNull, "a leg not measured is null")
    }

    @MainActor
    func testReportWriterWritesOnceAFrameWasShownAtMostEveryTwoSecondsAndOnFlush() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "latency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = DeviceLatencyReportWriter(directory: directory)
        let url = try XCTUnwrap(writer.url)
        func written() throws -> Int? {
            writer.waitForWrites()
            guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return json["session_id"] as? Int
        }
        let start = ContinuousClock.now
        writer.update(DeviceLatencySummary(), sessionID: 1, now: start)
        XCTAssertNil(try written(), "no frame shown yet: no report")
        writer.update(summary(), sessionID: 1, now: start)
        XCTAssertEqual(try written(), 1)
        writer.update(summary(), sessionID: 2, now: start + .seconds(1))
        XCTAssertEqual(try written(), 1, "within two seconds of the last write")
        writer.update(summary(), sessionID: 3, now: start + .seconds(2))
        XCTAssertEqual(try written(), 3)
        writer.update(summary(), sessionID: 4, now: start + .seconds(3))
        writer.flush(now: start + .seconds(3))
        XCTAssertEqual(try written(), 4, "a stop writes the newest at once")
    }

    @MainActor
    func testReportWriterReportsAFailedWrite() {
        let failures = Failures()
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let writer = DeviceLatencyReportWriter(directory: missing) { failures.add($0) }
        writer.update(summary(), sessionID: 1)
        writer.waitForWrites()
        XCTAssertEqual(failures.count, 1)
    }

    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        func add(_ message: String) { lock.withLock { messages.append(message) } }
        var count: Int { lock.withLock { messages.count } }
    }
}
