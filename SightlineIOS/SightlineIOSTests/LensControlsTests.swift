import XCTest

/// The phone's lens request (FR-CTL-001..003, FR-CTL-009): absolute values clamped to the vcp.md
/// §6.2 ranges, tap and rack identities that wrap, and adoption of the camera's applied lens.
final class LensControlsTests: XCTestCase {
    func testValuesAreClampedToTheWireRangesAndNonNumbersIgnored() {
        var lens = LensControls()
        XCTAssertNil(lens.lensMM)
        lens.setLens(0.2)
        XCTAssertEqual(lens.lensMM, 1)
        lens.setLens(9000)
        XCTAssertEqual(lens.lensMM, 2500)
        lens.setLens(85)
        lens.setLens(.nan)
        lens.setLens(.infinity)
        XCTAssertEqual(lens.lensMM, 85, "a non-number leaves the value alone")

        lens.setFocus(0)
        XCTAssertEqual(lens.focusDistanceM, 0.01)
        lens.setFocus(1e9)
        XCTAssertEqual(lens.focusDistanceM, 100_000)
        lens.setFocus(-.infinity)
        XCTAssertEqual(lens.focusDistanceM, 100_000)

        lens.setFstop(0.01)
        XCTAssertEqual(lens.fstop, 0.1)
        lens.setFstop(500)
        XCTAssertEqual(lens.fstop, 128)

        lens.setMark(VCPRackFocus.targetA, to: -3)
        lens.setMark(VCPRackFocus.targetB, to: 2e5)
        lens.setMark(VCPRackFocus.targetNone, to: 5)
        XCTAssertEqual(lens.markA, 0.01)
        XCTAssertEqual(lens.markB, 100_000)
        XCTAssertTrue(lens.rack.isValid)

        XCTAssertTrue(lens.tap(u: -1, v: 2))
        XCTAssertEqual(lens.tap, VCPTapFocus(u: 0, v: 1, seq: 1))
        XCTAssertFalse(lens.tap(u: .nan, v: 0.5))
        XCTAssertEqual(lens.tap.seq, 1, "a rejected tap isn't a request")

        var state = VCPControlState(stateSeq: 1, motionScale: nil, lockFlags: nil, originEpoch: nil)
        lens.fill(&state)
        XCTAssertNoThrow(try VCPMessage.controlState(state).payloadForTest(), "clamped values always seal")
    }

    func testTapAndRackIdentitiesStepAndWrap() {
        var lens = LensControls()
        XCTAssertEqual(lens.tap.seq, 0)
        lens.tap(u: 0.5, v: 0.5)
        lens.tap(u: 0.5, v: 0.5)
        XCTAssertEqual(lens.tap.seq, 2, "the same point tapped again is a new request")
        for _ in 0..<(65_535 - 2) { lens.tap(u: 0.1, v: 0.2) }
        XCTAssertEqual(lens.tap.seq, 65_535)
        lens.tap(u: 0.3, v: 0.4)
        XCTAssertEqual(lens.tap, VCPTapFocus(u: 0.3, v: 0.4, seq: 0), "tap_seq wraps 65535 → 0")

        XCTAssertFalse(lens.startRack(to: VCPRackFocus.targetB, durationMS: 1000), "B isn't set")
        XCTAssertEqual(lens.rack.seq, 0)
        XCTAssertEqual(lens.rack.target, VCPRackFocus.targetNone)
        XCTAssertEqual(lens.rack.aM, LensControls.unsetMarkM)
        lens.setMark(VCPRackFocus.targetA, to: 2)
        lens.setMark(VCPRackFocus.targetB, to: 6)
        XCTAssertFalse(lens.startRack(to: VCPRackFocus.targetNone, durationMS: 1000))
        XCTAssertTrue(lens.startRack(to: VCPRackFocus.targetB, durationMS: 90_000))
        XCTAssertEqual(lens.rack, VCPRackFocus(aM: 2, bM: 6, target: 2, durationMS: 60_000, seq: 1))
        XCTAssertTrue(lens.startRack(to: VCPRackFocus.targetA, durationMS: -5))
        XCTAssertEqual(lens.rack, VCPRackFocus(aM: 2, bM: 6, target: 1, durationMS: 0, seq: 2))
        XCTAssertTrue(lens.startRack(to: VCPRackFocus.targetA, durationMS: 800))
        XCTAssertEqual(lens.rack.seq, 3, "racking to the same mark again is a new request")
        XCTAssertEqual(lens.tap.seq, 0, "a rack doesn't touch the tap identity")
        lens.setMark(VCPRackFocus.targetA, to: 3)
        XCTAssertEqual(lens.rack.seq, 3, "moving a mark isn't a rack")
    }

    func testAdoptFillsOnlyUnsetValues() {
        let camera = VCPAppliedLens(
            lensMM: 24, focusDistanceM: 10, fstop: 2.8, dofOn: false, sensorFit: 0, sensorWidthMM: 36,
            renderAspect: 16 / 9)
        var lens = LensControls()
        lens.setFstop(8)
        XCTAssertTrue(lens.adopt(camera))
        XCTAssertEqual(lens.lensMM, 24)
        XCTAssertEqual(lens.focusDistanceM, 10)
        XCTAssertEqual(lens.fstop, 8, "the operator's own value stays")
        XCTAssertEqual(lens.dofOn, false)

        var edited = camera
        edited.lensMM = 60
        edited.dofOn = true
        XCTAssertFalse(lens.adopt(edited), "a later host-side edit doesn't become the phone's request")
        XCTAssertEqual(lens.lensMM, 24)
        XCTAssertEqual(lens.dofOn, false)
        XCTAssertFalse(lens.adopt(camera))
    }
}

extension VCPMessage {
    /// Seals with a throwaway session, for tests that only need to know it encodes.
    fileprivate func payloadForTest() throws {
        let key = [UInt8](repeating: 7, count: 32)
        let device = VCPEndpoint(role: .device, sessionID: 1, kD2H: key, kH2D: key)!
        _ = try device.seal(self)
    }
}
