import ARKit
import Darwin
import Foundation
import simd
import XCTest

/// The device send path (tasks 1.4.1, 1.4.2): ARKit frames become VCP `POSE` datagrams off the main
/// thread (ARC-005, FR-TRK-001/002, PR-FD-001), and the UI hears about them at most 15 times a
/// second.
final class TrackingPipelineTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(TrackingSnapshot, Bool)] = []

        func add(_ snapshot: TrackingSnapshot) {
            lock.withLock { items.append((snapshot, Thread.isMainThread)) }
        }

        var snapshots: [TrackingSnapshot] { lock.withLock { items.map(\.0) } }
        var poses: [VCPPose] { snapshots.compactMap(\.pose) }
        var anyOnMain: Bool { lock.withLock { items.contains { $0.1 } } }
    }

    /// A UDP socket on 127.0.0.1 that plays the host.
    private final class LoopbackReceiver {
        let fd: Int32
        let port: UInt16

        init() throws {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { throw POSIXError(.EBADF) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
                }
            }
            guard bound else {
                close(fd)
                throw POSIXError(.EADDRNOTAVAIL)
            }
            self.fd = fd
            port = UInt16(bigEndian: addr.sin_port)
        }

        deinit { close(fd) }

        /// The next datagram, or nil after `timeout` seconds.
        func receive(timeout: Double) -> [UInt8]? {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1e6))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 2048)
            let n = recv(fd, &buffer, buffer.count, 0)
            return n > 0 ? Array(buffer[..<n]) : nil
        }
    }

    private func load(_ path: String) throws -> [String: Any] {
        let root = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "testdata", withExtension: nil))
        let data = try Data(contentsOf: root.appending(path: path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i..<s.index(i, offsetBy: 2)], radix: 16)!
        }
    }

    private func translation(_ x: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(x, 0, 0, 1)
        return m
    }

    private let unpaired = TrackingDestination(host: "127.0.0.1", port: 9, endpoint: nil)

    /// Delivers frames the way ARKit does: asynchronously on the pipeline's queue (the session's
    /// delegate queue), then waits for them. (A `sync` from the test would run on the main thread.)
    private func feed(_ pipeline: TrackingPipeline, frames: Range<Int>, rate: Double,
                      state: UInt8 = VCPTrackingState.normal, jitter: (Int) -> Double = { _ in 0 }) {
        for i in frames {
            let transform = translation(Float(i))
            let timestamp = 100 + Double(i) / rate + jitter(i)
            pipeline.queue.async { pipeline.receive(transform: transform, timestamp: timestamp, trackingState: state) }
        }
        pipeline.queue.sync {}
    }

    func testSixtyHertzFramesReachTheUIAtFifteenHertzOffTheMainThread() {
        let recorder = Recorder()
        let pipeline = TrackingPipeline(publish: recorder.add)
        pipeline.start(unpaired)
        feed(pipeline, frames: 0..<600, rate: 60)  // 10 s of ARKit frames
        pipeline.stop()

        XCTAssertEqual(recorder.snapshots.count, 150)
        XCTAssertFalse(recorder.anyOnMain)
        // Each snapshot carries the newest pose: every 4th frame (ARKit x is canonical x).
        XCTAssertEqual(recorder.poses.map { Int($0.position.x) }, Array(stride(from: 0, to: 600, by: 4)))
    }

    func testJitteredFramesNeverExceedFifteenHertz() {
        let recorder = Recorder()
        let pipeline = TrackingPipeline(publish: recorder.add)
        pipeline.start(unpaired)
        var rng = SystemRandomNumberGenerator()
        let jitter = (0..<1200).map { _ in Double.random(in: -0.004...0.004, using: &rng) }
        feed(pipeline, frames: 0..<1200, rate: 60) { jitter[$0] }  // 20 s, ±4 ms per frame
        pipeline.stop()

        let times = recorder.poses.map { Double($0.captureTimeNs) / 1e9 }
        XCTAssertLessThanOrEqual(times.count, 301)  // 15 Hz over 20 s, plus the first slot
        XCTAssertGreaterThanOrEqual(times.count, 280)  // and not starved by jitter
        // No 1-second window holds more than 15 publishes (+1 for the tolerance at the edge).
        for (i, t) in times.enumerated() {
            XCTAssertLessThanOrEqual(times[i...].prefix { $0 < t + 1 }.count, 16, "window at \(t)")
        }
    }

    func testPosesCarrySeqCaptureTimeAndTrackingStateAndSeqRestartsPerRun() {
        let recorder = Recorder()
        let pipeline = TrackingPipeline(publish: recorder.add)
        feed(pipeline, frames: 0..<10, rate: 60)  // not started: dropped
        XCTAssertEqual(recorder.snapshots.count, 0)

        pipeline.start(unpaired)
        feed(pipeline, frames: 0..<8, rate: 60, state: VCPTrackingState.excessiveMotion)
        pipeline.stop()
        feed(pipeline, frames: 8..<60, rate: 60)  // after stop: dropped
        XCTAssertEqual(recorder.poses.map(\.seq), [1, 5])
        XCTAssertEqual(recorder.poses.map(\.captureTimeNs), [100_000_000_000, 100_066_666_667])
        XCTAssertEqual(Set(recorder.poses.map(\.trackingState)), [VCPTrackingState.excessiveMotion])
        XCTAssertEqual(recorder.snapshots.last?.packetsSent, 0, "unpaired: nothing is sent")

        // A new run restarts seq at 1; its AR clock starts elsewhere, so the first frame shows at once.
        pipeline.start(unpaired)
        pipeline.queue.sync { pipeline.receive(transform: translation(7), timestamp: 3, trackingState: VCPTrackingState.normal) }
        XCTAssertEqual(recorder.poses.last?.seq, 1)
        XCTAssertEqual(recorder.poses.last?.position.x, 7)
        pipeline.stop()
    }

    /// End to end against the golden vector the Rust host is also tested with: the ARKit frame
    /// behind vcp.md §6.1's example leaves the device as `pose_normal.bin`. The quaternion ARKit →
    /// canonical conversion lands 1 ulp from the vector's rounded 0.7071068 (so the tag differs);
    /// everything else is exact, and the host's key authenticates it.
    func testFirstFrameIsSentAsTheGoldenPose() throws {
        let receiver = try load("vcp/receive.json")["receiver"] as! [String: Any]
        let sid = UInt32(receiver["session_id"] as! Int)
        let d2h = hex(receiver["k_d2h"] as! String), h2d = hex(receiver["k_h2d"] as! String)
        let device = try XCTUnwrap(VCPEndpoint(role: .device, sessionID: sid, kD2H: d2h, kH2D: h2d))
        let blender = try XCTUnwrap(VCPEndpoint(role: .host, sessionID: sid, kD2H: d2h, kH2D: h2d))
        let goldenHex = try XCTUnwrap((try load("vcp/messages.json")["cases"] as! [[String: Any]])
            .first { $0["name"] as? String == "pose_normal" }?["hex"] as? String)
        guard case let .pose(golden) = try blender.open(hex(goldenHex)).get() else {
            return XCTFail("pose_normal is not a POSE")
        }

        let host = try LoopbackReceiver()
        let recorder = Recorder()
        let pipeline = TrackingPipeline(publish: recorder.add)
        pipeline.start(TrackingDestination(host: "127.0.0.1", port: host.port, endpoint: device))
        var arkit = matrix_identity_float4x4
        arkit.columns.3 = SIMD4(0.5, 1.6, 1.25, 1)
        let transform = arkit
        pipeline.queue.async { pipeline.receive(transform: transform, timestamp: 1.0, trackingState: VCPTrackingState.normal) }

        let datagram = try XCTUnwrap(host.receive(timeout: 5))
        XCTAssertEqual(datagram.count, goldenHex.count / 2)
        XCTAssertEqual(Array(datagram.prefix(12)), Array(hex(goldenHex).prefix(12)), "header")
        guard case let .pose(sent) = try blender.open(datagram).get() else {
            return XCTFail("not a POSE")
        }
        XCTAssertEqual(sent.seq, golden.seq)
        XCTAssertEqual(sent.captureTimeNs, golden.captureTimeNs)
        XCTAssertEqual(sent.position, golden.position)
        XCTAssertEqual(sent.trackingState, golden.trackingState)
        XCTAssertEqual(sent.flags, golden.flags)
        for i in 0..<4 {
            XCTAssertEqual(sent.orientation[i], golden.orientation[i], accuracy: 1.5e-7)
        }
        pipeline.stop()
    }

    func testUnpairedRunSendsNothing() throws {
        let host = try LoopbackReceiver()
        let recorder = Recorder()
        let pipeline = TrackingPipeline(publish: recorder.add)
        pipeline.start(TrackingDestination(host: "127.0.0.1", port: host.port, endpoint: nil))
        feed(pipeline, frames: 0..<30, rate: 60)
        XCTAssertNil(host.receive(timeout: 0.3))
        XCTAssertEqual(recorder.poses.last?.seq, 29)  // built and shown all the same
        pipeline.stop()
    }

    func testTrackingStateCodesFollowVCPTable() {
        let cases: [(ARCamera.TrackingState, UInt8)] = [
            (.notAvailable, 0), (.limited(.initializing), 1), (.limited(.excessiveMotion), 2),
            (.limited(.insufficientFeatures), 3), (.limited(.relocalizing), 4), (.normal, 5),
        ]
        for (state, code) in cases {
            XCTAssertEqual(VCPTrackingState.code(for: state), code, "\(state)")
        }
    }
}
