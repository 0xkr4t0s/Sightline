import ARKit
import Darwin
import Foundation
import simd
import XCTest

/// The device send path (tasks 1.4.1, 1.4.2, 1.4.4): ARKit frames become VCP `POSE` datagrams off
/// the main thread (ARC-005, FR-TRK-001/002, PR-FD-001), the UI hears about them at most 15 times a
/// second, and the rig controls go out as `CONTROL_STATE` until the host acknowledges them
/// (FR-CTL-004, FR-TRK-003).
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

    /// Keeps only the newest snapshot, without touching the heap (unlike `Recorder`'s array).
    private final class Latest: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TrackingSnapshot?

        func set(_ snapshot: TrackingSnapshot) {
            lock.withLock { value = snapshot }
        }

        var snapshot: TrackingSnapshot? { lock.withLock { value } }
    }

    /// A UDP socket on 127.0.0.1 that plays the host; it replies to the last sender, as the host does.
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

        private var source = sockaddr_in()

        /// The next datagram, or nil after `timeout` seconds.
        func receive(timeout: Double) -> [UInt8]? {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1e6))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 2048)
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &len) }
            }
            return n > 0 ? Array(buffer[..<n]) : nil
        }

        /// Sends `bytes` to where the last received datagram came from.
        func reply(_ bytes: [UInt8]) {
            var to = source
            _ = withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
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

    /// Both ends of the golden session (`receive.json`'s receiver keys).
    private func goldenSession() throws -> (device: VCPEndpoint, blender: VCPEndpoint) {
        let receiver = try load("vcp/receive.json")["receiver"] as! [String: Any]
        let sid = UInt32(receiver["session_id"] as! Int)
        let d2h = hex(receiver["k_d2h"] as! String), h2d = hex(receiver["k_h2d"] as! String)
        return (try XCTUnwrap(VCPEndpoint(role: .device, sessionID: sid, kD2H: d2h, kH2D: h2d)),
                try XCTUnwrap(VCPEndpoint(role: .host, sessionID: sid, kD2H: d2h, kH2D: h2d)))
    }

    private func goldenHex(_ name: String) throws -> String {
        try XCTUnwrap((try load("vcp/messages.json")["cases"] as! [[String: Any]])
            .first { $0["name"] as? String == name }?["hex"] as? String)
    }

    /// The next datagram of VCP `type` (header byte 5), skipping others; nil after `timeout`.
    private func next(_ type: UInt8, from host: LoopbackReceiver, timeout: Double = 5) -> [UInt8]? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while case let left = deadline.timeIntervalSinceNow, left > 0 {
            guard let datagram = host.receive(timeout: left) else { return nil }
            if datagram.count > 5, datagram[5] == type { return datagram }
        }
        return nil
    }

    private func controlState(_ datagram: [UInt8]?, _ blender: VCPEndpoint) throws -> VCPControlState {
        guard case let .controlState(state) = try blender.open(XCTUnwrap(datagram)).get() else {
            throw POSIXError(.EBADMSG)
        }
        return state
    }

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
        let (device, blender) = try goldenSession()
        let goldenHex = try self.goldenHex("pose_normal")
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

        let datagram = try XCTUnwrap(next(VCPMessageType.pose, from: host))
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
        var controls = DeviceControls()
        controls.setOrigin()
        pipeline.setControls(controls)
        XCTAssertNil(host.receive(timeout: 0.3))
        XCTAssertEqual(recorder.poses.last?.seq, 29)  // built and shown all the same
        pipeline.stop()
    }

    /// Sends `frames` poses (after 10 warm-up frames) on the calling thread inside `queue.sync`, so
    /// the counter sees exactly the pipeline's per-pose work, then reads them back as the host.
    private func sendPoses(_ frames: Int) throws -> (allocations: Int, last: VCPPose?, leg: SendLegSummary?) {
        let (device, blender) = try goldenSession()
        let host = try LoopbackReceiver()
        var room: Int32 = 8 << 20  // hold every datagram until it is read
        setsockopt(host.fd, SOL_SOCKET, SO_RCVBUF, &room, socklen_t(MemoryLayout<Int32>.size))
        let latest = Latest()
        let pipeline = TrackingPipeline(publish: latest.set)
        pipeline.start(TrackingDestination(host: "127.0.0.1", port: host.port, endpoint: device))
        defer { pipeline.stop() }
        let warmUp = 10
        var allocations = -1
        pipeline.queue.sync {
            let frame = { (i: Int) in
                pipeline.receive(transform: self.translation(Float(i)), timestamp: 100 + Double(i) / 60,
                                 trackingState: VCPTrackingState.normal)
            }
            for i in 0..<warmUp {
                frame(i)
            }
            allocations = heapAllocations {
                for i in warmUp..<warmUp + frames {
                    frame(i)
                }
            }
        }
        var last: VCPPose?
        while last?.seq != UInt32(warmUp + frames), let datagram = next(VCPMessageType.pose, from: host, timeout: 2) {
            guard case let .pose(pose) = try blender.open(datagram).get() else { throw POSIXError(.EBADMSG) }
            last = pose
        }
        return (allocations, last, latest.snapshot?.sendLeg)
    }

    /// NFR-LAT-002: from the frame reaching the pipeline to the POSE handed to the kernel, a pose
    /// allocates nothing. Checked on optimised code only (CI runs this test with `-configuration
    /// Release`): at `-Onone` generics stay unspecialised and closures boxed, about 12 blocks a pose.
    func testPoseSendPathAllocatesNothing() throws {
        #if DEBUG
        throw XCTSkip("allocation-free only when optimised: run with -configuration Release")
        #else
        // The counter works here: an array of one byte is one allocation.
        var bytes: [UInt8] = []
        XCTAssertEqual(heapAllocations { bytes = [UInt8](repeating: 1, count: 1) }, 1)
        XCTAssertEqual(bytes, [1])

        let (allocations, last, _) = try sendPoses(600)
        XCTAssertEqual(allocations, 0, "heap allocations over 600 poses")
        XCTAssertEqual(last?.position.x, 609, "the last pose arrives, authentic and intact")
        print("VCAM_SEND_ALLOCATIONS poses=600 allocations=\(allocations)")
        #endif
    }

    /// NFR-LAT-002: every pose handed to the kernel is a send-leg sample of its run.
    func testSendLegIsMeasuredForSentPoses() throws {
        let (_, last, sendLeg) = try sendPoses(600)
        XCTAssertEqual(last?.position.x, 609, "the last pose arrives, authentic and intact")
        let leg = try XCTUnwrap(sendLeg)
        XCTAssertEqual(leg.count, 609)  // as of the last publish: frame 608 (every 4th frame at 60 Hz)
        XCTAssertLessThanOrEqual(leg.p50, leg.p95)
        XCTAssertLessThanOrEqual(leg.p95, leg.max)
        XCTAssertTrue(leg.meetsTarget, "send leg p95 \(leg.p95) ns")
        print("VCAM_SEND_LEG n=\(leg.count) p50=\(leg.p50) p95=\(leg.p95) p99=\(leg.p99) max=\(leg.max) ns")
    }

    /// Unpaired frames aren't send-leg samples: nothing was handed to the kernel.
    func testSendLegIsNotMeasuredWithoutASession() {
        let latest = Latest()
        let pipeline = TrackingPipeline(publish: latest.set)
        pipeline.start(unpaired)
        feed(pipeline, frames: 0..<8, rate: 60)
        pipeline.stop()
        XCTAssertNotNil(latest.snapshot?.pose)
        XCTAssertNil(latest.snapshot?.sendLeg)
    }

    /// A host name (not an address) is resolved off the ARKit queue; poses flow once it is.
    func testHostNameIsResolvedAndPosesFlow() throws {
        let (device, blender) = try goldenSession()
        let host = try LoopbackReceiver()
        let pipeline = TrackingPipeline(publish: { _ in })
        pipeline.start(TrackingDestination(host: "localhost", port: host.port, endpoint: device))
        var received: VCPPose?
        for i in 0..<100 where received == nil {
            feed(pipeline, frames: i..<i + 1, rate: 60)
            if let datagram = next(VCPMessageType.pose, from: host, timeout: 0.05),
               case let .pose(pose) = try blender.open(datagram).get() {
                received = pose
            }
        }
        XCTAssertNotNil(received, "no POSE reached 127.0.0.1 via \"localhost\"")
        pipeline.stop()
    }

    /// Nearest-rank percentiles report their bin's upper edge (capped at the maximum), and samples
    /// past the last bin still count.
    func testSendLegMeterPercentiles() throws {
        var meter = SendLegMeter()
        XCTAssertNil(meter.summary)
        meter.add(3_000)
        XCTAssertEqual(meter.summary, SendLegSummary(count: 1, p50: 3_000, p95: 3_000, p99: 3_000, max: 3_000))

        meter = SendLegMeter()
        for i in 0..<100 {
            meter.add(UInt64(i) * 10_000 + 5_000)  // one sample in each of bins 0...99
        }
        XCTAssertEqual(meter.summary, SendLegSummary(count: 100, p50: 500_000, p95: 950_000, p99: 990_000, max: 995_000))

        // Ten samples: the 95th percentile's rank is 9.5, rounded up to the 10th (the maximum).
        meter = SendLegMeter()
        for i in 0..<10 {
            meter.add(UInt64(i) * 10_000 + 5_000)
        }
        XCTAssertEqual(meter.summary, SendLegSummary(count: 10, p50: 50_000, p95: 95_000, p99: 95_000, max: 95_000))

        meter = SendLegMeter()
        for _ in 0..<80 {
            meter.add(1_000)
        }
        for _ in 0..<20 {
            meter.add(6_000_000)  // past the 5 ms of bins
        }
        let summary = try XCTUnwrap(meter.summary)
        XCTAssertEqual(summary, SendLegSummary(count: 100, p50: 10_000, p95: 6_000_000, p99: 6_000_000, max: 6_000_000))
        XCTAssertFalse(summary.meetsTarget)
        XCTAssertTrue(SendLegSummary(count: 1, p50: 0, p95: 2_000_000, p99: 0, max: 0).meetsTarget)
        XCTAssertFalse(SendLegSummary(count: 1, p50: 0, p95: 2_000_001, p99: 0, max: 0).meetsTarget)
    }

    /// vcp.md §6.2: a run opens with its complete state as `state_seq` 1, every real change is the
    /// next `state_seq` and leaves at once, and the bytes are those of the golden vector the Rust
    /// host is tested with (`control_state_full`: seq 7, scale 10, lock roll, origin_epoch 3).
    func testControlChangesAreNumberedAndSentAsTheGoldenControlState() throws {
        let (device, blender) = try goldenSession()
        let host = try LoopbackReceiver()
        let pipeline = TrackingPipeline(publish: { _ in })
        pipeline.start(TrackingDestination(host: "127.0.0.1", port: host.port, endpoint: device))

        let first = try controlState(next(VCPMessageType.controlState, from: host), blender)
        XCTAssertEqual(first, VCPControlState(stateSeq: 1, motionScale: 1, lockFlags: 0, originEpoch: 0))

        var controls = DeviceControls()
        var changes: [DeviceControls] = []
        controls.motionScale = 2; changes.append(controls)
        controls.motionScale = 10; changes.append(controls)
        changes.append(controls)  // unchanged: not a new state
        controls.setLock(DeviceControls.lockRoll, true); changes.append(controls)
        for _ in 1...3 {
            controls.setOrigin(); changes.append(controls)
        }
        var seen: [UInt32] = [1]
        var last: [UInt8] = []
        for change in changes {
            pipeline.setControls(change)
        }
        while seen.last != 7, let datagram = next(VCPMessageType.controlState, from: host, timeout: 2) {
            let seq = try controlState(datagram, blender).stateSeq
            if seq != seen.last { seen.append(seq) }
            last = datagram
        }
        XCTAssertEqual(seen, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(last, hex(try goldenHex("control_state_full")))
        pipeline.stop()
    }

    /// vcp.md §6.2: the latest state repeats every 500 ms until an authentic, newer STATUS carries
    /// `control_ack` ≥ its `state_seq`; a stale STATUS (lower `status_seq`) doesn't count.
    func testControlStateRepeatsUntilAFreshStatusAcknowledgesIt() throws {
        let (device, blender) = try goldenSession()
        let host = try LoopbackReceiver()
        let pipeline = TrackingPipeline(publish: { _ in })
        pipeline.start(TrackingDestination(host: "127.0.0.1", port: host.port, endpoint: device))
        func status(_ seq: UInt32, ack: UInt32) throws -> [UInt8] {
            try blender.seal(.status(VCPStatus(statusSeq: seq, appliedPoseSeq: 0, controlAck: ack, errorCode: 0,
                                               flags: 3, cameraName: "Camera")))
        }

        XCTAssertEqual(try controlState(next(VCPMessageType.controlState, from: host), blender).stateSeq, 1)
        let sent = Date()
        XCTAssertEqual(try controlState(next(VCPMessageType.controlState, from: host, timeout: 1), blender).stateSeq, 1)
        XCTAssertGreaterThan(Date().timeIntervalSince(sent), 0.4, "repeats are 500 ms apart")

        host.reply(try status(5, ack: 0))  // not acknowledged yet
        XCTAssertNotNil(next(VCPMessageType.controlState, from: host, timeout: 1))
        host.reply(try status(4, ack: 1))  // stale STATUS: ignored
        XCTAssertNotNil(next(VCPMessageType.controlState, from: host, timeout: 1))
        host.reply(try status(6, ack: 1))
        var after = 0  // at most one repeat already on its way; bounded in case repeats never stop
        while after < 3, next(VCPMessageType.controlState, from: host, timeout: 1.2) != nil { after += 1 }
        XCTAssertLessThanOrEqual(after, 1, "repeats stop once acknowledged")

        var controls = DeviceControls()
        controls.setOrigin()
        pipeline.setControls(controls)
        let change = try controlState(next(VCPMessageType.controlState, from: host, timeout: 0.3), blender)
        XCTAssertEqual(change.stateSeq, 2)
        XCTAssertEqual(change.originEpoch, 1)
        XCTAssertEqual(try controlState(next(VCPMessageType.controlState, from: host, timeout: 1), blender).stateSeq, 2,
                       "a new state repeats again until acknowledged")
        pipeline.stop()
    }

    /// CLOCK and STATUS independently renew the deadline; authentication precedes renewal,
    /// while STATUS sequence filtering still protects control acknowledgements.
    func testHostHeartbeatsRenewLivenessButForgedTrafficDoesNot() throws {
        let (device, blender) = try goldenSession()
        let host = try LoopbackReceiver()
        let recorder = Recorder()
        let lost = expectation(description: "silent host expired")
        let pipeline = TrackingPipeline(publish: {
            recorder.add($0)
            if $0.sessionLost { lost.fulfill() }
        })
        pipeline.start(TrackingDestination(host: "127.0.0.1", port: host.port, endpoint: device))
        defer { pipeline.stop() }
        _ = try XCTUnwrap(next(VCPMessageType.controlState, from: host))
        let status = VCPStatus(statusSeq: 5, appliedPoseSeq: 0, controlAck: 1, errorCode: 0,
                               flags: 3, cameraName: "Camera")
        host.reply(try blender.seal(.status(status)))
        Thread.sleep(forTimeInterval: 1.6)

        let before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        host.reply(try blender.seal(.clock(.request(t1: 5_000_000_000))))
        let reply = try blender.open(XCTUnwrap(next(VCPMessageType.clock, from: host))).get()
        let after = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard case let .clock(.reply(t1, t2, t3)) = reply else { return XCTFail("not a CLOCK reply") }
        XCTAssertEqual(t1, 5_000_000_000)
        XCTAssertGreaterThanOrEqual(t2, before)
        XCTAssertGreaterThanOrEqual(t3, t2)
        XCTAssertLessThanOrEqual(t3, after)
        Thread.sleep(forTimeInterval: 1.6)
        XCTAssertFalse(recorder.snapshots.contains { $0.sessionLost }, "CLOCK must renew the initial deadline")

        var stale = status
        stale.statusSeq = 4
        stale.controlAck = 99
        host.reply(try blender.seal(.status(stale)))
        let lastValid = Date()
        Thread.sleep(forTimeInterval: 1.6)
        feed(pipeline, frames: 0..<1, rate: 60)
        XCTAssertEqual(recorder.snapshots.last?.controlAck, 1, "stale STATUS cannot acknowledge controls")
        XCTAssertFalse(recorder.snapshots.contains { $0.sessionLost }, "authenticated STATUS renews liveness")
        var forged = try blender.seal(.clock(.request(t1: 6_000_000_000)))
        forged[forged.count - 1] ^= 1
        host.reply(forged)
        XCTAssertNil(next(VCPMessageType.clock, from: host, timeout: 0.2), "bad tag must not elicit a reply")
        wait(for: [lost], timeout: 2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(lastValid), 2.9)
        XCTAssertEqual(recorder.snapshots.last?.sessionID, device.sessionID)
    }

    func testSilentSessionExpiresWithoutFramesAndStopsSending() throws {
        let (device, _) = try goldenSession()
        let host = try LoopbackReceiver()
        let lost = expectation(description: "no initial heartbeat")
        let pipeline = TrackingPipeline(publish: { if $0.sessionLost { lost.fulfill() } })
        pipeline.start(TrackingDestination(host: "127.0.0.1", port: host.port, endpoint: device))
        defer { pipeline.stop() }
        let began = Date()
        wait(for: [lost], timeout: 3.6)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 2.9)
        while host.receive(timeout: 0.02) != nil {} // drain controls sent before expiry
        feed(pipeline, frames: 0..<8, rate: 60)
        pipeline.setControls(DeviceControls(motionScale: 2))
        XCTAssertNil(host.receive(timeout: 0.6), "neither poses nor control repeats leave an expired session")
    }

    func testReplacementAndStopCancelTheOldLivenessDeadline() throws {
        let (device, _) = try goldenSession()
        let host = try LoopbackReceiver()
        let recorder = Recorder()
        let pipeline = TrackingPipeline(publish: recorder.add)
        let destination = TrackingDestination(host: "127.0.0.1", port: host.port, endpoint: device)
        pipeline.start(destination)
        Thread.sleep(forTimeInterval: 1.6)
        pipeline.start(destination)
        Thread.sleep(forTimeInterval: 1.6)
        feed(pipeline, frames: 0..<1, rate: 60)
        XCTAssertEqual(recorder.poses.last?.seq, 1)
        XCTAssertFalse(recorder.snapshots.contains { $0.sessionLost }, "replaced run's deadline must be cancelled")
        pipeline.stop()
        pipeline.start(unpaired)
        Thread.sleep(forTimeInterval: 3.2)
        feed(pipeline, frames: 0..<1, rate: 60)
        pipeline.stop()
        XCTAssertFalse(recorder.snapshots.contains { $0.sessionLost }, "stopped/unauthenticated runs must not expire")
        XCTAssertNil(recorder.snapshots.last?.sessionID)
    }

    func testDeviceControlsLocksOriginWrapAndScaleInput() {
        var controls = DeviceControls()
        controls.setLock(DeviceControls.lockHeight, true)
        controls.setLock(DeviceControls.panOnly, true)
        controls.setLock(DeviceControls.lockHeight, false)
        XCTAssertEqual(controls.lockFlags, DeviceControls.panOnly)
        controls.originEpoch = UInt16.max
        controls.setOrigin()
        XCTAssertEqual(controls.originEpoch, 0)  // §6.2: wraps 65535 → 0

        XCTAssertEqual(DeviceControls.parseScale("10"), 10)
        XCTAssertEqual(DeviceControls.parseScale(" 0,5 "), 0.5)
        XCTAssertEqual(DeviceControls.parseScale("0.001"), 0.001)
        XCTAssertEqual(DeviceControls.parseScale("1000"), 1000)
        for bad in ["0.0009", "1000.5", "0", "-2", "inf", "nan", "", "x"] {
            XCTAssertNil(DeviceControls.parseScale(bad), bad)
        }
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
