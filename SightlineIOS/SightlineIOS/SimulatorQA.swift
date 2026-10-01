// Simulator QA mode: lets a script or a UI test run the real app in the Simulator, where ARKit
// doesn't run, against a Blender host. Only the pose source is replaced; pairing, sessions,
// reconnects, video decode, the viewfinder and the overlays all run the normal code.
//
// Compiled only into simulator debug builds: device and App Store builds contain none of it.
#if targetEnvironment(simulator) && DEBUG
import Foundation
import os
import simd

/// Launch arguments, read from the `UserDefaults` argument domain, for example
/// `-SightlineQAHost 127.0.0.1:47000 -SightlineQACode 123456 -SightlineQAMotion orbit
/// -SightlineQAAutoStart YES`. Values written with `defaults write` also count.
nonisolated struct QALaunchOptions: Equatable, Sendable {
    enum Key {
        /// `host[:port]`: use this manual address instead of a discovered host.
        static let host = "SightlineQAHost"
        /// Six digits: pair with this code when the address has no stored pairing, or when a start
        /// with the stored one fails.
        static let code = "SightlineQACode"
        /// `orbit`, `pan` or `still`: scripted 60 Hz poses instead of ARKit.
        static let motion = "SightlineQAMotion"
        /// `YES`: start tracking once the app is active.
        static let autoStart = "SightlineQAAutoStart"
        /// `YES`: delete every stored pairing at launch.
        static let resetPairings = "SightlineQAResetPairings"
        /// `FROM-TO` (frame numbers): report limited tracking for these scripted frames.
        static let limited = "SightlineQALimited"
    }

    var host: String?
    var port: UInt16?
    var code: String?
    var motion: ScriptedMotion?
    var autoStart = false
    var resetPairings = false
    var limitedFrames: ClosedRange<Int>?

    /// This launch's options.
    static let current = QALaunchOptions(defaults: .standard)

    init() {}

    init(defaults: UserDefaults) {
        func text(_ key: String) -> String? {
            guard let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespaces),
                !value.isEmpty
            else { return nil }
            return value
        }
        if let address = text(Key.host).flatMap(Self.parseAddress) {
            host = address.host
            port = address.port
        }
        code = text(Key.code)
        motion = text(Key.motion).flatMap { ScriptedMotion(rawValue: $0.lowercased()) }
        autoStart = defaults.bool(forKey: Key.autoStart)
        resetPairings = defaults.bool(forKey: Key.resetPairings)
        limitedFrames = text(Key.limited).flatMap(Self.parseRange)
    }

    var isActive: Bool {
        host != nil || code != nil || motion != nil || autoStart || resetPairings
    }

    /// `"127.0.0.1:47000"`, `"blender.local"` or `"[::1]:47000"`; nil for an empty host or bad port.
    static func parseAddress(_ text: String) -> (host: String, port: UInt16?)? {
        var host = Substring(text)
        var portText: Substring?
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            let rest = host[host.index(after: close)...]
            host = host[host.index(after: host.startIndex)..<close]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return nil }
                portText = rest.dropFirst()
            }
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            portText = host[host.index(after: colon)...]
            host = host[..<colon]
        }
        guard !host.isEmpty else { return nil }
        guard let portText else { return (String(host), nil) }
        guard let port = UInt16(portText), port > 0 else { return nil }
        return (String(host), port)
    }

    /// `"120-240"` → 120...240.
    static func parseRange(_ text: String) -> ClosedRange<Int>? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let from = Int(parts[0]), let to = Int(parts[1]), from >= 0, from <= to
        else { return nil }
        return from...to
    }
}

