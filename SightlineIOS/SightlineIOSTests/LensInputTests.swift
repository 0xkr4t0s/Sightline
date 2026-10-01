import XCTest

/// The on-screen lens controls (FR-CTL-001..003): viewfinder taps mapped into the streamed picture,
/// the focal and focus scales, the aperture and rack-duration steps, and what the lens panel shows.
final class LensInputTests: XCTestCase {
    /// VAL-LENSI-009: (u, v) are relative to the displayed picture, not the view; bars give nil.
    func testTapIsNormalizedInsideThePictureAndIgnoredInTheBars() throws {
        // A 960×540 stream on an 874×402 screen: pillar bars left and right.
        let pillar = try XCTUnwrap(
            FramingGeometry(
                frame: CGSize(width: 960, height: 540), view: CGSize(width: 874, height: 402), maskAspect: nil)
        ).image
        XCTAssertEqual(pillar.minX, (874 - 402 * 16 / 9) / 2, accuracy: 0.01)
        let centre = try XCTUnwrap(LensInput.pictureTap(at: CGPoint(x: 437, y: 201), image: pillar))
        XCTAssertEqual(centre.u, 0.5, accuracy: 1e-5)
        XCTAssertEqual(centre.v, 0.5, accuracy: 1e-5)
        let topLeft = try XCTUnwrap(LensInput.pictureTap(at: pillar.origin, image: pillar))
        XCTAssertEqual(topLeft.u, 0)
        XCTAssertEqual(topLeft.v, 0)
        let quarter = try XCTUnwrap(
            LensInput.pictureTap(
                at: CGPoint(x: pillar.minX + pillar.width / 4, y: pillar.minY + pillar.height * 0.9), image: pillar))
        XCTAssertEqual(quarter.u, 0.25, accuracy: 1e-5, "u is measured in the picture, not the view")
        XCTAssertEqual(quarter.v, 0.9, accuracy: 1e-5, "v runs from the top of the picture")
        XCTAssertNil(LensInput.pictureTap(at: CGPoint(x: 20, y: 201), image: pillar), "left bar")
        XCTAssertNil(LensInput.pictureTap(at: CGPoint(x: pillar.maxX + 1, y: 201), image: pillar), "right bar")

        // A 2.39 stream: letterbox bars top and bottom.
        let letterbox = try XCTUnwrap(
            FramingGeometry(
                frame: CGSize(width: 960, height: 402), view: CGSize(width: 874, height: 402), maskAspect: nil)
        ).image
        XCTAssertGreaterThan(letterbox.minY, 10)
        XCTAssertNil(LensInput.pictureTap(at: CGPoint(x: 437, y: 5), image: letterbox), "top bar")
        XCTAssertNil(LensInput.pictureTap(at: CGPoint(x: 437, y: 400), image: letterbox), "bottom bar")
        let low = try XCTUnwrap(LensInput.pictureTap(at: CGPoint(x: 437, y: letterbox.maxY - 1), image: letterbox))
        XCTAssertEqual(low.v, Float((letterbox.height - 1) / letterbox.height), accuracy: 1e-5)
        XCTAssertNil(LensInput.pictureTap(at: CGPoint(x: 1, y: 1), image: .zero), "no picture")
    }

    func testFocalSliderIsLogarithmicAndPinchScalesTheFocalLength() {
        XCTAssertEqual(LensInput.focalPosition(12), 0, accuracy: 1e-9)
        XCTAssertEqual(LensInput.focalPosition(300), 1, accuracy: 1e-9)
        XCTAssertEqual(LensInput.focalPosition(60), 0.5, accuracy: 1e-9, "the geometric middle of 12…300 mm")
        XCTAssertEqual(LensInput.focalPosition(5), 0, "below the range")
        XCTAssertEqual(LensInput.focal(atPosition: 0.5), 60)
        XCTAssertEqual(LensInput.focal(atPosition: -1), 12)
        XCTAssertEqual(LensInput.focal(atPosition: 2), 300)
        for prime in LensInput.primesMM {
            XCTAssertEqual(LensInput.focal(atPosition: LensInput.focalPosition(prime)), prime, "prime \(prime)")
        }
        // Pinching out zooms in (longer lens), whole millimetres, within the slider's range.
        XCTAssertEqual(LensInput.pinch(from: 50, magnification: 2), 100)
        XCTAssertEqual(LensInput.pinch(from: 50, magnification: 0.5), 25)
        XCTAssertEqual(LensInput.pinch(from: 35, magnification: 1.1), 39)
        XCTAssertEqual(LensInput.pinch(from: 200, magnification: 3), 300)
        XCTAssertEqual(LensInput.pinch(from: 18, magnification: 0.2), 12)
        XCTAssertEqual(LensInput.pinch(from: 50, magnification: .nan), 50)
    }

