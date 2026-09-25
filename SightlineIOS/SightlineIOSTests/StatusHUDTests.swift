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
