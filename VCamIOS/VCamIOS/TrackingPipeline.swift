import Foundation
import simd

/// What the UI shows of the send path; published at most `UIThrottle.maxRate` times a second.
nonisolated struct TrackingSnapshot: Equatable, Sendable {
    /// The newest pose, as sent (canonical axes); nil before the first frame.
    var pose: VCPPose?
    var packetsSent: Int
    var sendError: String?
}

/// Where poses go: the host's UDP address and the session that authenticates them (vcp.md §4).
nonisolated struct TrackingDestination: Sendable {
    var host: String
    var port: UInt16
    /// The device side of an authenticated session. Without one, poses are built and shown but not
    /// sent: the host drops unauthenticated datagrams (PR-006).
    var endpoint: VCPEndpoint?
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
/// UDP send, on one serial queue (FR-TRK-001/002, PR-FD-001).
///
/// That queue is the actor's executor, the `ARSession` delegate queue, and the UDP connection's
/// queue, so ARKit callbacks and send completions run inside the actor with no hop. The main actor
/// only receives throttled snapshots through `publish`.
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

    init(publish: @escaping @Sendable (TrackingSnapshot) -> Void) {
        self.publish = publish
        sender = UDPSender(queue: queue)
    }

    /// Starts a tracking run: `seq` restarts at 1 (vcp.md §6.1). Synchronous, so a start and a stop
    /// issued in order on the main actor take effect in that order.
    nonisolated func start(_ destination: TrackingDestination) {
        queue.sync {
            assumeIsolated { pipeline in
                pipeline.sender.close()
                pipeline.destination = destination
                pipeline.seq = 0
                pipeline.throttle = UIThrottle()
                pipeline.snapshot = TrackingSnapshot(pose: nil, packetsSent: 0, sendError: nil)
            }
        }
    }

    /// Stops sending; frames still queued from ARKit are dropped. Synchronous (see `start`).
    nonisolated func stop() {
        queue.sync {
            assumeIsolated { pipeline in
                pipeline.destination = nil
                pipeline.sender.close()
            }
        }
    }

    /// Entry point for ARKit frames. Must be called on `queue` (the ARSession delegate queue).
    /// `timestamp` is `ARFrame.timestamp` (seconds, device clock); `trackingState` a §6.1 code.
    nonisolated func receive(transform: simd_float4x4, timestamp: TimeInterval, trackingState: UInt8) {
        assumeIsolated { $0.handle(transform: transform, timestamp: timestamp, trackingState: trackingState) }
    }

    private func handle(transform: simd_float4x4, timestamp: TimeInterval, trackingState: UInt8) {
        guard let destination else {
            return
        }
        seq &+= 1
        let canonical = VCPCoordinates.canonicalPose(fromARKit: transform)
        let pose = VCPPose(seq: seq, captureTimeNs: UInt64(max(0, (timestamp * 1e9).rounded())),
                           position: canonical.position, orientation: canonical.orientation,
                           trackingState: trackingState)
        snapshot.pose = pose
        if let endpoint = destination.endpoint {
            do {
                let datagram = try endpoint.seal(.pose(pose))
                sender.send(Data(datagram), host: destination.host, port: destination.port) { [weak self] error in
                    // Completions run on the connection's queue, which is `queue`.
                    self?.assumeIsolated { $0.record(error) }
                }
            } catch {
                snapshot.sendError = "POSE not sealed: \(error)"
            }
        }
        if throttle.shouldPublish(at: timestamp) {
            publish(snapshot)
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
