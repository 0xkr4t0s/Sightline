import Foundation
import simd

/// What the UI shows of the send path; published at most `UIThrottle.maxRate` times a second.
nonisolated struct TrackingSnapshot: Equatable, Sendable {
    /// The newest pose, as sent (canonical axes); nil before the first frame.
    var pose: VCPPose?
    var packetsSent: Int
    var sendError: String?
    /// Tags asynchronous snapshots so events from a previous session can be ignored.
    var sessionID: UInt32?
    var sessionLost = false
    /// Latest state sent this run (0: none yet), and the highest
    /// `STATUS.control_ack` the host has sent back (vcp.md §6.2).
    var controlSeq: UInt32 = 0
    var controlAck: UInt32 = 0
    /// NFR-LAT-002's send leg over this run's poses; nil until one has been sent.
    var sendLeg: SendLegSummary?
}

/// Where poses go: the host's UDP address and the session that authenticates them (vcp.md §4).
nonisolated struct TrackingDestination: Sendable {
    var host: String
    var port: UInt16
    /// The device side of an authenticated session. Without one, poses are built and shown but not
    /// sent: the host drops unauthenticated datagrams (PR-006).
    var endpoint: VCPEndpoint?
}

/// The operator's rig controls, sent to Blender as the complete v1 `CONTROL_STATE` (vcp.md §6.2):
/// motion scale and axis locks (FR-CTL-004), and the Set origin counter (FR-TRK-003).
nonisolated struct DeviceControls: Equatable, Sendable {
    static let scaleRange: ClosedRange<Float> = 0.001...1000
    static let lockHeight: UInt8 = 1 << 0
    static let lockRoll: UInt8 = 1 << 1
    static let panOnly: UInt8 = 1 << 2

    /// Host metres per device metre (1:10 is `10`).
    var motionScale: Float = 1
    var lockFlags: UInt8 = 0
    var originEpoch: UInt16 = 0

    /// Asks the host to re-zero position and yaw at the current pose; the host reacts to any
    /// change, so the counter simply wraps.
    mutating func setOrigin() {
        originEpoch &+= 1
    }

    func isLocked(_ flag: UInt8) -> Bool {
        lockFlags & flag != 0
    }

    mutating func setLock(_ flag: UInt8, _ on: Bool) {
        lockFlags = on ? lockFlags | flag : lockFlags & ~flag
    }

    /// A scale typed by the operator ("10", "0,5"), or nil if it isn't a number in `scaleRange`.
    static func parseScale(_ text: String) -> Float? {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacing(",", with: ".")
        guard let value = Float(normalized), value.isFinite, scaleRange.contains(value) else {
            return nil
        }
        return value
    }

    /// Every v1 field is present: the first state of a session must carry them all, and sending
    /// the full state every time keeps a lost datagram from leaving the ends out of sync.
    func message(seq: UInt32) -> VCPControlState {
        VCPControlState(stateSeq: seq, motionScale: motionScale, lockFlags: lockFlags, originEpoch: originEpoch)
    }
}

/// Rate limit for UI updates (ARC-005: ≤ 15 Hz), driven by the frame timestamps.
///
/// Slots are `1 / maxRate` apart and advance by exactly one interval per publish, so the long-run
/// rate never exceeds `maxRate` even when frames arrive a little early or late. A frame up to
/// `tolerance` before its slot counts as on time (60 Hz frames land on every 4th slot exactly).
/// A clock jump of more than one interval (a new AR session) restarts the cadence.
nonisolated struct UIThrottle: Sendable {
    static let maxRate = 15.0
    static let tolerance: TimeInterval = 0.001

    let interval: TimeInterval
    private var due: TimeInterval?

    init(maxRate: Double = UIThrottle.maxRate) {
        interval = 1 / maxRate
    }

    mutating func shouldPublish(at time: TimeInterval) -> Bool {
        guard let due else {
            self.due = time + interval
            return true
        }
        if time < due - Self.tolerance, time > due - interval - Self.tolerance {
            return false
        }
        self.due = abs(time - due) < interval ? due + interval : time + interval
        return true
    }
}

