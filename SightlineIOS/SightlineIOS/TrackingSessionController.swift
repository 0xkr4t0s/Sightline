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
    private(set) var selectedServiceName: String? = SelectedServiceStore.load()
    private(set) var isPairing = false
    private(set) var isTracking = false
    private(set) var packetsSent = 0
    /// The newest pose as sent (canonical axes, vcp.md §7), or nil before the first frame.
    private(set) var latestPose: VCPPose?
    /// The selected Blender install's authenticated host ID and pairing key, loaded from Keychain.
    private(set) var pairing: VCPHostPairing?
    /// The authenticated session poses are sealed with, while one is open (vcp.md §10).
    private(set) var sessionEndpoint: VCPEndpoint?
    private(set) var sessionStatus = "Idle"
    private(set) var lastError: String?
    /// Plane detection and LiDAR mesh in the running session (FR-TRK-004), nil when not tracking.
    private(set) var sceneUnderstanding: SceneUnderstanding?
    /// Motion scale, axis locks and the Set origin counter (FR-CTL-004, FR-TRK-003). Every change
    /// goes to the pipeline, which sends it to Blender as `CONTROL_STATE` during a run.
    var controls = DeviceControls() {
        didSet { pipeline.setControls(controls) }
    }
    /// `state_seq` of the newest control state this run, and the host's highest acknowledgement.
    private(set) var controlSeq: UInt32 = 0
    private(set) var controlAck: UInt32 = 0
    /// Poses per second over the last second of capture time (status screen), nil until known.
    private(set) var poseRate: Double?
    /// NFR-LAT-002's send leg over this run's sent poses, nil until one has been sent.
    private(set) var sendLeg: SendLegSummary?
    /// The device's thermal state, kept current from `ProcessInfo` notifications (FR-UX-004).
    private(set) var thermal = ThermalStatus(state: ProcessInfo.processInfo.thermalState)

    @ObservationIgnored private let session = ARSession()
    @ObservationIgnored private let pipeline: TrackingPipeline
    // ARSession.delegate is weak: this keeps the receiver alive.
    @ObservationIgnored private var receiver: ARFrameReceiver?
    @ObservationIgnored private var rateMeter = PoseRateMeter()
    @ObservationIgnored private var thermalObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let device = DeviceIdentityStore.load()
    /// The session of the current run; its TCP connection stays open until the run stops.
    @ObservationIgnored private var liveSession: VCPLiveSession?
    /// True while a start waits for camera permission or Blender's handshake.
    private(set) var isStarting = false

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
        reloadPairing()
        Task { [weak self] in
            for await snapshot in snapshots {
                guard let self else {
                    return
                }
                self.apply(snapshot)
            }
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.thermal = ThermalStatus(state: ProcessInfo.processInfo.thermalState)
            }
        }
    }

    private var pairingAccount: String? {
        if let selectedServiceName { return "bonjour:\(selectedServiceName)" }
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty, let port = UInt16(portText), port > 0 else { return nil }
        return "manual:\(address):\(port)"
    }

    func select(_ discovered: DiscoveredHost) {
        guard discovered.isCompatible, !isTracking, !isPairing else { return }
        selectedServiceName = discovered.id
        SelectedServiceStore.save(discovered.id)
        reloadPairing()
    }

    func selectManual() {
        guard !isTracking, !isPairing else { return }
        selectedServiceName = nil
        SelectedServiceStore.save(nil)
        reloadPairing()
    }

    func manualAddressChanged() {
        guard selectedServiceName == nil else { return }
        reloadPairing()
    }

    private func reloadPairing() {
        pairing = nil
        guard let account = pairingAccount else { return }
        do { pairing = try PairingStore.load(account) }
        catch { lastError = error.localizedDescription }
    }

    func pair(code: String) async {
        guard !isTracking, !isStarting, !isPairing else { return }
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            lastError = "Enter the six-digit code shown in Blender."
            return
        }
        guard let account = pairingAccount else {
            lastError = "Select a Blender host or enter its address and control port."
            return
        }
        isPairing = true
        sessionStatus = "Pairing with Blender"
        defer { isPairing = false }
        var channel: VCPControlChannel?
        do {
            if let selectedServiceName {
                channel = VCPControlChannel(serviceName: selectedServiceName)
            } else {
                let destination = try validatedDestination()
                channel = try VCPControlChannel(host: destination.host, port: destination.port)
                TrackingSettings(host: destination.host, port: Int(destination.port)).save()
            }
            guard let channel else { return }
            defer { channel.close() }
            let newPairing = try await channel.withDeadline(VCPSessionClient.handshakeTimeout) {
                () async throws(VCPLinkError) -> VCPHostPairing in
                try await channel.open()
                return try await VCPSessionClient.pair(on: channel, device: device, code: code)
            }
            try PairingStore.save(newPairing, for: account)
            pairing = newPairing
            let link = try await channel.withDeadline(VCPSessionClient.handshakeTimeout) {
                () async throws(VCPLinkError) -> VCPLiveSession in
                try await VCPSessionClient.startSession(on: channel, device: device) {
                    $0 == newPairing.hostID ? newPairing.pairingKey : nil
                }
            }
            link.close()
            sessionStatus = "Paired"
            lastError = nil
        } catch let error as VCPLinkError {
            sessionStatus = pairing == nil ? "Not paired" : "Paired"
            lastError = error.message
        } catch {
            sessionStatus = pairing == nil ? "Not paired" : "Paired"
            lastError = error.localizedDescription
        }
    }

    func startTracking() async {
        guard !isTracking, !isStarting, !isPairing else {
            return
        }

        guard ARWorldTrackingConfiguration.isSupported else {
            sessionStatus = "Unsupported"
            lastError = "ARWorldTrackingConfiguration is not supported on this device."
            return
        }

        isStarting = true
        defer { isStarting = false }
        do {
            // An unpaired discovered host can still show local AR poses; it has no UDP destination.
            let destination: (host: String, port: UInt16) = if selectedServiceName == nil {
                try validatedDestination()
            } else {
                ("", 0)
            }
            let granted = await requestCameraAccessIfNeeded()
            guard granted else {
                sessionStatus = "Permission denied"
                lastError = "Camera permission is required to run AR tracking."
                return
            }

            if selectedServiceName == nil {
                TrackingSettings(host: destination.host, port: Int(destination.port)).save()
                host = destination.host
            }
            var link: VCPLiveSession?
            if let pairing {
                sessionStatus = "Connecting to Blender"
                do throws(VCPLinkError) {
                    if let selectedServiceName {
                        link = try await VCPSessionClient.connect(serviceName: selectedServiceName,
                                                                  device: device, pairing: pairing)
                    } else {
                        link = try await VCPSessionClient.connect(host: destination.host, port: destination.port,
                                                                  device: device, pairing: pairing)
                    }
                } catch {
                    sessionStatus = "Not connected"
                    lastError = error.message
                    return
                }
            }
            // A new session per run: the run's seq and state_seq restart at 1, as a new session's
            // must (vcp.md §8).
            liveSession = link
            sessionEndpoint = link?.endpoint
            pipeline.start(link?.destination
                ?? TrackingDestination(host: destination.host, port: destination.port, endpoint: nil))
            if let link {
                watch(link)
            }

            let understanding = SceneUnderstanding.forThisDevice()
            let configuration = understanding.makeConfiguration()

            lastError = nil
            packetsSent = 0
            controlSeq = 0
            controlAck = 0
            latestPose = nil
            rateMeter = PoseRateMeter()
            poseRate = nil
            sendLeg = nil
            sceneUnderstanding = understanding
            isTracking = true
            sessionStatus = "Starting"
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } catch {
            sessionStatus = "Configuration error"
            lastError = error.localizedDescription
        }
    }

    /// Stops the run when Blender ends the session: the TCP connection closed or the host sent
    /// `ERROR` (vcp.md §8). Poses stop leaving the device at once.
    private func watch(_ link: VCPLiveSession) {
        Task { [weak self] in
            let reason = await link.ended()
            guard let self, self.liveSession === link else {
                return
            }
            self.lastError = reason.message
            self.stopTracking(reason: "Blender session ended")
        }
    }

    func stopTracking(reason: String? = nil) {
        session.pause()
        pipeline.stop()
        liveSession?.close()
        liveSession = nil
        sessionEndpoint = nil
        isTracking = false
        sceneUnderstanding = nil
        poseRate = nil
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
        if let pose = snapshot.pose {
            rateMeter.add(seq: pose.seq, captureTimeNs: pose.captureTimeNs)
            poseRate = rateMeter.rate
        }
        packetsSent = snapshot.packetsSent
        sendLeg = snapshot.sendLeg
        controlSeq = snapshot.controlSeq
        controlAck = snapshot.controlAck
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
