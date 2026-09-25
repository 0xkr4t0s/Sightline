import Foundation
import simd

/// What the UI shows of the send path; published at most `UIThrottle.maxRate` times a second.
nonisolated struct TrackingSnapshot: Equatable, Sendable {
    /// The newest pose, as sent (canonical axes); nil before the first frame.
    var pose: VCPPose?
    var packetsSent: Int
    var sendError: String?
    /// `state_seq` of the newest `CONTROL_STATE` built this run (0: none yet), and the highest
    /// `STATUS.control_ack` the host has sent back (vcp.md §6.2).
    var controlSeq: UInt32 = 0
    var controlAck: UInt32 = 0
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

/// The per-frame path, off the main actor (ARC-005): ARKit frame → VCP `POSE` → sealed datagram →
/// UDP send, on one serial queue (FR-TRK-001/002, PR-FD-001). The same path sends the rig controls
/// as `CONTROL_STATE` and reads the host's `STATUS` for their acknowledgement (vcp.md §6.2).
///
/// That queue is the actor's executor, the `ARSession` delegate queue, and the UDP connection's
/// queue, so ARKit callbacks, send completions, received datagrams and the retransmit timer run
/// inside the actor with no hop. The main actor only receives throttled snapshots through `publish`.
actor TrackingPipeline {
    nonisolated let queue = DispatchSerialQueue(label: "VCamIOS.TrackingPipeline", qos: .userInteractive)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private let publish: @Sendable (TrackingSnapshot) -> Void
    private let sender: UDPSender
    private var destination: TrackingDestination?
    private var seq: UInt32 = 0
    private var throttle = UIThrottle()
    private var snapshot = TrackingSnapshot(pose: nil, packetsSent: 0, sendError: nil)
    private var controls = DeviceControls()
    private var statusFilter = VCPSeqFilter()
    private var controlTimer: DispatchSourceTimer?

    /// vcp.md §6.2: the latest state is repeated this often until the host acknowledges it.
    static let controlRepeatInterval: DispatchTimeInterval = .milliseconds(500)

    init(publish: @escaping @Sendable (TrackingSnapshot) -> Void) {
        self.publish = publish
        sender = UDPSender(queue: queue)
    }

    /// Starts a tracking run: `seq` and `state_seq` restart at 1 (vcp.md §6.1, §6.2), and the
    /// current controls go out at once as the run's first, complete `CONTROL_STATE`. Synchronous, so
    /// a start and a stop issued in order on the main actor take effect in that order.
    nonisolated func start(_ destination: TrackingDestination) {
        queue.sync {
            assumeIsolated { pipeline in
                pipeline.sender.close()
                pipeline.sender.onReceive = { [weak pipeline] data in
                    // Received datagrams are delivered on the connection's queue, which is `queue`.
                    pipeline?.assumeIsolated { $0.handleIncoming(data) }
                }
                pipeline.destination = destination
                pipeline.seq = 0
                pipeline.throttle = UIThrottle()
                pipeline.snapshot = TrackingSnapshot(pose: nil, packetsSent: 0, sendError: nil)
                pipeline.statusFilter = VCPSeqFilter()
                pipeline.sendNewControlState()
            }
        }
    }

    /// Stops sending; frames still queued from ARKit are dropped. Synchronous (see `start`).
    nonisolated func stop() {
        queue.sync {
            assumeIsolated { pipeline in
                pipeline.destination = nil
                pipeline.cancelControlTimer()
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
    nonisolated func receive(transform: simd_float4x4, timestamp: TimeInterval, trackingState: UInt8) {
        assumeIsolated { $0.handle(transform: transform, timestamp: timestamp, trackingState: trackingState) }
    }

    private func handle(transform: simd_float4x4, timestamp: TimeInterval, trackingState: UInt8) {
        guard destination != nil else {
            return
        }
        seq &+= 1
        let canonical = VCPCoordinates.canonicalPose(fromARKit: transform)
        let pose = VCPPose(seq: seq, captureTimeNs: UInt64(max(0, (timestamp * 1e9).rounded())),
                           position: canonical.position, orientation: canonical.orientation,
                           trackingState: trackingState)
        snapshot.pose = pose
        send(.pose(pose))
        if throttle.shouldPublish(at: timestamp) {
            publish(snapshot)
        }
    }

    /// Seals and sends one message; without a session endpoint nothing leaves the device.
    private func send(_ message: VCPMessage) {
        guard let destination, let endpoint = destination.endpoint else {
            return
        }
        do {
            let datagram = try endpoint.seal(message)
            sender.send(Data(datagram), host: destination.host, port: destination.port) { [weak self] error in
                // Completions run on the connection's queue, which is `queue`.
                self?.assumeIsolated { $0.record(error) }
            }
        } catch {
            snapshot.sendError = "Message \(message.type) not sealed: \(error)"
        }
    }

    /// vcp.md §6.2: `state_seq` + 1, send on change, then repeat every 500 ms until acknowledged.
    private func sendNewControlState() {
        snapshot.controlSeq &+= 1
        send(.controlState(controls.message(seq: snapshot.controlSeq)))
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
        send(.controlState(controls.message(seq: snapshot.controlSeq)))
    }

    private func cancelControlTimer() {
        controlTimer?.cancel()
        controlTimer = nil
    }

    /// A datagram from the host. Only an authentic, newer `STATUS` counts (§4.3, §6.4); its
    /// `control_ack` ends the repeats once it reaches the latest `state_seq`.
    private func handleIncoming(_ data: Data) {
        guard let endpoint = destination?.endpoint,
              case let .success(.status(status)) = endpoint.open([UInt8](data)),
              statusFilter.accept(status.statusSeq)
        else {
            return
        }
        snapshot.controlAck = max(snapshot.controlAck, status.controlAck)
        if snapshot.controlAck >= snapshot.controlSeq {
            cancelControlTimer()
        }
    }

    private func record(_ error: String?) {
        guard destination != nil else {
            return
        }
        if let error {
            snapshot.sendError = error
        } else {
            snapshot.packetsSent += 1
            snapshot.sendError = nil
        }
    }
}
