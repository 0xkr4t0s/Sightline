import CoreGraphics
import Foundation
import XCTest

/// The landscape status screen's logic (task 1.4.5; FR-UX-003/004).
final class StatusHUDTests: XCTestCase {
    private static let frameNs: UInt64 = 16_666_667  // 60 Hz

    func testRateCountsEveryPoseEvenWhenTheUISeesOnlySome() throws {
        var meter = PoseRateMeter()
        // ARKit at 60 Hz; the ≤ 15 Hz UI throttle hands over every 4th pose.
        for seq in stride(from: UInt32(1), through: 57, by: 4) {
            meter.add(seq: seq, captureTimeNs: UInt64(seq) * Self.frameNs)
        }
        XCTAssertNil(meter.rate, "no rate before a full second of capture time")
        meter.add(seq: 61, captureTimeNs: 61 * Self.frameNs)
        XCTAssertEqual(try XCTUnwrap(meter.rate), 60, accuracy: 0.01)

        // Tracking slows to 30 Hz; the next window reports it.
        var seq: UInt32 = 61
        var time = 61 * Self.frameNs
        for _ in 0..<16 {
            seq += 2
            time += 4 * Self.frameNs
            meter.add(seq: seq, captureTimeNs: time)
        }
        XCTAssertEqual(try XCTUnwrap(meter.rate), 30, accuracy: 0.01)
    }

    func testRateStartsOverOnANewRunOrClock() {
        var meter = PoseRateMeter()
        meter.add(seq: 100, captureTimeNs: 5_000_000_000)
        meter.add(seq: 160, captureTimeNs: 6_000_000_000)
        XCTAssertNotNil(meter.rate)

        // seq restarts at 1 each run: the old anchor must not produce a bogus rate.
        meter.add(seq: 1, captureTimeNs: 9_000_000_000)
        XCTAssertNil(meter.rate)
        meter.add(seq: 61, captureTimeNs: 10_000_000_000)
        XCTAssertEqual(meter.rate ?? 0, 60, accuracy: 0.01)

        // A new AR session can restart the capture clock.
        meter.add(seq: 70, captureTimeNs: 1_000_000)
        XCTAssertNil(meter.rate)
    }

    private static let second: UInt64 = 1_000_000_000

    /// FR-VF-004: frames completed and video bits received per second of the last full window;
    /// nothing until one has passed, and each window counts only its own frames and bytes.
    func testStreamRatesPerWindow() throws {
        var meter = StreamMeter(nowNs: 5 * Self.second)
        for _ in 0..<30 {
            meter.hostDatagram(atNs: 5 * Self.second + 500_000_000)
            meter.fragment(bytes: 50_000)
        }
        XCTAssertNil(meter.stats(atNs: 6 * Self.second - 1, framesComplete: 30, framesLost: 0),
                     "no rate before a full second")
        var stats = try XCTUnwrap(meter.stats(atNs: 6 * Self.second, framesComplete: 30, framesLost: 0))
        XCTAssertEqual(stats.framesPerSecond, 30)
        XCTAssertEqual(stats.bitsPerSecond, 12_000_000)
        XCTAssertEqual(stats.quality, .good)
        XCTAssertEqual(stats.label, "30 fps · 12.0 Mbit/s")

        // Mid-window the last window's stats stay; a 2 s window with 12 more frames gives 6 fps.
        meter.hostDatagram(atNs: 7 * Self.second)
        meter.fragment(bytes: 300_000)
        XCTAssertEqual(meter.stats(atNs: 7 * Self.second - 1, framesComplete: 36, framesLost: 0), stats)
        stats = try XCTUnwrap(meter.stats(atNs: 8 * Self.second, framesComplete: 42, framesLost: 0))
        XCTAssertEqual(stats.framesPerSecond, 6)
        XCTAssertEqual(stats.bitsPerSecond, 1_200_000)

        // The stream stops: the next window says so.
        meter.hostDatagram(atNs: 9 * Self.second)
        stats = try XCTUnwrap(meter.stats(atNs: 9 * Self.second, framesComplete: 42, framesLost: 0))
        XCTAssertEqual(stats.framesPerSecond, 0)
        XCTAssertEqual(stats.bitsPerSecond, 0)
        XCTAssertEqual(StreamStats(framesPerSecond: 23.6, bitsPerSecond: 6_140_000, quality: .fair).label,
                       "24 fps · 6.1 Mbit/s")
    }

