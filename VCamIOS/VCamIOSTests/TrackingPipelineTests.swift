import Foundation
import simd
import XCTest

/// ARC-005: the per-frame path runs off the main thread and the UI hears from it at most 15 times
/// a second.
final class TrackingPipelineTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(TrackingSnapshot, Bool)] = []

        func add(_ snapshot: TrackingSnapshot) {
            lock.withLock { items.append((snapshot, Thread.isMainThread)) }
        }

        var snapshots: [TrackingSnapshot] { lock.withLock { items.map(\.0) } }
        var anyOnMain: Bool { lock.withLock { items.contains { $0.1 } } }
    }

    private func translation(_ x: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(x, 0, 0, 1)
        return m
    }

    /// Delivers frames the way ARKit does: asynchronously on the pipeline's queue (the session's
    /// delegate queue), then waits for them. (A `sync` from the test would run on the main thread.)
    private func feed(_ pipeline: TrackingPipeline, frames: Range<Int>, rate: Double, jitter: (Int) -> Double = { _ in 0 }) {
        for i in frames {
            let transform = translation(Float(i))
            let timestamp = 100 + Double(i) / rate + jitter(i)
            pipeline.queue.async { pipeline.receive(transform: transform, timestamp: timestamp) }
        }
        pipeline.queue.sync {}
    }

    func testSixtyHertzFramesReachTheUIAtFifteenHertzOffTheMainThread() {
        let recorder = Recorder()
        let pipeline = TrackingPipeline(publish: recorder.add)
        pipeline.start(host: "127.0.0.1", port: 9)
        feed(pipeline, frames: 0..<600, rate: 60)  // 10 s of ARKit frames
        pipeline.stop()

        let snapshots = recorder.snapshots
        XCTAssertEqual(snapshots.count, 150)
        XCTAssertFalse(recorder.anyOnMain)
        // Each snapshot carries the newest pose: every 4th frame.
        XCTAssertEqual(snapshots.map { Int($0.pose.x) }, Array(stride(from: 0, to: 600, by: 4)))
    }

    func testJitteredFramesNeverExceedFifteenHertz() {
        let recorder = Recorder()
        let pipeline = TrackingPipeline(publish: recorder.add)
        pipeline.start(host: "127.0.0.1", port: 9)
        var rng = SystemRandomNumberGenerator()
        let jitter = (0..<1200).map { _ in Double.random(in: -0.004...0.004, using: &rng) }
        feed(pipeline, frames: 0..<1200, rate: 60) { jitter[$0] }  // 20 s, ±4 ms per frame
        pipeline.stop()

        let times = recorder.snapshots.map(\.pose.timestamp)
        XCTAssertLessThanOrEqual(times.count, 301)  // 15 Hz over 20 s, plus the first slot
        XCTAssertGreaterThanOrEqual(times.count, 280)  // and not starved by jitter
        // No 1-second window holds more than 15 publishes (+1 for the tolerance at the edge).
        for (i, t) in times.enumerated() {
            XCTAssertLessThanOrEqual(times[i...].prefix { $0 < t + 1 }.count, 16, "window at \(t)")
        }
    }

    func testFramesAfterStopAreDroppedAndStartRestartsTheCadence() {
        let recorder = Recorder()
        let pipeline = TrackingPipeline(publish: recorder.add)
        feed(pipeline, frames: 0..<10, rate: 60)  // not started
        XCTAssertEqual(recorder.snapshots.count, 0)

        pipeline.start(host: "127.0.0.1", port: 9)
        feed(pipeline, frames: 0..<8, rate: 60)
        pipeline.stop()
        feed(pipeline, frames: 8..<60, rate: 60)
        XCTAssertEqual(recorder.snapshots.count, 2)

        // A new AR session starts its clock elsewhere; the first frame shows at once.
        pipeline.start(host: "127.0.0.1", port: 9)
        pipeline.queue.sync { pipeline.receive(transform: translation(7), timestamp: 3) }
        XCTAssertEqual(recorder.snapshots.count, 3)
        XCTAssertEqual(recorder.snapshots.last?.pose.x, 7)
        XCTAssertEqual(recorder.snapshots.last?.packetsSent, 0)
        pipeline.stop()
    }
}