    func testFocusWheelDoublesPerDragStepAndClamps() {
        let step = CGFloat(LensInput.wheelPointsPerDoubling)
        XCTAssertEqual(LensInput.wheel(from: 2, dragX: 0), 2)
        XCTAssertEqual(LensInput.wheel(from: 2, dragX: -step), 4, "drag left: farther marks come under the index")
        XCTAssertEqual(LensInput.wheel(from: 2, dragX: step), 1)
        XCTAssertEqual(LensInput.wheel(from: 1.5, dragX: -step / 2), 2.12, "centimetres")
        XCTAssertEqual(LensInput.wheel(from: 2, dragX: 20 * step), LensInput.focusRange.lowerBound)
        XCTAssertEqual(LensInput.wheel(from: 2, dragX: -20 * step), LensInput.focusRange.upperBound)
        XCTAssertEqual(LensInput.wheelStep(from: 2, farther: true), 2.38)
        XCTAssertEqual(LensInput.wheelStep(from: 2, farther: false), 1.68)
        XCTAssertEqual(LensInput.wheelStep(from: 100, farther: true), 100)
    }

    func testApertureAndRackDurationStepThroughTheirSeries() {
        XCTAssertEqual(LensInput.aperture(from: 2.8, wider: true), 2)
        XCTAssertEqual(LensInput.aperture(from: 2.8, wider: false), 4)
        XCTAssertEqual(LensInput.aperture(from: 3.2, wider: true), 2.8, "off the series: nearest stop that way")
        XCTAssertEqual(LensInput.aperture(from: 3.2, wider: false), 4)
        XCTAssertEqual(LensInput.aperture(from: 1.4, wider: true), 1.4)
        XCTAssertEqual(LensInput.aperture(from: 22, wider: false), 22)
        XCTAssertEqual(LensInput.aperture(from: 0.95, wider: false), 1.4)
        XCTAssertEqual(LensInput.aperture(from: Float(2.8).nextUp, wider: true), 2, "float noise from Blender")

        XCTAssertEqual(LensInput.rackDuration(from: 2000, longer: true), 3000)
        XCTAssertEqual(LensInput.rackDuration(from: 2000, longer: false), 1000)
        XCTAssertEqual(LensInput.rackDuration(from: 0, longer: false), 0)
        XCTAssertEqual(LensInput.rackDuration(from: 8000, longer: true), 8000)
        XCTAssertEqual(LensInput.rackDuration(from: 1500, longer: true), 2000)
    }

    func testRackGoesToTheMarkFartherFromTheCurrentFocus() {
        let a = VCPRackFocus.targetA
        let b = VCPRackFocus.targetB
        XCTAssertEqual(LensInput.rackTarget(focus: 1, markA: 1, markB: 5), b)
        XCTAssertEqual(LensInput.rackTarget(focus: 5, markA: 1, markB: 5), a)
        XCTAssertEqual(LensInput.rackTarget(focus: 2.9, markA: 1, markB: 5), b)
        XCTAssertEqual(LensInput.rackTarget(focus: nil, markA: 1, markB: 5), b)
        XCTAssertEqual(LensInput.rackTarget(focus: 5, markA: 1, markB: nil), a, "the only mark")
        XCTAssertEqual(LensInput.rackTarget(focus: 1, markA: nil, markB: 5), b)
        XCTAssertNil(LensInput.rackTarget(focus: 1, markA: nil, markB: nil))
    }

    private func applied(lens: Float = 24, focus: Float = 3, fstop: Float = 2.8, dof: Bool = false) -> VCPAppliedLens {
        VCPAppliedLens(
            lensMM: lens, focusDistanceM: focus, fstop: fstop, dofOn: dof, sensorFit: 0, sensorWidthMM: 36,
            renderAspect: 16 / 9)
    }

    /// The panel shows the camera's lens, except a value the operator just set that STATUS doesn't
    /// show yet; after a tap or rack the host owns the focus again.
    func testPanelShowsTheCameraUnlessTheOperatorsChangeIsStillOnItsWay() {
        var panel = LensPanelModel()
        var lens = LensControls()
        XCTAssertEqual(panel.shown(lens, applied: nil), LensValues(lensMM: nil, focusM: nil, fstop: nil, dofOn: nil))
        let camera = applied()
        lens.adopt(camera)
        XCTAssertEqual(panel.shown(lens, applied: camera), LensValues(lensMM: 24, focusM: 3, fstop: 2.8, dofOn: false))

        panel.setLens(85, &lens)
        panel.setFocus(1.5, &lens)
        panel.setFstop(2, &lens)
        panel.setDoF(true, &lens)
        XCTAssertEqual(lens.lensMM, 85)
        XCTAssertEqual(lens.dofOn, true)
        XCTAssertEqual(
            panel.shown(lens, applied: camera), LensValues(lensMM: 85, focusM: 1.5, fstop: 2, dofOn: true),
            "before STATUS shows the change, the request")
        panel.statusChanged(lens, applied: applied(lens: 85, focus: 3, fstop: 2.8, dof: true))
        XCTAssertEqual(
            panel.shown(lens, applied: applied(lens: 50, focus: 3, fstop: 2.8, dof: false)),
            LensValues(lensMM: 50, focusM: 1.5, fstop: 2, dofOn: false),
            "an applied value that matched the request settles it; later host edits show")

        // A tap: the host picks the distance, so the panel follows STATUS from here on.
        XCTAssertTrue(panel.tap(u: 0.5, v: 0.5, &lens))
        XCTAssertEqual(lens.tap.seq, 1)
        XCTAssertEqual(panel.shown(lens, applied: applied(focus: 1.3)).focusM, 1.3)
        XCTAssertFalse(panel.tap(u: .nan, v: 0.5, &lens))
    }

