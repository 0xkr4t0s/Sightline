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
    /// Draws the newest decoded viewfinder frame (FR-VF-001/002); nil without Metal.
    @ObservationIgnored let viewfinder: ViewfinderRenderer?
    /// Decodes the pipeline's completed frames for `viewfinder`, off the tracking queue.
    @ObservationIgnored private let decoder: ViewfinderDecoder?
    /// No new viewfinder frame for more than 250 ms during a run (FR-VF-005).
    private(set) var videoStalled = false
    @ObservationIgnored private let stallWatch = VideoStallWatch()
    // ARSession.delegate is weak: this keeps the receiver alive.
    @ObservationIgnored private var receiver: ARFrameReceiver?
    @ObservationIgnored private var rateMeter = PoseRateMeter()
    @ObservationIgnored private var thermalObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let device = DeviceIdentityStore.load()
    /// The session of the current run; its TCP connection stays open until the run stops.
    @ObservationIgnored private var liveSession: VCPLiveSession?
    /// True while a start waits for camera permission or Blender's handshake.
    private(set) var isStarting = false
    /// True while a run that lost its session tries to start a new one (NET-004). AR keeps running.
    private(set) var isReconnecting = false
    /// Loss detected → new session accepted, for the last reconnect this run (NET-004: ≤ 3 s once
    /// the network and Blender are back).
    private(set) var lastReconnectSeconds: Double?
    /// Where this run's sessions come from; a reconnect goes back to the same place.
    @ObservationIgnored private var sessionTarget: SessionTarget?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// The handshake of a start in progress, so an explicit stop can cancel it.
    @ObservationIgnored private var pendingConnect: Task<Result<VCPLiveSession, VCPLinkError>, Never>?
    /// Bumped by every stop: a start that was waiting (camera prompt, handshake) sees it and quits.
    @ObservationIgnored private var runGeneration: UInt64 = 0
    /// Set when the app leaves the foreground mid-run, so the run restarts when it comes back.
    @ObservationIgnored private var resumeWhenActive = false

    init() {
        let settings = TrackingSettings.load()
        host = settings.host
        portText = String(settings.port)
        // Newest snapshot wins: the UI never queues stale frames.
        let (snapshots, continuation) = AsyncStream.makeStream(
            of: TrackingSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let viewfinder = ViewfinderRenderer()
        self.viewfinder = viewfinder
        let decoder = viewfinder.flatMap { renderer in
            ViewfinderDecoder(device: renderer.device) { renderer.show($0) }
        }
        self.decoder = decoder
        pipeline = TrackingPipeline(publish: { _ = continuation.yield($0) },
                                    videoFrame: { decoder?.submit($0, jpeg: $1) })
        let receiver = ARFrameReceiver(pipeline: pipeline) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.receiver = receiver
        session.delegate = receiver
        session.delegateQueue = pipeline.queue
        reloadPairing()
        stallWatch.onChange = { [weak self] in self?.videoStalled = $0 }
        viewfinder?.onShown = { [weak self] in self?.stallWatch.frameShown() }
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
        let generation = runGeneration
        do {
            // An unpaired discovered host can still show local AR poses; it has no UDP destination.
            let destination: (host: String, port: UInt16) = if selectedServiceName == nil {
                try validatedDestination()
            } else {
                ("", 0)
            }
            let granted = await requestCameraAccessIfNeeded()
            guard generation == runGeneration else {
                return  // stopped while the camera prompt was up
            }
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
            let target: SessionTarget = if let selectedServiceName {
                .service(selectedServiceName)
            } else {
                .address(host: destination.host, port: destination.port)
            }
            if let pairing {
                sessionStatus = "Connecting to Blender"
                let device = device
                let connect = Task { () async -> Result<VCPLiveSession, VCPLinkError> in
                    do throws(VCPLinkError) {
                        return .success(try await target.connect(device: device, pairing: pairing,
                                                                 timeout: VCPSessionClient.handshakeTimeout))
                    } catch {
                        return .failure(error)
                    }
                }
                pendingConnect = connect
                let result = await connect.value
                pendingConnect = nil
                guard generation == runGeneration else {
                    if case let .success(late) = result { late.close() }
                    return  // stopped during the handshake
                }
                switch result {
                case let .success(session):
                    link = session
                case let .failure(error):
                    sessionStatus = "Not connected"
                    lastError = error.message
                    return
                }
            }
            sessionTarget = target
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
            lastReconnectSeconds = nil
            sceneUnderstanding = understanding
            isTracking = true
            stallWatch.start()
            sessionStatus = "Starting"
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } catch {
            sessionStatus = "Configuration error"
            lastError = error.localizedDescription
        }
    }

    /// Watches the run's TCP connection: Blender closing it or sending `ERROR` loses the session
    /// (vcp.md §8).
    private func watch(_ link: VCPLiveSession) {
        Task { [weak self] in
            let reason = await link.ended()
            guard let self, self.liveSession === link else {
                return
            }
            self.sessionLost(reason.message)
        }
    }

    /// vcp.md §8, NET-004: a lost session is replaced by a new one with the stored pairing
    /// (`HELLO` mode 1), with no re-pairing. AR tracking keeps running and poses stay on screen,
    /// but nothing leaves the device until the new session is up; its `seq` and `state_seq`
    /// restart at 1 and it opens with the complete `CONTROL_STATE` (`TrackingPipeline.start`).
    private func sessionLost(_ reason: String) {
        guard isTracking, let pairing, let target = sessionTarget else {
            lastError = reason
            stopTracking(reason: "Blender session ended")
            return
        }
        liveSession?.close()
        liveSession = nil
        sessionEndpoint = nil
        pipeline.start(TrackingDestination(host: "", port: 0, endpoint: nil))
        lastError = reason
        sessionStatus = "Reconnecting to Blender"
        isReconnecting = true
        reconnectTask?.cancel()
        let device = device
        let lostAt = ContinuousClock.now
        reconnectTask = Task { [weak self] in
            let result: Result<VCPLiveSession, VCPLinkError>
            do throws(VCPLinkError) {
                result = .success(try await VCPReconnect.run { () async throws(VCPLinkError) -> VCPLiveSession in
                    try await target.connect(device: device, pairing: pairing, timeout: VCPReconnect.attemptTimeout)
                })
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else {
                if case let .success(late) = result { late.close() }
                return
            }
            self.reconnected(result, after: ContinuousClock.now - lostAt)
        }
    }

    private func reconnected(_ result: Result<VCPLiveSession, VCPLinkError>, after elapsed: Duration) {
        reconnectTask = nil
        isReconnecting = false
        switch result {
        case let .success(link):
            liveSession = link
            sessionEndpoint = link.endpoint
            pipeline.start(link.destination)
            watch(link)
            controlSeq = 0
            controlAck = 0
            lastReconnectSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
            lastError = nil
            sessionStatus = "Reconnected"
        case let .failure(error):
            // Only a fatal error ends the loop (a stop cancels this task first): pair again.
            lastError = error.message
            stopTracking(reason: "Pairing no longer accepted")
        }
    }

    func stopTracking(reason: String? = nil) {
        runGeneration &+= 1
        resumeWhenActive = false
        pendingConnect?.cancel()
        pendingConnect = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        sessionTarget = nil
        session.pause()
        pipeline.stop()
        liveSession?.close()
        liveSession = nil
        sessionEndpoint = nil
        isTracking = false
        stallWatch.stop()
        sceneUnderstanding = nil
        poseRate = nil
        if let reason {
            sessionStatus = reason
        } else if lastError == nil {
            sessionStatus = "Stopped"
        }
    }

    /// Leaving the foreground ends the run (ARKit stops in the background); coming back starts it
    /// again with a new session from the stored pairing (NET-004), unless the operator stopped it.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if resumeWhenActive {
                resumeWhenActive = false
                Task { await startTracking() }
            } else if !isTracking, lastError == nil, sessionStatus == "Inactive" || sessionStatus == "Backgrounded" {
                sessionStatus = "Idle"
            }
        case .inactive, .background:
            let reason = phase == .background ? "Backgrounded" : "Inactive"
            if isTracking || isStarting {
                stopTracking(reason: reason)
                resumeWhenActive = true
            } else {
                sessionStatus = reason
            }
        @unknown default:
            break
        }
    }

    private func apply(_ snapshot: TrackingSnapshot) {
        guard isTracking, snapshot.sessionID == sessionEndpoint?.sessionID else {
            return
        }
        if snapshot.sessionLost {
            sessionLost("No authenticated reply from Blender for three seconds.")
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
            if isTracking, !isReconnecting {
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

/// Where a run's sessions come from: the Bonjour service picked in Settings, or a typed address and
/// control port. A reconnect (NET-004) goes back to the same one.
nonisolated enum SessionTarget: Sendable {
    case service(String)
    case address(host: String, port: UInt16)

    func connect(device: VCPDeviceIdentity, pairing: VCPHostPairing,
                 timeout: Double) async throws(VCPLinkError) -> VCPLiveSession {
        switch self {
        case let .service(name):
            try await VCPSessionClient.connect(serviceName: name, device: device, pairing: pairing, timeout: timeout)
        case let .address(host, port):
            try await VCPSessionClient.connect(host: host, port: port, device: device, pairing: pairing, timeout: timeout)
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