/// Send-leg percentiles in nanoseconds (NFR-LAT-002).
nonisolated struct SendLegSummary: Equatable, Sendable {
    var count: Int
    var p50: UInt64
    var p95: UInt64
    var p99: UInt64
    var max: UInt64

    /// NFR-LAT-002: p95 ≤ 2 ms.
    var meetsTarget: Bool { p95 <= SendLegMeter.target }
}

/// NFR-LAT-002's send leg on the device: the ARKit frame reaching the pipeline → its POSE datagram
/// handed to the kernel. Samples go into 10 µs bins up to 5 ms, plus one overflow bin, so recording
/// a pose allocates nothing. Percentiles are nearest-rank and report the upper edge of their bin
/// (capped at the maximum), so they never understate.
nonisolated struct SendLegMeter: Sendable {
    static let binWidth: UInt64 = 10_000
    static let target: UInt64 = 2_000_000

    private var bins = InlineArray<500, UInt32>(repeating: 0)
    private(set) var count = 0
    private var max: UInt64 = 0

    mutating func add(_ ns: UInt64) {
        if ns < Self.binWidth * UInt64(bins.count) {
            bins[Int(ns / Self.binWidth)] &+= 1
        }
        count += 1
        max = Swift.max(max, ns)
    }

    var summary: SendLegSummary? {
        guard count > 0 else {
            return nil
        }
        return SendLegSummary(count: count, p50: percentile(50), p95: percentile(95), p99: percentile(99), max: max)
    }

    /// The smallest bin edge with at least `percent` % of the samples at or below it.
    private func percentile(_ percent: Int) -> UInt64 {
        let rank = (count * percent + 99) / 100
        var seen = 0
        for i in bins.indices {
            seen += Int(bins[i])
            if seen >= rank {
                return Swift.min(UInt64(i + 1) * Self.binWidth, max)
            }
        }
        return max  // in the overflow bin
    }
}

