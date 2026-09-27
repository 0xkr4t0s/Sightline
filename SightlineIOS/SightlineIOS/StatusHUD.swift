import CoreGraphics
import Foundation

/// Tracking rate for the status screen (task 1.4.5). It counts pose `seq` steps against ARKit
/// capture time, so frames the UI throttle skipped still count, and a slow main thread can't
/// make the rate look lower than it is.
nonisolated struct PoseRateMeter: Sendable {
    /// The rate is recomputed once at least this much capture time has passed.
    static let windowNs: UInt64 = 1_000_000_000

    private var anchorSeq: UInt32?
    private var anchorTimeNs: UInt64 = 0
    /// Poses per second over the last full window, or nil until one has passed.
    private(set) var rate: Double?

    mutating func add(seq: UInt32, captureTimeNs: UInt64) {
        guard let startSeq = anchorSeq, seq >= startSeq, captureTimeNs >= anchorTimeNs else {
            // First pose, or a new run (seq restarts at 1) or clock: start over.
            anchorSeq = seq
            anchorTimeNs = captureTimeNs
            rate = nil
            return
        }
        let elapsed = captureTimeNs - anchorTimeNs
        guard elapsed >= Self.windowNs else {
            return
        }
        rate = Double(seq - startSeq) / (Double(elapsed) / 1e9)
        anchorSeq = seq
        anchorTimeNs = captureTimeNs
    }
}

/// The worse of STATUS loss and viewfinder frame loss determines the link indicator (FR-VF-004).
nonisolated enum ConnectionQuality: Int, Comparable, Sendable {
    case good, fair, poor

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .good: "Good"
        case .fair: "Fair"
        case .poor: "Poor"
        }
    }
}

nonisolated struct StreamStats: Equatable, Sendable {
    var framesPerSecond: Double
    var megabitsPerSecond: Double
    var quality: ConnectionQuality

    var label: String {
        "\(Int(framesPerSecond.rounded())) fps · \(megabitsPerSecond.formatted(.number.precision(.fractionLength(1)))) Mbit/s"
    }
}

/// One per authenticated session. All times use CLOCK_UPTIME_RAW; a caller supplies the clock
/// so the one-second window and the strict silence boundary can be tested without sleeping.
nonisolated struct StreamMeter: Sendable {
    static let windowNs: UInt64 = 1_000_000_000
    private var windowStartNs: UInt64
    private var lastHostNs: UInt64
    private var dataBytes: UInt64 = 0
    private var lastStatusSeq: UInt32?
    private var statusExpected: UInt64 = 0
    private var statusReceived: UInt64 = 0
    private var previousComplete: UInt64 = 0
    private var previousLost: UInt64 = 0
    private var lastRates: (fps: Double, mbps: Double)?
    private var windowQuality: ConnectionQuality = .good

    init(startNs: UInt64) {
        windowStartNs = startNs
        lastHostNs = startNs
    }

    mutating func hostDatagram(atNs nowNs: UInt64) {
        lastHostNs = max(lastHostNs, nowNs)
    }

    /// Only fresh STATUS messages count towards sequence loss; the baseline crosses windows.
    mutating func status(seq: UInt32) {
        if let last = lastStatusSeq, seq > last {
            statusExpected += UInt64(seq - last)
            statusReceived += 1
        }
        lastStatusSeq = seq
    }

    /// Count the data field, not the VCP header/tag, for every authenticated VIDEO_FRAGMENT.
    mutating func fragment(dataBytes count: Int) {
        dataBytes += UInt64(count)
    }

    mutating func snapshot(atNs nowNs: UInt64, complete: UInt64, lost: UInt64) -> StreamStats? {
        if nowNs >= windowStartNs, nowNs - windowStartNs >= Self.windowNs {
            let seconds = Double(nowNs - windowStartNs) / 1e9
            let completed = complete - previousComplete
            let missing = lost - previousLost
            let frameLoss = completed + missing == 0 ? 0 : Double(missing) / Double(completed + missing)
            let statusLoss = statusExpected == 0 ? 0 : Double(statusExpected - statusReceived) / Double(statusExpected)
            let loss = max(frameLoss, statusLoss)
            windowQuality = loss >= 0.10 ? .poor : loss >= 0.02 ? .fair : .good
            lastRates = (Double(completed) / seconds, Double(dataBytes) * 8 / seconds / 1e6)
            windowStartNs = nowNs
            previousComplete = complete
            previousLost = lost
            dataBytes = 0
            statusExpected = 0
            statusReceived = 0
        }
        guard let lastRates else { return nil }
        let silent = nowNs > lastHostNs && nowNs - lastHostNs > Self.windowNs
        return StreamStats(
            framesPerSecond: lastRates.fps, megabitsPerSecond: lastRates.mbps,
            quality: silent ? .poor : windowQuality)
    }
}