    /// Quality is the worse of STATUS loss (gaps in `status_seq`) and viewfinder frames lost, per
    /// window: under 2 % good, under 10 % fair, else poor.
    func testConnectionQualityFromLoss() throws {
        func quality(statusSeqs: [UInt32], complete: UInt64, lost: UInt64) throws -> ConnectionQuality {
            var meter = StreamMeter(nowNs: 0)
            meter.hostDatagram(atNs: Self.second)
            for seq in statusSeqs { meter.status(seq: seq) }
            return try XCTUnwrap(meter.stats(atNs: Self.second, framesComplete: complete, framesLost: lost)).quality
        }
        // The first STATUS has nothing before it: starting at 7 isn't loss.
        XCTAssertEqual(try quality(statusSeqs: Array(7...8), complete: 0, lost: 0), .good)
        // 100 expected after the first; 1, 2, 9 and 10 missing.
        XCTAssertEqual(try quality(statusSeqs: Array(0...100).filter { $0 != 50 }, complete: 0, lost: 0), .good)
        XCTAssertEqual(try quality(statusSeqs: Array(0...100).filter { $0 != 50 && $0 != 60 }, complete: 0,
                                   lost: 0), .fair)
        XCTAssertEqual(try quality(statusSeqs: Array(0...100).filter { $0 % 10 != 5 || $0 == 95 }, complete: 0,
                                   lost: 0), .fair, "9 %")
        XCTAssertEqual(try quality(statusSeqs: Array(0...100).filter { $0 % 10 != 5 }, complete: 0, lost: 0), .poor)
        // Frames: 1, 2 and 10 of 100 lost.
        XCTAssertEqual(try quality(statusSeqs: [], complete: 99, lost: 1), .good)
        XCTAssertEqual(try quality(statusSeqs: [], complete: 98, lost: 2), .fair)
        XCTAssertEqual(try quality(statusSeqs: [], complete: 90, lost: 10), .poor)
        // The worse of the two counts.
        XCTAssertEqual(try quality(statusSeqs: Array(0...100).filter { $0 % 10 != 5 }, complete: 100, lost: 0), .poor)
        XCTAssertEqual(try quality(statusSeqs: Array(0...100), complete: 90, lost: 10), .poor)

        // Loss is per window: a clean window after a lossy one is good again.
        var meter = StreamMeter(nowNs: 0)
        meter.hostDatagram(atNs: Self.second)
        XCTAssertEqual(meter.stats(atNs: Self.second, framesComplete: 90, framesLost: 10)?.quality, .poor)
        meter.hostDatagram(atNs: 2 * Self.second)
        XCTAssertEqual(meter.stats(atNs: 2 * Self.second, framesComplete: 190, framesLost: 10)?.quality, .good)
    }

    /// More than a second without an authentic host datagram is poor at once, between windows too,
    /// and the next datagram ends it.
    func testHostSilenceIsPoorAtOnce() {
        var meter = StreamMeter(nowNs: 0)
        meter.hostDatagram(atNs: Self.second)
        XCTAssertEqual(meter.stats(atNs: Self.second, framesComplete: 0, framesLost: 0)?.quality, .good)
        XCTAssertEqual(meter.stats(atNs: 2 * Self.second, framesComplete: 0, framesLost: 0)?.quality, .good,
                       "exactly one second is still fine")
        XCTAssertEqual(meter.stats(atNs: 2 * Self.second + 1, framesComplete: 0, framesLost: 0)?.quality, .poor)
        meter.hostDatagram(atNs: 2 * Self.second + 2)
        XCTAssertEqual(meter.stats(atNs: 2 * Self.second + 3, framesComplete: 0, framesLost: 0)?.quality, .good)

        // A session whose host never answers: silence counts from the start.
        var silent = StreamMeter(nowNs: 10 * Self.second)
        XCTAssertEqual(silent.stats(atNs: 11 * Self.second + 1, framesComplete: 0, framesLost: 0)?.quality, .poor)
    }