    func testActionsFromThePanelAndTheViewfinder() {
        var panel = LensPanelModel()
        var lens = LensControls()
        let camera = applied(focus: 3)
        XCTAssertTrue(panel.perform(.lens(35), &lens, applied: camera))
        XCTAssertTrue(panel.perform(.focus(2), &lens, applied: camera))
        XCTAssertTrue(panel.perform(.fstop(4), &lens, applied: camera))
        XCTAssertTrue(panel.perform(.dof(true), &lens, applied: camera))
        XCTAssertEqual(panel.shown(lens, applied: camera), LensValues(lensMM: 35, focusM: 2, fstop: 4, dofOn: true))
        XCTAssertFalse(panel.perform(.rack, &lens, applied: camera), "no marks yet")
        XCTAssertEqual(lens.rack.seq, 0)
        XCTAssertTrue(panel.perform(.mark(VCPRackFocus.targetA), &lens, applied: camera))
        XCTAssertEqual(lens.markA, 2)
        XCTAssertTrue(panel.perform(.rackDuration(longer: true), &lens, applied: camera))
        XCTAssertEqual(panel.rackDurationMS, 3000)
        XCTAssertTrue(panel.perform(.rack, &lens, applied: camera))
        XCTAssertEqual(lens.rack.target, VCPRackFocus.targetA)
        XCTAssertEqual(lens.rack.durationMS, 3000)
        XCTAssertTrue(panel.perform(.tap(u: 0.25, v: 0.75), &lens, applied: camera))
        XCTAssertEqual(lens.tap, VCPTapFocus(u: 0.25, v: 0.75, seq: 1))
        XCTAssertFalse(panel.perform(.tap(u: .nan, v: 0), &lens, applied: camera))
        XCTAssertEqual(lens.tap.seq, 1)
    }

    func testMarksTakeTheShownFocusAndRackUsesTheChosenDuration() {
        var panel = LensPanelModel()
        var lens = LensControls()
        let camera = applied(focus: 3)
        XCTAssertFalse(panel.setMark(VCPRackFocus.targetA, &lens, applied: nil), "no focus known yet")
        XCTAssertNil(panel.rack(&lens, applied: camera), "no marks")

        XCTAssertTrue(panel.setMark(VCPRackFocus.targetB, &lens, applied: camera))
        panel.setFocus(1.2, &lens)
        XCTAssertTrue(panel.setMark(VCPRackFocus.targetA, &lens, applied: camera), "the wheel's value, not STATUS's")
        XCTAssertEqual(lens.markA, 1.2)
        XCTAssertEqual(lens.markB, 3)

        XCTAssertEqual(panel.rackDurationMS, 2000)
        panel.stepRackDuration(longer: false)
        XCTAssertEqual(panel.rackDurationMS, 1000)
        XCTAssertEqual(panel.rack(&lens, applied: camera), VCPRackFocus.targetB, "from A (1.2 m) to the farther B")
        XCTAssertEqual(lens.rack, VCPRackFocus(aM: 1.2, bM: 3, target: VCPRackFocus.targetB, durationMS: 1000, seq: 1))
        XCTAssertEqual(panel.shown(lens, applied: applied(focus: 2.2)).focusM, 2.2, "the rack moves the shown focus")
        XCTAssertEqual(panel.rack(&lens, applied: applied(focus: 3)), VCPRackFocus.targetA)
        XCTAssertEqual(lens.rack.seq, 2)
    }

    /// A pinch scales the camera's lens, so it waits for STATUS to report it; a second pinch
    /// before STATUS catches up starts from the first one's request, not the older camera value.
    func testPinchStartsFromTheShownLensOnlyOnceTheCameraIsKnown() {
        var panel = LensPanelModel()
        var lens = LensControls()
        XCTAssertNil(panel.pinchBase(lens, applied: nil), "nothing known")
        lens.setLens(35)
        XCTAssertNil(panel.pinchBase(lens, applied: nil), "an old request before STATUS would overwrite the camera")
        XCTAssertEqual(panel.pinchBase(lens, applied: applied(lens: 24)), 24, "the camera's lens")

        panel.setLens(LensInput.pinch(from: 24, magnification: 2), &lens)
        XCTAssertEqual(panel.pinchBase(lens, applied: applied(lens: 24)), 48, "no jump back to the stale 24 mm")
        panel.statusChanged(lens, applied: applied(lens: 24))
        XCTAssertEqual(panel.pinchBase(lens, applied: applied(lens: 24)), 48)
        panel.statusChanged(lens, applied: applied(lens: 48))
        XCTAssertEqual(panel.pinchBase(lens, applied: applied(lens: 48)), 48)
        XCTAssertEqual(panel.pinchBase(lens, applied: applied(lens: 60)), 60, "settled: a host edit shows")
    }
}