/// The device's thermal state as the status screen shows it (FR-UX-004).
nonisolated struct ThermalStatus: Equatable, Sendable {
    var state: ProcessInfo.ThermalState

    var code: UInt8 {
        switch state {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        @unknown default: 0
        }
    }

    var label: String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    /// From `.serious` on, FR-UX-004 wants the stream reduced; the HUD shows it as a warning.
    var isWarning: Bool {
        state == .serious || state == .critical
    }
}

/// FR-VF-004: display only facts from the decoded frame that was handed to Metal, not the
/// requested stream setting. Lens and latency stay unknown until their later milestones.
nonisolated enum HUDFields {
    static let lens = "Focal — · Focus — · f/—"
    static let m2p = "—"
    static let recording = "Recording: not available (T3)"

    static func level(quality: UInt8, size: CGSize) -> String {
        let q = quality == 0 ? "—" : String(quality)
        return "q\(q) · \(Int(size.width))×\(Int(size.height))"
    }

    static func tracking(running: Bool, state: UInt8?) -> String {
        guard running else { return "Stopped" }
        guard let state else { return "Starting" }
        if state == VCPPose.trackingNormal { return "Tracking" }
        return state == 0 ? "Tracking unavailable" : "Tracking limited"
    }

    static func thermal(_ status: ThermalStatus) -> String {
        status.isWarning ? "Stream reduced (thermal)" : "Thermal: \(status.label)"
    }
}

/// When the status screen's controls are on screen (FR-UX-003: they auto-hide). While not
/// tracking they stay up, so Start is always reachable.
nonisolated struct ChromeVisibility: Hashable, Sendable {
    static let hideAfter: Duration = .seconds(4)

    private(set) var lastInteraction: ContinuousClock.Instant
    private var hiddenByTap = false

    init(now: ContinuousClock.Instant) {
        lastInteraction = now
    }

    func isShown(at now: ContinuousClock.Instant, tracking: Bool) -> Bool {
        guard tracking else {
            return true
        }
        return !hiddenByTap && now - lastInteraction < Self.hideAfter
    }

    /// Any use of a control: show, and restart the hide countdown.
    mutating func interact(at now: ContinuousClock.Instant) {
        lastInteraction = now
        hiddenByTap = false
    }

    /// A tap on the frame shows hidden controls or hides shown ones.
    mutating func tapFrame(at now: ContinuousClock.Instant, tracking: Bool) {
        if isShown(at: now, tracking: tracking) {
            hiddenByTap = tracking
        } else {
            interact(at: now)
        }
    }
}

/// Where the status screen puts things (FR-UX-003): a status strip along the top edge and the
/// control rail along the trailing edge, under the right thumb in landscape. Both are capped so
/// they stay out of `centre`, the middle half of the frame in each direction, which holds the
/// rule-of-thirds points.
nonisolated struct HUDLayout: Equatable, Sendable {
    static let statusHeight: CGFloat = 44
    static let railWidth: CGFloat = 96
    /// Largest share of the frame's height (strip) or width (rail) either may take.
    static let maxShare: CGFloat = 0.2

    let statusStrip: CGRect
    let controlRail: CGRect
    let dataPanel: CGRect
    let centre: CGRect

    init(size: CGSize) {
        let stripHeight = min(Self.statusHeight, size.height * Self.maxShare)
        let railWidth = min(Self.railWidth, size.width * Self.maxShare)
        statusStrip = CGRect(x: 0, y: 0, width: size.width, height: stripHeight)
        controlRail = CGRect(
            x: size.width - railWidth, y: stripHeight,
            width: railWidth, height: size.height - stripHeight)
        let panelHeight = min(100, size.height * 0.24)
        dataPanel = CGRect(
            x: 0, y: size.height - panelHeight,
            width: min(430, size.width - railWidth), height: panelHeight)
        centre = CGRect(
            x: size.width / 4, y: size.height / 4,
            width: size.width / 2, height: size.height / 2)
    }
}
