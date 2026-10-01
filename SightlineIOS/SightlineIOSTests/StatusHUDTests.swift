import CoreGraphics
import Foundation
import XCTest

/// The landscape status screen's logic (task 1.4.5; FR-UX-003/004).
final class StatusHUDTests: XCTestCase {
    private static let frameNs: UInt64 = 16_666_667  // 60 Hz

    func testStreamWindowCountsFramesAndFragmentDataWithoutDoubleCounting() throws {
        var meter = StreamMeter(startNs: 0)
        XCTAssertNil(meter.snapshot(atNs: 999_999_999, complete: 0, lost: 0))
        for _ in 0..<30 {
            meter.hostDatagram(atNs: 900_000_000)
            meter.fragment(dataBytes: 12_000)
            meter.fragment(dataBytes: 8_000)
        }
        let first = try XCTUnwrap(meter.snapshot(atNs: 1_000_000_000, complete: 30, lost: 0))
        XCTAssertEqual(first.framesPerSecond, 30, accuracy: 0.001)
        XCTAssertEqual(first.megabitsPerSecond, 4.8, accuracy: 0.001)
        XCTAssertEqual(first.label, "30 fps · 4.8 Mbit/s")
        XCTAssertEqual(first.quality, .good)
        // An idle second clears the old window, rather than reporting a lifetime average.
        let second = try XCTUnwrap(meter.snapshot(atNs: 2_000_000_000, complete: 30, lost: 0))
        XCTAssertEqual(second.framesPerSecond, 0)
        XCTAssertEqual(second.megabitsPerSecond, 0)
    }

    func testQualityThresholdBoundariesAndWorseLossSource() throws {
        let samples: [(Int, ConnectionQuality)] = [
            (199, .good), (200, .fair), (999, .fair), (1000, .poor),
        ]
        for (missing, expected) in samples {
            var statusMeter = StreamMeter(startNs: 0)
            statusMeter.status(seq: 1)
            for seq in 2...(10_000 - missing) {
                statusMeter.status(seq: UInt32(seq))
            }
            statusMeter.status(seq: 10_001)
            statusMeter.hostDatagram(atNs: 1_000_000_000)
            XCTAssertEqual(
                statusMeter.snapshot(atNs: 1_000_000_000, complete: 100, lost: 0)?.quality,
                expected, "STATUS \(missing) of 10000")

            var videoMeter = StreamMeter(startNs: 0)
            videoMeter.status(seq: 1)
            videoMeter.status(seq: 2)  // good STATUS cannot hide worse frame loss
            videoMeter.hostDatagram(atNs: 1_000_000_000)
            XCTAssertEqual(
                videoMeter.snapshot(
                    atNs: 1_000_000_000, complete: UInt64(10_000 - missing), lost: UInt64(missing)
                )?.quality,
                expected, "frames \(missing) of 10000")
        }
    }

    func testSilenceTurnsPoorOnlyAfterOneSecondAndRecovers() throws {
        var meter = StreamMeter(startNs: 0)
        meter.hostDatagram(atNs: 1_000_000_000)
        XCTAssertEqual(meter.snapshot(atNs: 1_000_000_000, complete: 1, lost: 0)?.quality, .good)
        XCTAssertEqual(meter.snapshot(atNs: 2_000_000_000, complete: 1, lost: 0)?.quality, .good)
        XCTAssertEqual(meter.snapshot(atNs: 2_000_000_001, complete: 1, lost: 0)?.quality, .poor)
        meter.hostDatagram(atNs: 2_000_000_002)
        XCTAssertEqual(meter.snapshot(atNs: 2_000_000_002, complete: 1, lost: 0)?.quality, .good)
    }

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
        XCTAssertTrue(
            chrome.isShown(at: later.advanced(by: .seconds(60)), tracking: false),
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
        XCTAssertTrue(
            chrome.isShown(at: t2.advanced(by: .milliseconds(3999)), tracking: true),
            "showing again restarts the delay")

        // Not tracking: a tap doesn't hide anything, now or once tracking starts.
        var idle = ChromeVisibility(now: t0)
        idle.tapFrame(at: t1, tracking: false)
        XCTAssertTrue(idle.isShown(at: t1, tracking: true))
    }