/// The per-frame path, off the main actor (ARC-005): ARKit frame → VCP `POSE` → sealed datagram →
/// UDP send, on one serial queue (FR-TRK-001/002, PR-FD-001). The same path sends the rig controls
/// as `CONTROL_STATE` and reads the host's `STATUS` for their acknowledgement (vcp.md §6.2), and
/// reassembles the viewfinder's `VIDEO_FRAGMENT`s, handing each completed frame to the decoder and
/// reporting how they arrive in `VIDEO_REPORT` (§6.5, §6.6).
///
/// That queue is the actor's executor, the `ARSession` delegate queue, and the UDP socket's read
/// queue, so ARKit callbacks, received datagrams and the retransmit timer run inside the actor with
/// no hop. A pose is sealed into one reused buffer and handed to the kernel by a single `send`, so
/// the per-pose path allocates nothing (NFR-LAT-002). The main actor only receives throttled
/// snapshots through `publish`.
actor TrackingPipeline {
    nonisolated let queue = DispatchSerialQueue(label: "Sightline.TrackingPipeline", qos: .userInteractive)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private let publish: @Sendable (TrackingSnapshot) -> Void
    /// Receives each completed viewfinder frame (a copy of its bytes), in `frame_id` order.
    private let videoFrame: @Sendable (VCPVideoFrameInfo, Data) -> Void
    private let sender: UDPSender
    private var destination: TrackingDestination?
    private var seq: UInt32 = 0
    private var throttle = UIThrottle()
    private var snapshot = TrackingSnapshot(pose: nil, packetsSent: 0, sendError: nil)
    private var controls = DeviceControls()
    private var statusFilter = VCPSeqFilter()
    private var controlTimer: DispatchSourceTimer?
    private var livenessTimer: DispatchSourceTimer?
    /// Every datagram is sealed into this buffer; its capacity is reserved once.
    private var datagram: [UInt8] = []
    private var sendLeg = SendLegMeter()
    /// This session's viewfinder frames (§6.5); the report timer runs once the first fragment arrived.
    private var video = VCPVideoReassembler()
    private var reportSeq: UInt32 = 0
    private var reportTimer: DispatchSourceTimer?
    /// Bumped by every start and stop, so a host name resolved after its run ended is ignored.
    private var run: UInt64 = 0

    /// vcp.md §6.6: `VIDEO_REPORT` interval once viewfinder frames arrive.
    static let videoReportInterval: DispatchTimeInterval = .milliseconds(500)

    /// vcp.md §6.2: the latest state is repeated this often until the host acknowledges it.
    static let controlRepeatInterval: DispatchTimeInterval = .milliseconds(500)

    init(publish: @escaping @Sendable (TrackingSnapshot) -> Void,
         videoFrame: @escaping @Sendable (VCPVideoFrameInfo, Data) -> Void = { _, _ in }) {
        self.publish = publish
        self.videoFrame = videoFrame
        sender = UDPSender(queue: queue)
        datagram.reserveCapacity(VCPEndpoint.maxDatagram)
    }

    /// Starts a tracking run: `seq` and `state_seq` restart at 1 (vcp.md §6.1, §6.2), and the
    /// current controls go out at once as the run's first, complete `CONTROL_STATE`. Synchronous, so
    /// a start and a stop issued in order on the main actor take effect in that order.
    nonisolated func start(_ destination: TrackingDestination) {
        queue.sync {
            assumeIsolated { pipeline in
                pipeline.sender.close()
                pipeline.cancelLivenessTimer()
                pipeline.run &+= 1
                let run = pipeline.run
                pipeline.sender.onReceive = { [weak pipeline] data in
                    // A queued read from a replaced socket must not affect the new run.
                    pipeline?.assumeIsolated {
                        if $0.run == run { $0.handleIncoming(data) }
                    }
                }
                pipeline.destination = destination
                pipeline.seq = 0
                pipeline.throttle = UIThrottle()
                pipeline.snapshot = TrackingSnapshot(pose: nil, packetsSent: 0, sendError: nil)
                pipeline.snapshot.sessionID = destination.endpoint?.sessionID
                pipeline.sendLeg = SendLegMeter()
                pipeline.statusFilter = VCPSeqFilter()
                // §6.6: report_seq and both counters start again with each session.
                pipeline.cancelReportTimer()
                pipeline.video = VCPVideoReassembler()
                pipeline.reportSeq = 0
                pipeline.connect()
                pipeline.sendNewControlState()
                pipeline.startLivenessTimer()
            }
        }
    }

    /// Stops sending; frames still queued from ARKit are dropped. Synchronous (see `start`).
    nonisolated func stop() {
        queue.sync {
            assumeIsolated { pipeline in
                pipeline.run &+= 1
                pipeline.destination = nil
                pipeline.cancelControlTimer()
                pipeline.cancelLivenessTimer()
                pipeline.cancelReportTimer()
                pipeline.sender.close()
            }
        }
    }

    /// The operator changed a control. A real change becomes the next `state_seq` and is sent at
    /// once during a run; either way it's what the next run starts with. Synchronous (see `start`).
    nonisolated func setControls(_ controls: DeviceControls) {
        queue.sync {
            assumeIsolated { pipeline in
                guard controls != pipeline.controls else {
                    return
                }
                pipeline.controls = controls
                if pipeline.destination != nil {
                    pipeline.sendNewControlState()
                }
            }
        }
    }

    /// Entry point for ARKit frames. Must be called on `queue` (the ARSession delegate queue).
    /// `timestamp` is `ARFrame.timestamp` (seconds, device clock); `trackingState` a §6.1 code.
    ///
    /// Not `assumeIsolated`: it wraps its closure with `withoutActuallyEscaping` and a bit-cast,
    /// which costs 2 heap blocks (closure contexts) per call, i.e. per pose (measured, task
    /// 1.5.1b). This does the same without closures: `dispatchPrecondition` is the isolation check
    /// (`queue` is the actor's executor), and `handleFrame` is a context-free function whose
    /// `isolated` parameter is dropped by the same bit-cast the standard library uses.
    nonisolated func receive(transform: simd_float4x4, timestamp: TimeInterval, trackingState: UInt8) {
        let arrived = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        dispatchPrecondition(condition: .onQueue(queue))
        typealias Isolated = (isolated TrackingPipeline, simd_float4x4, TimeInterval, UInt8, UInt64) -> Void
        typealias Unchecked = (TrackingPipeline, simd_float4x4, TimeInterval, UInt8, UInt64) -> Void
        unsafeBitCast(handleFrame as Isolated, to: Unchecked.self)(self, transform, timestamp, trackingState, arrived)
    }

    fileprivate func handle(transform: simd_float4x4, timestamp: TimeInterval, trackingState: UInt8, arrived: UInt64) {
        guard destination != nil else {
            return
        }
        seq &+= 1
        let canonical = VCPCoordinates.canonicalPose(fromARKit: transform)
        let pose = VCPPose(seq: seq, captureTimeNs: UInt64(max(0, (timestamp * 1e9).rounded())),
                           position: canonical.position, orientation: canonical.orientation,
                           trackingState: trackingState)
        snapshot.pose = pose
        if send(.pose(pose)) {
            sendLeg.add(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- arrived)
        }
        if throttle.shouldPublish(at: timestamp) {
            snapshot.sendLeg = sendLeg.summary
            publish(snapshot)
        }
    }

    /// Opens the socket for a paired run. An address connects at once; a host name is resolved off
    /// the ARKit queue (it may take a DNS or mDNS round trip), and datagrams before that are dropped.
    private func connect() {
        guard let destination, destination.endpoint != nil else {
            return
        }
        let (host, port, run) = (destination.host, destination.port, run)
        if case let .success(address) = UDPSender.resolve(host: host, port: port, numericOnly: true) {
            connected(.success(address), run: run)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let resolved = UDPSender.resolve(host: host, port: port, numericOnly: false)
            queue.async { self.assumeIsolated { $0.connected(resolved, run: run) } }
        }
    }

    private func connected(_ resolved: Result<UDPAddress, UDPResolveError>, run: UInt64) {
        guard run == self.run else {
            return
        }
        switch resolved {
        case let .success(address):
            if let code = sender.connect(to: address) {
                snapshot.sendError = "Can't open the UDP socket: \(String(cString: strerror(code)))"
            }
        case let .failure(error):
            snapshot.sendError = "Can't resolve \(destination?.host ?? ""): \(error.message)"
        }
    }

    /// Seals and sends one message; `true` if it was handed to the kernel. Without a session
    /// endpoint nothing leaves the device.
    private func send(_ message: VCPMessage) -> Bool {
        guard let endpoint = destination?.endpoint else {
            return false
        }
        do {
            try endpoint.seal(message, into: &datagram)
        } catch {
            snapshot.sendError = "Message \(message.type) not sealed: \(error)"
            return false
        }
        switch sender.send(datagram) {
        case .sent:
            snapshot.packetsSent += 1
            snapshot.sendError = nil
            return true
        case .notConnected:
            return false
        case let .failed(code):
            snapshot.sendError = String(cString: strerror(code))
            return false
        }
    }

    /// vcp.md §6.2: `state_seq` + 1, send on change, then repeat every 500 ms until acknowledged.
    private func sendNewControlState() {
        snapshot.controlSeq &+= 1
        _ = send(.controlState(controls.message(seq: snapshot.controlSeq)))
        cancelControlTimer()
        guard destination?.endpoint != nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.controlRepeatInterval, repeating: Self.controlRepeatInterval)
        timer.setEventHandler { [weak self] in
            self?.assumeIsolated { $0.repeatControlState() }
        }
        timer.resume()
        controlTimer = timer
    }

    private func repeatControlState() {
        guard snapshot.controlAck < snapshot.controlSeq else {
            cancelControlTimer()
            return
        }
        _ = send(.controlState(controls.message(seq: snapshot.controlSeq)))
    }

    private func cancelControlTimer() {
        controlTimer?.cancel()
        controlTimer = nil
    }

    /// Independent of AR frames and control acknowledgements: an idle device must also detect
    /// a silent host after 3 seconds (§8). A stopped/replaced run cannot expire a newer one.
    private func startLivenessTimer() {
        guard destination?.endpoint != nil else { return }
        let run = run
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(3))
        timer.setEventHandler { [weak self] in
            self?.assumeIsolated { pipeline in
                guard pipeline.run == run else { return }
                pipeline.run &+= 1
                pipeline.destination = nil
                pipeline.cancelControlTimer()
                pipeline.cancelLivenessTimer()
                pipeline.cancelReportTimer()
                pipeline.sender.close()
                pipeline.snapshot.sessionLost = true
                pipeline.publish(pipeline.snapshot)
            }
        }
        timer.resume()
        livenessTimer = timer
    }

    private func cancelLivenessTimer() {
        livenessTimer?.cancel()
        livenessTimer = nil
    }

    /// §6.6: every 500 ms from the first valid `VIDEO_FRAGMENT` until the session ends; the totals
    /// make retransmission unnecessary. Motion-to-photon isn't measured yet (0, task 2.6).
    private func startReportTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.videoReportInterval, repeating: Self.videoReportInterval)
        timer.setEventHandler { [weak self] in
            self?.assumeIsolated { $0.sendVideoReport() }
        }
        timer.resume()
        reportTimer = timer
    }

    private func sendVideoReport() {
        reportSeq &+= 1
        _ = send(.videoReport(video.report(seq: reportSeq, m2pP95Ms: 0)))
    }

    private func cancelReportTimer() {
        reportTimer?.cancel()
        reportTimer = nil
    }

    /// Only a valid authenticated host datagram refreshes liveness (§8). STATUS freshness is
    /// separate: an older status can keep the link alive, but must not acknowledge controls.
    private func handleIncoming(_ data: Data) {
        let received = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard let endpoint = destination?.endpoint,
              case let .success(message) = endpoint.open([UInt8](data))
        else {
            return
        }
        livenessTimer?.schedule(deadline: .now() + .seconds(3))
        switch message {
        case let .clock(.request(t1)):
            // Uptime is the candidate ARFrame clock; O-1 still needs a physical-device
            // comparison before claiming capture-to-host latency accuracy.
            _ = send(.clock(.reply(t1: t1, t2: received,
                                  t3: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))))
        case let .status(status):
            guard statusFilter.accept(status.statusSeq) else { return }
            snapshot.controlAck = max(snapshot.controlAck, status.controlAck)
            if snapshot.controlAck >= snapshot.controlSeq {
                cancelControlTimer()
            }
        case let .videoFragment(fragment):
            // Stale, duplicate and inconsistent fragments still count as the stream arriving.
            // A completed frame is copied out, as the reassembler reuses its buffer (FR-VF-001).
            if video.push(fragment) == .complete, let frame = video.frame {
                videoFrame(frame.info, Data(frame.data))
            }
            if reportTimer == nil { startReportTimer() }
        default:
            // VCPEndpoint rejects every other host-to-device message in v1.
            break
        }
    }
}

/// `TrackingPipeline.receive`'s way into the actor: a free function, so referring to it captures
/// nothing (a static method would capture its metatype: one heap block per call).
private func handleFrame(_ pipeline: isolated TrackingPipeline, _ transform: simd_float4x4, _ timestamp: TimeInterval,
                         _ trackingState: UInt8, _ arrived: UInt64) {
    pipeline.handle(transform: transform, timestamp: timestamp, trackingState: trackingState, arrived: arrived)
}
