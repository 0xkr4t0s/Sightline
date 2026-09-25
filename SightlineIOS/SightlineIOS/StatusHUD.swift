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

/// The device's thermal state as the status screen shows it (FR-UX-004).
nonisolated struct ThermalStatus: Equatable, Sendable {
    var state: ProcessInfo.ThermalState

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
    let centre: CGRect

    init(size: CGSize) {
        let stripHeight = min(Self.statusHeight, size.height * Self.maxShare)
        let railWidth = min(Self.railWidth, size.width * Self.maxShare)
        statusStrip = CGRect(x: 0, y: 0, width: size.width, height: stripHeight)
        controlRail = CGRect(x: size.width - railWidth, y: stripHeight,
                             width: railWidth, height: size.height - stripHeight)
        centre = CGRect(x: size.width / 4, y: size.height / 4,
                        width: size.width / 2, height: size.height / 2)
    }
}
