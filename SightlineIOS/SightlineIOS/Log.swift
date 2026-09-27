import os

/// The app's unified log (`log stream --predicate 'subsystem == "kr8t0s.Sightline"'`).
///
/// Host addresses, service names and device names go in as `privacy: .private`. Pairing codes,
/// pairing keys and session keys are never logged.
nonisolated enum Log {
    static let subsystem = "kr8t0s.Sightline"

    /// Session start, stop, loss and reconnect (vcp.md §8, NET-004).
    static let session = Logger(subsystem: subsystem, category: "session")
    /// Pairing with a Blender host (vcp.md §9).
    static let pairing = Logger(subsystem: subsystem, category: "pairing")
    /// The pose source: ARKit or, in simulator QA runs, the scripted path.
    static let tracking = Logger(subsystem: subsystem, category: "tracking")
    /// Viewfinder frames and stalls (FR-VF-001/005).
    static let video = Logger(subsystem: subsystem, category: "video")
    /// Tap-to-focus, focus marks and racks the operator asks for (FR-CTL-002).
    static let lens = Logger(subsystem: subsystem, category: "lens")
    /// Hardware buttons and game controllers (FR-CTL-008).
    static let input = Logger(subsystem: subsystem, category: "input")
    /// Simulator QA mode (launch arguments), compiled only into simulator debug builds.
    static let qa = Logger(subsystem: subsystem, category: "qa")
}

extension VCPLinkError {
    /// The error for a public log line: a network failure's detail can hold a host address, so
    /// only its kind is shown (log `message` privately for the rest).
    nonisolated var logSummary: String {
        if case .network = self {
            return "Can't reach Blender (network error)"
        }
        return message
    }
}
