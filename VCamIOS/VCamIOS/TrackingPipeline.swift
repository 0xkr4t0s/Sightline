import Foundation
import simd

/// What the UI shows of the send path; published at most `UIThrottle.maxRate` times a second.
nonisolated struct TrackingSnapshot: Equatable, Sendable {
    var pose: TrackingPose
    var packetsSent: Int
    var sendError: String?
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

/// The per-frame path, off the main actor (ARC-005): pose → packet → UDP send, on one serial queue.
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
    private var destination: (host: String, port: UInt16)?
    private var throttle = UIThrottle()
    private var snapshot = TrackingSnapshot(pose: .zero, packetsSent: 0, sendError: nil)

    init(publish: @escaping @Sendable (TrackingSnapshot) -> Void) {
        self.publish = publish
        sender = UDPSender(queue: queue)
    }

    /// Starts sending to `host:port`. Synchronous, so a start and a stop issued in order on the
    /// main actor take effect in that order.
    nonisolated func start(host: String, port: UInt16) {
        queue.sync {
            assumeIsolated { pipeline in
                pipeline.sender.close()
                pipeline.destination = (host, port)
                pipeline.throttle = UIThrottle()
                pipeline.snapshot = TrackingSnapshot(pose: .zero, packetsSent: 0, sendError: nil)
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
    nonisolated func receive(transform: simd_float4x4, timestamp: TimeInterval) {
        assumeIsolated { $0.handle(transform: transform, timestamp: timestamp) }
    }

    private func handle(transform: simd_float4x4, timestamp: TimeInterval) {
        guard let destination else {
            return
        }
        let pose = TrackingPose(cameraTransform: transform, timestamp: timestamp)
        snapshot.pose = pose
        sender.send(FreeDPacketEncoder.encode(pose: pose), host: destination.host, port: destination.port) {
            [weak self] error in
            // Completions run on the connection's queue, which is `queue`.
            self?.assumeIsolated { $0.record(error) }
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
