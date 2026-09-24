import ARKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

@MainActor
final class TrackingSessionController: NSObject, ObservableObject {
    @Published var host: String
    @Published var portText: String
    @Published private(set) var isTracking = false
    @Published private(set) var packetsSent = 0
    @Published private(set) var latestPose = TrackingPose.zero
    @Published private(set) var sessionStatus = "Idle"
    @Published private(set) var lastError: String?

    private let session = ARSession()
    private let sender = UDPSender()

    override init() {
        let settings = TrackingSettings.load()
        host = settings.host
        portText = String(settings.port)
        super.init()
        session.delegate = self
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
            sender.close()

            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity

            lastError = nil
            packetsSent = 0
            latestPose = .zero
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
        sender.close()
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
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func send(pose: TrackingPose) {
        guard isTracking else {
            return
        }

        do {
            let destination = try validatedDestination()
            host = destination.host
            let packet = FreeDPacketEncoder.encode(pose: pose)
            latestPose = pose

            sender.send(packet, host: destination.host, port: destination.port) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }

                    switch result {
                    case .success:
                        self.packetsSent += 1
                        self.lastError = nil
                    case .failure(let error):
                        self.lastError = error.localizedDescription
                        self.sessionStatus = "Send error"
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
            sessionStatus = "Configuration error"
            stopTracking(reason: "Stopped")
        }
    }

    private func trackingStateDescription(_ trackingState: ARCamera.TrackingState) -> String {
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

extension TrackingSessionController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let pose = TrackingPose(cameraTransform: frame.camera.transform, timestamp: frame.timestamp)
        Task { @MainActor [weak self] in
            self?.send(pose: pose)
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if self.isTracking {
                self.sessionStatus = self.trackingStateDescription(camera.trackingState)
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.lastError = error.localizedDescription
            self?.stopTracking(reason: "Session failed")
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.sessionStatus = "Interrupted"
            self?.lastError = "The AR session was interrupted."
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.sessionStatus = "Interruption ended"
        }
    }
}