    func testThermalLabelsAndWarning() {
        let expected: [(ProcessInfo.ThermalState, String, Bool)] = [
            (.nominal, "Normal", false),
            (.fair, "Fair", false),
            (.serious, "Serious", true),
            (.critical, "Critical", true),
        ]
        for (state, label, warning) in expected {
            let status = ThermalStatus(state: state)
            XCTAssertEqual(status.label, label)
            XCTAssertEqual(status.isWarning, warning, "FR-UX-004 acts from .serious on: \(label)")
        }
    }

    func testControlsAutoHideWhileTrackingOnly() {
        let t0 = ContinuousClock.now
        var chrome = ChromeVisibility(now: t0)
        let almost = t0.advanced(by: .milliseconds(3999))
        let later = t0.advanced(by: ChromeVisibility.hideAfter)

        XCTAssertTrue(chrome.isShown(at: almost, tracking: true))
        XCTAssertFalse(chrome.isShown(at: later, tracking: true), "hidden after the delay")
        XCTAssertTrue(chrome.isShown(at: later.advanced(by: .seconds(60)), tracking: false),
                      "Start stays reachable while not tracking")

        chrome.interact(at: almost)
        XCTAssertTrue(chrome.isShown(at: later, tracking: true), "a control use restarts the delay")
        XCTAssertFalse(chrome.isShown(at: almost.advanced(by: ChromeVisibility.hideAfter), tracking: true))
    }

    func testTapOnTheFrameTogglesTheControls() {
        let t0 = ContinuousClock.now
        var chrome = ChromeVisibility(now: t0)
        let t1 = t0.advanced(by: .seconds(1))

        chrome.tapFrame(at: t1, tracking: true)
        XCTAssertFalse(chrome.isShown(at: t1, tracking: true), "a tap hides shown controls at once")

        let t2 = t1.advanced(by: .seconds(1))
        chrome.tapFrame(at: t2, tracking: true)
        XCTAssertTrue(chrome.isShown(at: t2, tracking: true))
        XCTAssertTrue(chrome.isShown(at: t2.advanced(by: .milliseconds(3999)), tracking: true),
                      "showing again restarts the delay")

        // Not tracking: a tap doesn't hide anything, now or once tracking starts.
        var idle = ChromeVisibility(now: t0)
        idle.tapFrame(at: t1, tracking: false)
        XCTAssertTrue(idle.isShown(at: t1, tracking: true))
    }

    func testControlsAndStatusNeverCoverTheCentre() {
        let sizes = [
            CGSize(width: 874, height: 402),   // iPhone 17 Pro landscape
            CGSize(width: 667, height: 375),   // iPhone SE landscape
            CGSize(width: 1376, height: 1032), // iPad Pro 13" landscape
            CGSize(width: 1032, height: 1376), // iPad Pro 13" portrait
            CGSize(width: 320, height: 180),   // a small split-view window
        ]
        for size in sizes {
            let layout = HUDLayout(size: size)
            XCTAssertEqual(layout.centre.width, size.width / 2)
            XCTAssertEqual(layout.centre.height, size.height / 2)
            XCTAssertFalse(layout.controlRail.intersects(layout.centre), "rail at \(size)")
            XCTAssertFalse(layout.statusStrip.intersects(layout.centre), "strip at \(size)")
            // Edges: strip along the top, rail along the trailing edge below it.
            XCTAssertEqual(layout.statusStrip.minY, 0)
            XCTAssertEqual(layout.statusStrip.width, size.width)
            XCTAssertEqual(layout.controlRail.maxX, size.width)
            XCTAssertEqual(layout.controlRail.minY, layout.statusStrip.maxY)
            XCTAssertEqual(layout.controlRail.maxY, size.height)
        }
        let phone = HUDLayout(size: sizes[0])
        XCTAssertEqual(phone.controlRail.width, HUDLayout.railWidth, "full-size rail on a phone")
        XCTAssertEqual(phone.statusStrip.height, HUDLayout.statusHeight)
    }
}
