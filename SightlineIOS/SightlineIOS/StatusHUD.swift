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

/// How well the host's datagrams are getting through, as the HUD shows it (FR-VF-004).
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

/// The viewfinder stream and the link it arrives on, for the HUD (FR-VF-004).
nonisolated struct StreamStats: Equatable, Sendable {
    /// Viewfinder frames completed per second.
    var framesPerSecond: Double
    /// Video data received (every authentic `VIDEO_FRAGMENT`'s data), in bits per second.
    var bitsPerSecond: Double
    var quality: ConnectionQuality

    /// "24 fps · 6.1 Mbit/s".
    var label: String {
        "\(Int(framesPerSecond.rounded())) fps · \((bitsPerSecond / 1e6).formatted(.number.precision(.fractionLength(1)))) Mbit/s"
    }
}

/// Measures `StreamStats` over one-second windows of `CLOCK_UPTIME_RAW` time, fed by the pipeline
/// from the session's authentic host datagrams. One per session. Connection quality is the worse
/// of two losses over the last window: `STATUS` datagrams missing from the `status_seq` run (the
/// host numbers every one it sends, vcp.md §6.4), and viewfinder frames abandoned incomplete. It
/// is poor at once when nothing has come from the host for more than a second (STATUS is 2 Hz,
/// and the host marks a silent device stale after the same second, §8).
nonisolated struct StreamMeter: Sendable {
    static let windowNs: UInt64 = 1_000_000_000
    /// Longest host silence that still counts as connected well.
    static let silenceNs: UInt64 = 1_000_000_000
    /// Loss at or above which quality drops to fair, and to poor.
    static let fairLoss = 0.02
    static let poorLoss = 0.10

    private var windowStartNs: UInt64
    private var lastHostNs: UInt64
    private var bytes: UInt64 = 0
    private var lastStatusSeq: UInt32?
    private var statusExpected: UInt64 = 0
    private var statusReceived: UInt64 = 0
    private var framesAtStart: (complete: UInt64, lost: UInt64) = (0, 0)
    private var windowQuality = ConnectionQuality.good
    private var rates: (fps: Double, bps: Double)?

    /// `nowNs` is the session's start; the first second of silence is counted from here.
    init(nowNs: UInt64) {
        windowStartNs = nowNs
        lastHostNs = nowNs
    }

    /// Any authentic host datagram.
    mutating func hostDatagram(atNs nowNs: UInt64) {
        lastHostNs = max(lastHostNs, nowNs)
    }

    /// A `STATUS` the sequence filter accepted (higher than every earlier one).
    mutating func status(seq: UInt32) {
        if let last = lastStatusSeq, seq > last {
            statusExpected += UInt64(seq - last)
            statusReceived += 1
        }
        lastStatusSeq = seq
    }

    /// The data bytes of an authentic `VIDEO_FRAGMENT`, whatever reassembly made of it.
    mutating func fragment(bytes count: Int) {
        bytes += UInt64(count)
    }

    /// Closes every window that has ended by `nowNs`, given the reassembler's session totals, and
    /// returns the stats of the last one: nil until a full window has passed.
    mutating func stats(atNs nowNs: UInt64, framesComplete: UInt64, framesLost: UInt64) -> StreamStats? {
        if nowNs >= windowStartNs, nowNs - windowStartNs >= Self.windowNs {
            let seconds = Double(nowNs - windowStartNs) / 1e9
            let complete = framesComplete - framesAtStart.complete
            let lost = framesLost - framesAtStart.lost
            rates = (Double(complete) / seconds, Double(bytes * 8) / seconds)
            let frameLoss = complete + lost > 0 ? Double(lost) / Double(complete + lost) : 0
            let statusLoss = statusExpected > 0 ? Double(statusExpected - statusReceived) / Double(statusExpected) : 0
            let loss = max(frameLoss, statusLoss)
            windowQuality = loss >= Self.poorLoss ? .poor : loss >= Self.fairLoss ? .fair : .good
            windowStartNs = nowNs
            bytes = 0
            statusExpected = 0
            statusReceived = 0
            framesAtStart = (framesComplete, framesLost)
        }
        guard let rates else { return nil }
        let silent = nowNs > lastHostNs && nowNs - lastHostNs > Self.silenceNs
        return StreamStats(framesPerSecond: rates.fps, bitsPerSecond: rates.bps,
                           quality: silent ? .poor : windowQuality)
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
