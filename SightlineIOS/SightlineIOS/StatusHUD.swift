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
/// requested stream setting, and the lens Blender reports, not the one the phone asked for.
/// Latency stays unknown until its later milestone.
nonisolated enum HUDFields {
    static let noLens = "Focal — · Focus — · f/— · FOV —"
    static let m2p = "—"

    /// The applied lens (vcp.md §6.4) with the horizontal FOV and 35 mm-equivalent focal length
    /// (LNS-002), which are unknown unless Blender fits the sensor horizontally. C formatting, so
    /// the decimal point doesn't follow the locale, as in the N-panel.
    static func lens(_ applied: VCPAppliedLens?) -> String {
        guard let applied else { return noLens }
        let focal = String(format: "Focal %.4g mm", Double(applied.lensMM))
        let focus = String(format: "Focus %.2f m", Double(applied.focusDistanceM))
        let fstop = String(format: "f/%.3g", Double(applied.fstop))
        let derived =
            applied.horizontalFOVAndEquivalent.map {
                String(format: "FOV %.1f° · Equiv %.0f mm", $0.fovDegrees, $0.equivalentMM)
            } ?? "FOV —"
        return [focal, focus, fstop, derived].joined(separator: " · ")
    }
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
/// control rail along the trailing edge, under the right thumb in landscape. The data panel's
/// whole container fits below `centre`, the middle half of the displayed picture, with
/// `centreMargin` to spare.
nonisolated struct HUDLayout: Equatable, Sendable {
    static let statusHeight: CGFloat = 44
    static let railWidth: CGFloat = 96
    static let panelMaxHeight: CGFloat = 100
    /// Gap between the data panel and `centre`, so pixel rounding can't push the panel into it.
    static let centreMargin: CGFloat = 4
    /// Largest share of the frame's height (strip) or width (rail) either may take.
    static let maxShare: CGFloat = 0.2
    /// The lens panel takes the rail's place and whatever else is free right of the centre, within
    /// these widths. Below the minimum (a small split-view window) it may cover the centre.
    static let lensPanelMinWidth: CGFloat = 140
    static let lensPanelMaxWidth: CGFloat = 240

    let statusStrip: CGRect
    let controlRail: CGRect
    let lensPanel: CGRect
    let dataPanel: CGRect
    let centre: CGRect

    /// Both rectangles use the safe-area reader's coordinates, not global screen coordinates.
    init(size: CGSize, picture: CGRect? = nil, viewfinder: CGRect? = nil) {
        let stripHeight = min(Self.statusHeight, size.height * Self.maxShare)
        let railWidth = min(Self.railWidth, size.width * Self.maxShare)
        let image = picture ?? CGRect(origin: .zero, size: size)
        let canvas = viewfinder ?? CGRect(origin: .zero, size: size)
        // A mask can shrink the picture's centre; still leave the full viewfinder middle half
        // clear (the UI's centre-clear contract).
        centre = image.insetBy(dx: image.width / 4, dy: image.height / 4)
            .union(canvas.insetBy(dx: canvas.width / 4, dy: canvas.height / 4))
        statusStrip = CGRect(x: 0, y: 0, width: size.width, height: stripHeight)
        controlRail = CGRect(
            x: size.width - railWidth, y: stripHeight,
            width: railWidth, height: size.height - stripHeight)
        let lensWidth = min(
            Self.lensPanelMaxWidth, max(Self.lensPanelMinWidth, size.width - centre.maxX - Self.centreMargin))
        lensPanel = CGRect(
            x: size.width - lensWidth, y: stripHeight, width: lensWidth, height: size.height - stripHeight)
        let panelHeight = min(Self.panelMaxHeight, max(0, size.height - centre.maxY - Self.centreMargin))
        dataPanel = CGRect(
            x: 0, y: size.height - panelHeight,
            width: min(430, size.width - railWidth), height: panelHeight)
    }
}