    func testControlsAndStatusNeverCoverTheCentre() {
        let sizes = [
            CGSize(width: 874, height: 402),  // iPhone 17 Pro landscape
            CGSize(width: 667, height: 375),  // iPhone SE landscape
            CGSize(width: 1376, height: 1032),  // iPad Pro 13" landscape
            CGSize(width: 1032, height: 1376),  // iPad Pro 13" portrait
            CGSize(width: 320, height: 180),  // a small split-view window
        ]
        for size in sizes {
            let layout = HUDLayout(size: size)
            XCTAssertEqual(layout.centre.width, size.width / 2)
            XCTAssertEqual(layout.centre.height, size.height / 2)
            XCTAssertFalse(layout.controlRail.intersects(layout.centre), "rail at \(size)")
            XCTAssertFalse(layout.statusStrip.intersects(layout.centre), "strip at \(size)")
            XCTAssertFalse(layout.dataPanel.intersects(layout.centre), "HUD data at \(size)")
            XCTAssertFalse(layout.dataPanel.intersects(layout.controlRail), "HUD avoids controls at \(size)")
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

    func testPanelContainerAvoidsDisplayedPictureCentreEvenWithSafeAreaInsetsAndMask() throws {
        let viewport = CGSize(width: 874, height: 402)
        let frame = CGSize(width: 960, height: 540)
        for mask in [nil, 2.39, 1.33] as [Double?] {
            let geometry = try XCTUnwrap(FramingGeometry(frame: frame, view: viewport, maskAspect: mask))
            // The GeometryReader inside the safe area has less room than the full-screen Metal view.
            let inset = CGRect(x: 59, y: 0, width: 756, height: 381)
            let layout = HUDLayout(
                size: inset.size, picture: geometry.picture.offsetBy(dx: -inset.minX, dy: 0),
                viewfinder: CGRect(x: -inset.minX, y: 0, width: viewport.width, height: viewport.height))
            let pictureCentre = geometry.picture.insetBy(
                dx: geometry.picture.width / 4, dy: geometry.picture.height / 4)
            XCTAssertFalse(
                layout.dataPanel.offsetBy(dx: inset.minX, dy: inset.minY).intersects(pictureCentre),
                "panel background overlaps centre for mask \(String(describing: mask))")
            XCTAssertFalse(
                layout.dataPanel.offsetBy(dx: inset.minX, dy: inset.minY).intersects(
                    CGRect(origin: .zero, size: viewport).insetBy(dx: viewport.width / 4, dy: viewport.height / 4)),
                "panel background overlaps full viewfinder centre")
            XCTAssertLessThanOrEqual(layout.dataPanel.maxY, inset.height)
            XCTAssertEqual(layout.dataPanel.minY, viewport.height * 0.75, accuracy: 0.01)
        }
    }

    func testDisplayedFrameLevelAndUnavailableFields() {
        XCTAssertEqual(HUDFields.level(quality: 70, size: CGSize(width: 960, height: 540)), "q70 · 960×540")
        XCTAssertEqual(HUDFields.level(quality: 50, size: CGSize(width: 640, height: 360)), "q50 · 640×360")
        XCTAssertEqual(HUDFields.level(quality: 0, size: CGSize(width: 960, height: 540)), "q— · 960×540")
        XCTAssertEqual(HUDFields.lens, "Focal — · Focus — · f/—")
        XCTAssertEqual(HUDFields.m2p, "—")
        XCTAssertEqual(HUDFields.recording, "Recording: not available (T3)")
        XCTAssertEqual(HUDFields.tracking(running: false, state: 5), "Stopped")
        XCTAssertEqual(HUDFields.tracking(running: true, state: nil), "Starting")
        XCTAssertEqual(HUDFields.tracking(running: true, state: 0), "Tracking unavailable")
        XCTAssertEqual(HUDFields.tracking(running: true, state: 2), "Tracking limited")
        XCTAssertEqual(HUDFields.tracking(running: true, state: VCPPose.trackingNormal), "Tracking")
    }
}