/// A smooth, deterministic camera path in ARKit's world frame (y up, the camera looking down its
/// own -z), so the Blender camera visibly moves and every run moves it the same way.
nonisolated enum ScriptedMotion: String, CaseIterable, Sendable {
    /// Swings ±34° on a 1.5 m arc around a point 1.5 m in front of the start, facing it, with a
    /// slight rise and fall and a slow roll (so the horizon level moves too).
    case orbit
    /// Stands still and pans ±29° and tilts ±7°.
    case pan
    /// Holds the start pose.
    case still

    static let rate = 60.0

    /// The camera transform `frame` frames (at `rate`) into the run.
    func transform(frame: Int) -> simd_float4x4 {
        let t = Float(Double(frame) / Self.rate)
        func wave(_ amplitude: Float, period: Float) -> Float {
            amplitude * sin(2 * .pi * t / period)
        }
        let yAxis = SIMD3<Float>(0, 1, 0)
        switch self {
        case .orbit:
            let radius: Float = 1.5
            let swing = wave(0.6, period: 8)
            let position = SIMD3(radius * sin(swing), wave(0.1, period: 4), radius * (cos(swing) - 1))
            let rotation =
                simd_quatf(angle: swing, axis: yAxis) * simd_quatf(angle: wave(0.08, period: 5), axis: [0, 0, 1])
            return Self.matrix(rotation, position)
        case .pan:
            let rotation =
                simd_quatf(angle: wave(0.5, period: 6), axis: yAxis)
                * simd_quatf(angle: wave(0.12, period: 4), axis: [1, 0, 0])
            return Self.matrix(rotation, .zero)
        case .still:
            return matrix_identity_float4x4
        }
    }

    private static func matrix(_ rotation: simd_quatf, _ position: SIMD3<Float>) -> simd_float4x4 {
        var matrix = simd_float4x4(rotation)
        matrix.columns.3 = SIMD4(position, 1)
        return matrix
    }
}

/// Feeds a `ScriptedMotion` into the pipeline at 60 Hz in place of ARKit: on the pipeline's queue
/// and with uptime timestamps, as `ARFrameReceiver` does, so everything from
/// `TrackingPipeline.receive` on is the real path. The first frames report "Initializing", like a
/// new AR session, and `limited` frames report insufficient features.
///
/// `@unchecked Sendable`: `timer` and `frame` are only touched on the pipeline's queue.
nonisolated final class ScriptedPoseSource: PoseSource, @unchecked Sendable {
    static let initializingFrames = 10

    private let pipeline: TrackingPipeline
    private let motion: ScriptedMotion
    private let limited: ClosedRange<Int>?
    private let onEvent: @Sendable (PoseSourceEvent) -> Void
    private var timer: DispatchSourceTimer?
    private var frame = 0
    private var lastState: UInt8?

    init(
        motion: ScriptedMotion, limited: ClosedRange<Int>?, pipeline: TrackingPipeline,
        onEvent: @escaping @Sendable (PoseSourceEvent) -> Void
    ) {
        self.motion = motion
        self.limited = limited
        self.pipeline = pipeline
        self.onEvent = onEvent
    }

    // Explicitly nonisolated: as witnesses of the main-actor protocol they would otherwise be
    // inferred main-actor, and so would the timer handler, which runs on the pipeline's queue.
    nonisolated var isAvailable: Bool { true }
    nonisolated var needsCamera: Bool { false }

    nonisolated func start() -> SceneUnderstanding? {
        pipeline.queue.sync {
            cancelTimer()
            frame = 0
            lastState = nil
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: pipeline.queue)
            let interval = DispatchTimeInterval.nanoseconds(Int(1e9 / ScriptedMotion.rate))
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
            timer.setEventHandler { @Sendable [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
        Log.tracking.notice("Scripted poses started: \(self.motion.rawValue, privacy: .public)")
        return nil
    }

    nonisolated func stop() {
        pipeline.queue.sync { cancelTimer() }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let state =
            if frame < Self.initializingFrames {
                VCPTrackingState.initializing
            } else if limited?.contains(frame) == true {
                VCPTrackingState.insufficientFeatures
            } else {
                VCPTrackingState.normal
            }
        let timestamp = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
        pipeline.receive(transform: motion.transform(frame: frame), timestamp: timestamp, trackingState: state)
        if state != lastState {
            lastState = state
            onEvent(.trackingState(Self.describe(state)))
        }
        frame += 1
    }

    /// The same words `ARFrameReceiver` uses for ARKit's states.
    static func describe(_ state: UInt8) -> String {
        switch state {
        case VCPTrackingState.normal: "Running"
        case VCPTrackingState.initializing: "Initializing"
        case VCPTrackingState.insufficientFeatures: "Limited: insufficient features"
        default: "Limited"
        }
    }
}

extension QALaunchOptions {
    /// The scripted source when `-SightlineQAMotion` is given, else nil (ARKit, which reports
    /// "Unsupported" in the Simulator).
    func poseSource(
        pipeline: TrackingPipeline, onEvent: @escaping @Sendable (PoseSourceEvent) -> Void
    )
        -> (any PoseSource)?
    {
        motion.map { ScriptedPoseSource(motion: $0, limited: limitedFrames, pipeline: pipeline, onEvent: onEvent) }
    }
}
#endif
