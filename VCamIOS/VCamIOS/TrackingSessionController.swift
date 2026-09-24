import ARKit
import AVFoundation
import Foundation
import Observation
import SwiftUI

/// UI state and start/stop (main actor). The per-frame work runs in `TrackingPipeline` on its own
/// queue (ARC-005); this object only sees throttled snapshots (≤ 15 Hz) and rare session events.
@MainActor
@Observable
final class TrackingSessionController {
    var host: String
    var portText: String
    private(set) var isTracking = false
    private(set) var packetsSent = 0
    /// The newest pose as sent (canonical axes, vcp.md §7), or nil before the first frame.
    private(set) var latestPose: VCPPose?
    /// The authenticated session poses are sealed with. It comes from pairing and session setup
    /// over TCP (tasks 1.1.4b/1.4.3), which don't exist yet; until then poses are shown, not sent.
    private(set) var sessionEndpoint: VCPEndpoint?
    private(set) var sessionStatus = "Idle"
    private(set) var lastError: String?

    @ObservationIgnored private let session = ARSession()
    @ObservationIgnored private let pipeline: TrackingPipeline
    // ARSession.delegate is weak: this keeps the receiver alive.
    @ObservationIgnored private var receiver: ARFrameReceiver?

    init() {
        let settings = TrackingSettings.load()
        host = settings.host
        portText = String(settings.port)
        // Newest snapshot wins: the UI never queues stale frames.
        let (snapshots, continuation) = AsyncStream.makeStream(
            of: TrackingSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        pipeline = TrackingPipeline(publish: { _ = continuation.yield($0) })
        let receiver = ARFrameReceiver(pipeline: pipeline) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.receiver = receiver
        session.delegate = receiver
        session.delegateQueue = pipeline.queue
        Task { [weak self] in
            for await snapshot in snapshots {
                guard let self else {
                    return
                }
                self.apply(snapshot)
            }
        }
    }

    func startTracking() async {
        guard !isTracking else {
            return
        }

        guard ARWorldTrackingConfiguration.isSupported else {
            sessionStatus = "Unsupported"
            lastError = "ARWorldTrackingConfiguration is not supported on this device."
            return
        }

        do {
            let destination = try validatedDestination()
            let granted = await requestCameraAccessIfNeeded()
            guard granted else {
                sessionStatus = "Permission denied"
                lastError = "Camera permission is required to run AR tracking."
                return
            }

            TrackingSettings(host: destination.host, port: Int(destination.port)).save()
            host = destination.host
            pipeline.start(TrackingDestination(host: destination.host, port: destination.port, endpoint: sessionEndpoint))

            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity

            lastError = nil
            packetsSent = 0
            latestPose = nil
            isTracking = true
            sessionStatus = "Starting"
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } catch {
            sessionStatus = "Configuration error"
            lastError = error.localizedDescription
        }
    }

    func stopTracking(reason: String? = nil) {
        session.pause()
        pipeline.stop()
        isTracking = false
        if let reason {
            sessionStatus = reason
        } else if lastError == nil {
            sessionStatus = "Stopped"
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if !isTracking, lastError == nil, sessionStatus == "Inactive" || sessionStatus == "Backgrounded" {
                sessionStatus = "Idle"
            }
        case .inactive:
            if isTracking {
                stopTracking(reason: "Inactive")
            } else {
                sessionStatus = "Inactive"
            }
        case .background:
            if isTracking {
                stopTracking(reason: "Backgrounded")
            } else {
                sessionStatus = "Backgrounded"
            }
        @unknown default:
            break
        }
    }

    private func apply(_ snapshot: TrackingSnapshot) {
        guard isTracking else {
            return
        }
        latestPose = snapshot.pose
        packetsSent = snapshot.packetsSent
        if let error = snapshot.sendError {
            lastError = error
            sessionStatus = "Send error"
        } else if sessionStatus == "Send error" {
            lastError = nil
            sessionStatus = "Running"
        }
    }

    private func handle(_ event: ARFrameReceiver.Event) {
        switch event {
        case .trackingState(let description):
            if isTracking {
                sessionStatus = description
            }
        case .failed(let message):
            lastError = message
            stopTracking(reason: "Session failed")
        case .interrupted:
            sessionStatus = "Interrupted"
            lastError = "The AR session was interrupted."
        case .interruptionEnded:
            sessionStatus = "Interruption ended"
        }
    }

    private func validatedDestination() throws -> (host: String, port: UInt16) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw UDPSenderError.invalidHost
        }
        guard let port = UInt16(portText), port > 0 else {
            throw UDPSenderError.invalidPort
        }
        return (trimmedHost, port)
    }

    private func requestCameraAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

/// The ARSession delegate. It runs on the pipeline's queue (`ARSession.delegateQueue`), never the
/// main thread: frames go straight into the pipeline, and rare session events go to `onEvent`.
nonisolated final class ARFrameReceiver: NSObject, ARSessionDelegate, Sendable {
    enum Event: Sendable {
        case trackingState(String)
        case failed(String)
        case interrupted
        case interruptionEnded
    }

    private let pipeline: TrackingPipeline
    private let onEvent: @Sendable (Event) -> Void

    init(pipeline: TrackingPipeline, onEvent: @escaping @Sendable (Event) -> Void) {
        self.pipeline = pipeline
        self.onEvent = onEvent
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Copy the values out: holding the ARFrame would stall ARKit's frame pool. The tracking
        // state travels with every pose (FR-TRK-002).
        let camera = frame.camera
        pipeline.receive(transform: camera.transform, timestamp: frame.timestamp,
                         trackingState: VCPTrackingState.code(for: camera.trackingState))
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        onEvent(.trackingState(Self.describe(camera.trackingState)))
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onEvent(.failed(error.localizedDescription))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        onEvent(.interrupted)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        onEvent(.interruptionEnded)
    }

    private static func describe(_ trackingState: ARCamera.TrackingState) -> String {
        switch trackingState {
        case .normal:
            return "Running"
        case .notAvailable:
            return "Tracking unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing:
                return "Initializing"
            case .excessiveMotion:
                return "Limited: excessive motion"
            case .insufficientFeatures:
                return "Limited: insufficient features"
            case .relocalizing:
                return "Relocalizing"
            @unknown default:
                return "Limited"
            }
        }
    }
}
