import XCTest

/// Drives the app as a user would, in the Simulator. `testStatusScreenAndSettings` needs nothing
/// else; `testStreamsFromBlenderHost` runs against a Blender host started with a Sightline session
/// (`tools/mission/qa_blender.sh start`) and is skipped unless its address and pairing code are
/// passed as `TEST_RUNNER_SIGHTLINE_QA_HOST` (`127.0.0.1:47000`) and `TEST_RUNNER_SIGHTLINE_QA_CODE`
/// (the code may be left out once the app has paired with that host).
/// `tools/mission/qa_ios.sh uitest` passes both from the harness's `host.json`.
@MainActor
final class SightlineUITests: XCTestCase {
    /// Framing guides start off, whatever an earlier run saved (the argument domain wins over the
    /// app's own defaults, and isn't saved).
    private static let framingOff = [
        "-viewfinder.framing.maskAspect", "0",
        "-viewfinder.framing.thirds", "NO",
        "-viewfinder.framing.centreCross", "NO",
        "-viewfinder.framing.safeAreas", "NO",
        "-viewfinder.framing.horizon", "NO",
    ]

    /// The app is landscape-only on iPhone: with the device left in portrait, screenshots come out
    /// sideways and swipes go the wrong way.
    private func landscapeApp() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        return XCUIApplication()
    }

    func testStatusScreenAndSettings() throws {
        continueAfterFailure = false
        let app = landscapeApp()
        app.launchArguments = Self.framingOff
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft

        let status = app.staticTexts["status.session"]
        XCTAssertTrue(status.waitForExistence(timeout: 20), "status strip")
        XCTAssertTrue(app.staticTexts["status.connection"].exists)
        XCTAssertTrue(app.staticTexts["status.rate"].exists)
        XCTAssertFalse(element(app, "hud.stream").exists, "without a session there is no stream meter")
        XCTAssertFalse(element(app, "hud.quality").exists)
        let startStop = app.buttons["control.startStop"]
        XCTAssertTrue(startStop.exists)
        XCTAssertEqual(startStop.label, "Start")
        XCTAssertFalse(app.buttons["control.origin"].isEnabled, "Origin needs a run")
        let viewfinder = element(app, "viewfinder")
        XCTAssertTrue(viewfinder.exists)
        XCTAssertEqual(viewfinder.value as? String, "No video")
        XCTAssertFalse(app.descendants(matching: .any)["video.stalled"].exists)
        attachScreenshot(app, "1 status screen")

        // Without scripted motion the app uses ARKit, which the Simulator doesn't have.
        startStop.tap()
        wait(for: status, label: "Unsupported")
        XCTAssertTrue(app.staticTexts["status.error"].exists)
        attachScreenshot(app, "2 start without ARKit")

        setFraming(app, on: true)
        XCTAssertTrue(app.staticTexts["status.session"].waitForExistence(timeout: 5))
        wait(for: viewfinder, value: "No video; thirds, centre cross, horizon")
        attachScreenshot(app, "4 framing guides on")

        // Leave the saved guides as they were.
        setFraming(app, on: false)
        wait(for: viewfinder, value: "No video")
    }

    /// The pairing code is only needed while the app holds no pairing the host accepts: the host
    /// withdraws a code once a device has paired with it.
    func testStreamsFromBlenderHost() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["SIGHTLINE_QA_HOST"], !host.isEmpty else {
            throw XCTSkip(
                "set TEST_RUNNER_SIGHTLINE_QA_HOST (and TEST_RUNNER_SIGHTLINE_QA_CODE) to run against a Blender host")
        }
        let code = env["SIGHTLINE_QA_CODE"] ?? ""
        continueAfterFailure = false
        let app = landscapeApp()
        app.launchArguments = [
            "-SightlineQAHost", host,
            "-SightlineQACode", code,
            "-SightlineQAMotion", env["SIGHTLINE_QA_MOTION"] ?? "orbit",
            "-SightlineQAAutoStart", "YES",
            "-viewfinder.framing.maskAspect", "2.39",
            "-viewfinder.framing.thirds", "YES",
            "-viewfinder.framing.centreCross", "NO",
            "-viewfinder.framing.safeAreas", "NO",
            "-viewfinder.framing.horizon", "YES",
        ]
        app.launch()

        let connection = app.staticTexts["status.connection"]
        XCTAssertTrue(connection.waitForExistence(timeout: 20))
        wait(for: connection, label: "Sending to Blender", timeout: 45)
        let status = app.staticTexts["status.session"]
        wait(for: status, label: "Running", timeout: 15)

        // A frame is on screen once the viewfinder reports its size instead of "No video".
        let viewfinder = element(app, "viewfinder")
        expect(viewfinder, NSPredicate(format: "value MATCHES %@", "^[0-9]+x[0-9]+; .*"), timeout: 30)
        let stream = element(app, "hud.stream")
        expect(
            stream, NSPredicate(format: "value MATCHES %@", "^[1-9][0-9]* fps · [0-9]+\\.[0-9] Mbit/s$"), timeout: 15)
        let quality = element(app, "hud.quality")
        wait(for: quality, value: "Good", timeout: 15)
        let level = element(app, "hud.level")
        expect(level, NSPredicate(format: "value MATCHES %@", "^q[0-9]+ · [0-9]+×[0-9]+$"), timeout: 15)
        for id in [
            "hud.tracking", "hud.connection", "hud.stream", "hud.quality", "hud.level",
            "hud.lens", "hud.m2p", "hud.recording", "hud.thermal",
        ] {
            let item = element(app, id)
            XCTAssertTrue(item.exists, "\(id) must be accessible")
            XCTAssertFalse(
                item.frame.intersects(
                    viewfinder.frame.insetBy(
                        dx: viewfinder.frame.width / 4, dy: viewfinder.frame.height / 4)),
                "\(id) covers picture centre: \(item.frame), viewfinder \(viewfinder.frame)"
            )
        }
        // The host reports its camera's lens in STATUS; the HUD shows it with FOV and equivalent.
        expect(
            element(app, "hud.lens"),
            NSPredicate(
                format: "value MATCHES %@",
                "^Focal [0-9.]+ mm · Focus [0-9.]+ m · f/[0-9.]+ · FOV [0-9.]+° · Equiv [0-9]+ mm$"),
            timeout: 10)
        let panel = element(app, "hud.panel")
        XCTAssertTrue(panel.exists, "panel background must have a measurable frame")
        let centre = viewfinder.frame.insetBy(dx: viewfinder.frame.width / 4, dy: viewfinder.frame.height / 4)
        XCTAssertFalse(
            panel.frame.intersects(centre),
            "HUD panel background covers picture centre: \(panel.frame), viewfinder \(viewfinder.frame)")
        // HUDLayout.centreMargin is 4 pt; allow half a point of pixel rounding.
        XCTAssertGreaterThanOrEqual(
            panel.frame.minY - centre.maxY, 3.5, "HUD panel margin above the centre: \(panel.frame), centre \(centre)")
        XCTAssertEqual(element(app, "hud.m2p").value as? String, "—")
        XCTAssertEqual(element(app, "hud.recording").value as? String, "Recording: not available (T3)")
        // Frames keep coming: no stall once they arrive (FR-VF-005).
        sleep(2)
        XCTAssertFalse(app.descendants(matching: .any)["video.stalled"].exists, "video stalled while streaming")
        attachScreenshot(app, "1 streaming")
        sleep(2)
        attachScreenshot(app, "2 streaming, camera moved")

        showControls(app)
        let origin = app.buttons["control.origin"]
        XCTAssertTrue(origin.isEnabled)
        origin.tap()

        // Set origin sends a new control state (after the first one and the camera's lens adopted
        // from the first STATUS), which Blender acknowledges; with the host's state readable, it's
        // the one Blender has and it carries origin epoch 1.
        showControls(app)
        app.buttons["control.settings"].tap()
        // Top to bottom: the form only scrolls down to find a cell, and cells out of view leave the
        // accessibility tree.
        let packets = scrollTo(app, "settings.packetsSent")
        XCTAssertFalse(text(of: packets).hasSuffix(" 0"), "packets sent: \(text(of: packets))")
        let controlStatus = scrollTo(app, "settings.controlStatus")
        expect(
            controlStatus,
            NSPredicate(
                format: "label MATCHES %@ OR value MATCHES %@", ".*Applied \\(#[0-9]+\\).*", "Applied \\(#[0-9]+\\)"),
            timeout: 10)
        if hostDirectory != nil {
            let applied = text(of: controlStatus).firstMatch(of: /Applied \(#([0-9]+)\)/).flatMap { Int($0.1) }
            let host = waitForHost("origin epoch 1") { controls($0)["origin_epoch"] as? Int == 1 }
            XCTAssertEqual(controls(host)["state_seq"] as? Int, applied, "the acknowledged state is Blender's")
        }
        attachScreenshot(app, "3 settings while streaming")
        app.buttons["settings.done"].tap()

        XCTAssertFalse(app.descendants(matching: .any)["video.stalled"].exists, "video stalled while streaming")
        attachScreenshot(app, "4 after set origin")

        showControls(app)
        let startStop = app.buttons["control.startStop"]
        XCTAssertEqual(startStop.label, "Stop")
        let lastFrameDescription = viewfinder.value as? String
        startStop.tap()
        wait(for: status, label: "Stopped")
        wait(for: element(app, "hud.tracking"), value: "Stopped")
        XCTAssertFalse(stream.exists, "a stopped session must not show old stream measurements")
        XCTAssertEqual(
            viewfinder.value as? String,
            lastFrameDescription,
            "the still-visible last frame must keep its framing guides and accessibility size")
        attachScreenshot(app, "5 stopped")
    }

    func testThermalOverrideReducesStreamAndNominalRestoresIt() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["SIGHTLINE_QA_HOST"], !host.isEmpty else {
            throw XCTSkip("requires the Blender QA host")
        }
        continueAfterFailure = false
        let app = landscapeApp()
        let base =
            [
                "-SightlineQAHost", host,
                "-SightlineQACode", env["SIGHTLINE_QA_CODE"] ?? "",
                "-SightlineQAMotion", "orbit",
                "-SightlineQAAutoStart", "YES",
            ] + Self.framingOff

        app.launchArguments = base + ["-SightlineQAThermal", "serious"]
        app.launch()
        let viewfinder = element(app, "viewfinder")
        wait(for: element(app, "status.connection"), label: "Sending to Blender", timeout: 45)
        wait(for: element(app, "hud.thermal"), value: "Stream reduced (thermal)", timeout: 15)
        wait(for: app.staticTexts["status.thermal"], label: "Thermal: Serious", timeout: 15)
        expect(viewfinder, NSPredicate(format: "value BEGINSWITH '640x360'"), timeout: 35)
        expect(element(app, "hud.level"), NSPredicate(format: "value CONTAINS '640×360'"), timeout: 15)
        attachScreenshot(app, "1 thermal serious, stream reduced")

        app.terminate()
        app.launchArguments = base + ["-SightlineQAThermal", "nominal"]
        app.launch()
        wait(for: element(app, "status.connection"), label: "Sending to Blender", timeout: 45)
        wait(for: app.staticTexts["status.thermal"], label: "Thermal: Normal", timeout: 15)
        wait(for: element(app, "hud.thermal"), value: "Thermal: Normal", timeout: 15)
        expect(viewfinder, NSPredicate(format: "value BEGINSWITH '960x540'"), timeout: 35)
        expect(element(app, "hud.level"), NSPredicate(format: "value CONTAINS '960×540'"), timeout: 15)
        attachScreenshot(app, "2 thermal nominal, stream restored")
    }

    // MARK: - Lens (FR-CTL-001..003)

    static let lensIdentifiers = [
        "lens.panel", "lens.done", "lens.prime.18", "lens.prime.24", "lens.prime.35", "lens.prime.50",
        "lens.prime.85", "lens.prime.135", "lens.focal", "lens.focus", "lens.setA", "lens.setB", "lens.rack",
        "lens.rackDuration", "lens.rackDuration.down", "lens.rackDuration.up", "lens.aperture",
        "lens.aperture.down", "lens.aperture.up", "lens.dof",
    ]

    /// Primes, the focal slider, a pinch on the viewfinder, aperture and DoF each change the Blender
    /// camera (`hud.lens` is what Blender reports in STATUS; with the harness, `state.json` too), and
    /// the primes change the next streamed frame. Still motion, so only the lens changes the frame.
    func testLensControlsDriveTheBlenderCameraAndTheFrame() throws {
        let app = try launchStreaming(motion: "still")
        let viewfinder = element(app, "viewfinder")
        openLensPanel(app)
        for id in Self.lensIdentifiers {
            XCTAssertTrue(element(app, id).exists, "\(id) must be accessible")
        }
        let panel = element(app, "lens.panel")
        XCTAssertFalse(
            panel.frame.intersects(
                viewfinder.frame.insetBy(dx: viewfinder.frame.width / 4, dy: viewfinder.frame.height / 4)),
            "the lens panel covers the picture centre: \(panel.frame), viewfinder \(viewfinder.frame)")
        attachScreenshot(app, "1 lens panel")

        // VAL-CROSS-001 / VAL-LENSI-007: prime → Blender → the next frame.
        var frames: [Float: CGImage] = [:]
        for prime: Float in [24, 135, 85] {
            openLensPanel(app)
            app.buttons["lens.prime.\(Int(prime))"].tap()
            waitForLens(app, focal: prime)
            sleep(1)
            frames[prime] = pictureArea()
            attachScreenshot(app, "2 prime \(Int(prime)) mm")
        }
        let same = try XCTUnwrap(pictureArea())
        let wideToLong = difference(try XCTUnwrap(frames[24]), try XCTUnwrap(frames[135]))
        let longTo85 = difference(try XCTUnwrap(frames[135]), try XCTUnwrap(frames[85]))
        let still = difference(try XCTUnwrap(frames[85]), same)
        print("LENS_FRAME_DIFF 24→135 \(wideToLong) 135→85 \(longTo85) 85→85 \(still)")
        XCTAssertGreaterThan(wideToLong, 4 * max(still, 1), "24 → 135 mm must change the streamed frame")
        XCTAssertGreaterThan(longTo85, 4 * max(still, 1), "135 → 85 mm must change the streamed frame")

        // VAL-LENSI-008: the slider, then a pinch out (longer) and in (shorter), within 12…300 mm.
        openLensPanel(app)
        app.sliders["lens.focal"].adjust(toNormalizedSliderPosition: 0.2)
        let slid = try XCTUnwrap(waitForLens(app, "the slider's focal length") { $0.focal < 85 }).focal
        XCTAssertGreaterThanOrEqual(slid, 12)
        attachScreenshot(app, "3 focal slider")
        // Pinches start with the fingers apart: keep them off the lens panel.
        closeLensPanel(app)
        viewfinder.pinch(withScale: 2, velocity: 1)
        let longer = try XCTUnwrap(waitForLens(app, "a longer lens after pinching out") { $0.focal > slid + 5 }).focal
        attachScreenshot(app, "4 pinch out")
        viewfinder.pinch(withScale: 0.4, velocity: -1)
        let shorter = try XCTUnwrap(waitForLens(app, "a shorter lens after pinching in") { $0.focal < longer - 5 })
            .focal
        XCTAssertGreaterThanOrEqual(shorter, 12)
        for _ in 0..<3 { viewfinder.pinch(withScale: 3, velocity: 2) }
        let longest = try XCTUnwrap(waitForLens(app, "pinching out stops at 300 mm") { $0.focal == 300 }).focal
        print("LENS_FOCAL slider \(slid) pinch-out \(longer) pinch-in \(shorter) max \(longest)")
        if hostDirectory != nil {
            waitForHost("Blender lens 300 mm") { camera($0)["lens"] as? Double == 300 }
        }

        // VAL-LENSI-011: DoF on at f/2, then off.
        openLensPanel(app)
        app.buttons["lens.prime.85"].tap()
        waitForLens(app, focal: 85)
        openLensPanel(app)
        setSwitch(app.switches["lens.dof"], on: true)
        setAperture(app, 2)
        expect(element(app, "hud.lens"), NSPredicate(format: "value CONTAINS ' · f/2 · '"), timeout: 10)
        if hostDirectory != nil {
            let on = waitForHost("DoF on at f/2") {
                camera($0)["dof_use"] as? Bool == true && camera($0)["fstop"] as? Double == 2
            }
            print("LENS_DOF on \(camera(on))")
        }
        sleep(1)
        let dofOn = try XCTUnwrap(pictureArea())
        attachScreenshot(app, "5 DoF on f2")
        openLensPanel(app)
        setSwitch(app.switches["lens.dof"], on: false)
        if hostDirectory != nil {
            waitForHost("DoF off") { camera($0)["dof_use"] as? Bool == false }
        }
        sleep(1)
        // The stream draws the viewport's shading, which may not show depth of field: recorded, not
        // asserted (VAL-LENSI-011 allows that as a documented limitation).
        print("LENS_DOF_FRAME_DIFF on→off \(difference(dofOn, try XCTUnwrap(pictureArea())))")
        attachScreenshot(app, "6 DoF off")
        closeLensPanel(app)
    }

    /// VAL-LENSI-009 / VAL-CROSS-005: a tap on the picture focuses Blender's camera on what's
    /// there; a tap in the pillar bar beside the picture sends nothing. VAL-LENSI-010 /
    /// VAL-CROSS-006: wheel, marks and a 2 s rack that Blender runs smoothly to B.
    func testTapToFocusAndRackBetweenMarks() throws {
        let app = try launchStreaming(motion: "still")
        let viewfinder = element(app, "viewfinder")
        let size = try XCTUnwrap(frameSize(viewfinder))
        // A wide lens and a far focus, so both taps below change the focus.
        openLensPanel(app)
        app.buttons["lens.prime.24"].tap()
        waitForLens(app, focal: 24)
        openLensPanel(app)
        dragWheel(element(app, "lens.focus"), farther: true) { $0 >= 4 }
        waitForLens(app, "a far focus from the wheel") { $0.focus >= 4 }
        closeLensPanel(app)
        let before = hudLens(app)?.focus
        let tapSeq = hostDirectory.flatMap { _ in controls(hostState() ?? [:])["tap_seq"] as? Int }

        tapPicture(viewfinder, frame: size, u: 0.5, v: 0.5)
        let first = try XCTUnwrap(waitForLens(app, "focus on the totem") { $0.focus != before }).focus
        attachScreenshot(app, "1 tap centre")
        tapPicture(viewfinder, frame: size, u: 0.75, v: 0.9)
        let second = try XCTUnwrap(waitForLens(app, "focus on the floor") { $0.focus != first }).focus
        attachScreenshot(app, "2 tap lower right")
        print("LENS_TAP centre \(first) m, lower right \(second) m")
        if let tapSeq {
            let host = waitForHost("two taps on the host") { controls($0)["tap_seq"] as? Int == tapSeq + 2 }
            let focus = try XCTUnwrap(camera(host)["focus_distance"] as? Double)
            XCTAssertEqual(focus, second, accuracy: 0.006, "hud.lens shows Blender's focus distance")
            print("LENS_TAP host \(host["focus"] ?? "nil")")
        }

        // The pillar bar left of the picture (inside the safe-area inset): hides the controls the
        // picture taps showed, never focuses.
        let picture = pictureRect(viewfinder.frame, frame: size)
        XCTAssertGreaterThan(picture.minX - viewfinder.frame.minX, 20, "a 16:9 stream leaves a pillar bar")
        XCTAssertTrue(app.buttons["control.settings"].exists, "a tap on the picture shows the controls")
        viewfinder.coordinate(withNormalizedOffset: .zero)
            .withOffset(
                CGVector(
                    dx: (picture.minX - viewfinder.frame.minX) / 2,
                    dy: picture.minY + picture.height / 4 - viewfinder.frame.minY)
            )
            .tap()
        XCTAssertTrue(app.buttons["control.settings"].waitForNonExistence(timeout: 5), "a bar tap hides them")
        sleep(1)
        XCTAssertEqual(hudLens(app)?.focus, second, "a bar tap must not focus")
        if let tapSeq {
            XCTAssertEqual(controls(hostState() ?? [:])["tap_seq"] as? Int, tapSeq + 2, "a bar tap sends no tap")
        }

        // Far mark B, then near mark A with the wheel; the rack goes to the farther mark, B.
        openLensPanel(app)
        let wheel = element(app, "lens.focus")
        let far = dragWheel(wheel, farther: true) { $0 >= 4 }
        app.buttons["lens.setB"].tap()
        wait(for: app.buttons["lens.setB"], value: String(format: "%.2f m", far))
        let near = dragWheel(wheel, farther: false) { $0 <= 1.5 }
        app.buttons["lens.setA"].tap()
        wait(for: app.buttons["lens.setA"], value: String(format: "%.2f m", near))
        waitForLens(app, "Blender at the near mark") { abs($0.focus - Double(near)) < 0.006 }
        openLensPanel(app)
        wait(for: element(app, "lens.rackDuration"), value: "2.0 s")
        let rack = app.buttons["lens.rack"]
        XCTAssertEqual(rack.label, "Rack to B")
        attachScreenshot(app, "3 marks set")
        rack.tap()
        var series: [Double] = []
        if hostDirectory != nil {
            let start = Date()
            while Date().timeIntervalSince(start) < 3.2 {
                if let focus = camera(hostState() ?? [:])["focus_distance"] as? Double, series.last != focus {
                    series.append(focus)
                }
                usleep(100_000)
            }
            print("LENS_RACK series \(series.map { String(format: "%.3f", $0) }.joined(separator: " "))")
            let between = series.filter { $0 > Double(near) + 0.01 && $0 < Double(far) - 0.01 }
            XCTAssertGreaterThanOrEqual(between.count, 5, "a smooth rack, not a jump: \(series)")
            XCTAssertEqual(series, series.sorted(), "the rack never goes back (no restart): \(series)")
            XCTAssertEqual(try XCTUnwrap(series.last), Double(far), accuracy: 0.006, "ends at B")
        }
        let end = waitForLens(app, "the HUD at B") { abs($0.focus - Double(far)) < 0.006 }
        print("LENS_RACK near \(near) far \(far) hud end \(end?.focus ?? -1)")
        attachScreenshot(app, "4 racked to B")
    }

    /// VAL-LENSI-012: a 2.39 render on the host reaches the phone's letterbox and guides.
    func testStreamFollowsTheHostRenderAspect() throws {
        guard hostDirectory != nil else { throw XCTSkip("needs the QA harness (TEST_RUNNER_SIGHTLINE_QA_DIR)") }
        let app = try launchStreaming(motion: "still", framing: ["-viewfinder.framing.thirds", "YES"])
        let viewfinder = element(app, "viewfinder")
        expect(viewfinder, NSPredicate(format: "value == '960x540; thirds'"), timeout: 20)
        attachScreenshot(app, "1 16x9")
        let render = try XCTUnwrap(hostCommand(["cmd": "set_render", "resolution_x": 2390, "resolution_y": 1000]))
        XCTAssertEqual(render["ok"] as? Bool, true, "\(render)")
        defer { _ = hostCommand(["cmd": "set_render", "resolution_x": 1920, "resolution_y": 1080]) }
        expect(viewfinder, NSPredicate(format: "value == '960x402; thirds'"), timeout: 20)
        let size = try XCTUnwrap(frameSize(viewfinder))
        let picture = pictureRect(viewfinder.frame, frame: size)
        XCTAssertGreaterThan(picture.minY - viewfinder.frame.minY, 5, "letterbox bars above and below")
        sleep(1)
        attachScreenshot(app, "2 2.39 letterbox with thirds")
        _ = hostCommand(["cmd": "set_render", "resolution_x": 1920, "resolution_y": 1080])
        expect(viewfinder, NSPredicate(format: "value == '960x540; thirds'"), timeout: 20)
    }

    /// VAL-CROSS-008: the lens set on the phone comes back on a fresh Blender. Stops the harness
    /// host, so it only runs with SIGHTLINE_QA_RESTART=1 while something starts the host again
    /// (e.g. a shell loop running `qa_blender.sh start` once `status` says it stopped).
    func testLensStateSurvivesAHostRestart() throws {
        let env = ProcessInfo.processInfo.environment
        guard hostDirectory != nil, env["SIGHTLINE_QA_RESTART"] == "1" else {
            throw XCTSkip("needs the QA harness and SIGHTLINE_QA_RESTART=1 with a host restarter")
        }
        let app = try launchStreaming(motion: "still")
        openLensPanel(app)
        app.buttons["lens.prime.85"].tap()
        openLensPanel(app)
        setSwitch(app.switches["lens.dof"], on: true)
        openLensPanel(app)
        setAperture(app, 2)
        let set = waitForHost("85 mm f/2 DoF on") {
            camera($0)["lens"] as? Double == 85 && camera($0)["fstop"] as? Double == 2
                && camera($0)["dof_use"] as? Bool == true
        }
        let oldSession = session(set)["session_id"] as? Int
        attachScreenshot(app, "1 lens set before restart")
        _ = hostCommand(["cmd": "stop"])
        let connection = element(app, "status.connection")
        expect(connection, NSPredicate(format: "label == 'Reconnecting'"), timeout: 20)
        wait(for: connection, label: "Sending to Blender", timeout: 150)
        let after = waitForHost("the fresh host applies 85 mm f/2 DoF on", timeout: 30) {
            session($0)["session_id"] as? Int != oldSession && camera($0)["lens"] as? Double == 85
                && camera($0)["fstop"] as? Double == 2 && camera($0)["dof_use"] as? Bool == true
        }
        let focus = after["focus"] as? [String: Any]
        XCTAssertTrue(focus?["last_tap"] is NSNull, "no tap replayed: \(String(describing: focus))")
        XCTAssertTrue(focus?["rack"] is NSNull, "no rack replayed: \(String(describing: focus))")
        waitForLens(app, focal: 85)
        expect(element(app, "hud.lens"), NSPredicate(format: "value CONTAINS ' · f/2 · '"), timeout: 10)
        print("LENS_RESTART camera \(camera(after)) controls \(controls(after))")
        attachScreenshot(app, "2 lens after restart")
    }

    // MARK: - Helpers

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Launches against the harness host and waits until frames and the camera's lens arrive.
    private func launchStreaming(motion: String, framing: [String] = []) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["SIGHTLINE_QA_HOST"], !host.isEmpty else {
            throw XCTSkip("requires the Blender QA host")
        }
        continueAfterFailure = false
        let app = landscapeApp()
        app.launchArguments =
            [
                "-SightlineQAHost", host,
                "-SightlineQACode", env["SIGHTLINE_QA_CODE"] ?? "",
                "-SightlineQAMotion", motion,
                "-SightlineQAAutoStart", "YES",
            ] + Self.framingOff + framing
        app.launch()
        wait(for: element(app, "status.connection"), label: "Sending to Blender", timeout: 45)
        expect(element(app, "viewfinder"), NSPredicate(format: "value MATCHES %@", "^[0-9]+x[0-9]+.*"), timeout: 30)
        waitForLens(app, "the camera's lens from STATUS") { _ in true }
        if hostDirectory != nil {
            XCTAssertNotNil(hostState(), "state.json must be readable from the simulator")
        }
        return app
    }

    /// Steps the aperture control to f/`fstop` (a full stop in its series).
    private func setAperture(_ app: XCUIApplication, _ fstop: Double) {
        let aperture = element(app, "lens.aperture")
        let target = String(format: "f/%g", fstop)
        for _ in 0..<10 {
            openLensPanel(app)
            guard let shown = (aperture.value as? String).flatMap({ Double($0.dropFirst(2)) }), shown != fstop else {
                break
            }
            app.buttons[shown > fstop ? "lens.aperture.down" : "lens.aperture.up"].tap()
        }
        wait(for: aperture, value: target)
    }

    /// `hud.lens` as numbers: "Focal 85 mm · Focus 3.00 m · f/2 · …".
    private func hudLens(_ app: XCUIApplication) -> (focal: Float, focus: Double, fstop: Double)? {
        guard let value = element(app, "hud.lens").value as? String,
            let match = value.firstMatch(of: /^Focal ([0-9.]+) mm · Focus ([0-9.]+) m · f\/([0-9.]+)/),
            let focal = Float(match.1), let focus = Double(match.2), let fstop = Double(match.3)
        else { return nil }
        return (focal, focus, fstop)
    }

    @discardableResult
    private func waitForLens(
        _ app: XCUIApplication, _ what: String, timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line,
        _ check: ((focal: Float, focus: Double, fstop: Double)) -> Bool
    ) -> (focal: Float, focus: Double, fstop: Double)? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let lens = hudLens(app), check(lens) { return lens }
            usleep(100_000)
        } while Date() < deadline
        XCTFail("hud.lens never showed \(what): \(element(app, "hud.lens").value ?? "nil")", file: file, line: line)
        return nil
    }

    /// Waits for Blender's focal length in `hud.lens` and, with the harness, in `state.json`.
    private func waitForLens(_ app: XCUIApplication, focal: Float, file: StaticString = #filePath, line: UInt = #line) {
        waitForLens(app, "Focal \(focal) mm", file: file, line: line) { $0.focal == focal }
        if hostDirectory != nil {
            waitForHost("Blender lens \(focal) mm", file: file, line: line) {
                camera($0)["lens"] as? Double == Double(focal)
            }
        }
    }

    private func frameSize(_ viewfinder: XCUIElement) -> CGSize? {
        guard let value = viewfinder.value as? String,
            let match = value.firstMatch(of: /^([0-9]+)x([0-9]+)/),
            let width = Double(match.1), let height = Double(match.2)
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Where the frame is drawn in the viewfinder: fitted and centred (`ViewfinderLayout`).
    private func pictureRect(_ view: CGRect, frame: CGSize) -> CGRect {
        let scale = min(view.width / frame.width, view.height / frame.height)
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        return CGRect(
            x: view.midX - size.width / 2, y: view.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func tapPicture(_ viewfinder: XCUIElement, frame: CGSize, u: CGFloat, v: CGFloat) {
        let picture = pictureRect(viewfinder.frame, frame: frame)
        viewfinder.coordinate(withNormalizedOffset: .zero)
            .withOffset(
                CGVector(
                    dx: picture.minX + u * picture.width - viewfinder.frame.minX,
                    dy: picture.minY + v * picture.height - viewfinder.frame.minY)
            )
            .tap()
    }

    /// Drags the focus wheel by half its width until `done` accepts its value (metres).
    @discardableResult
    private func dragWheel(_ wheel: XCUIElement, farther: Bool, until done: (Float) -> Bool) -> Float {
        func value() -> Float? {
            (wheel.value as? String).flatMap { Float($0.replacingOccurrences(of: " m", with: "")) }
        }
        for _ in 0..<8 {
            if let metres = value(), done(metres) { return metres }
            let from = wheel.coordinate(withNormalizedOffset: CGVector(dx: farther ? 0.75 : 0.25, dy: 0.5))
            let to = wheel.coordinate(withNormalizedOffset: CGVector(dx: farther ? 0.25 : 0.75, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTFail("focus wheel stuck at \(wheel.value ?? "nil")")
        return value() ?? 0
    }

    /// The picture between the status strip and the HUD panel, left of the lens panel, upright:
    /// where a lens change shows, for comparing frames. (The middle alone can be one flat colour at
    /// a long focal length.)
    private func pictureArea() -> CGImage? {
        guard let image = upright(XCUIScreen.main.screenshot().image).cgImage else { return nil }
        let (width, height) = (CGFloat(image.width), CGFloat(image.height))
        return image.cropping(
            to: CGRect(x: width * 0.1, y: height * 0.12, width: width * 0.55, height: height * 0.6).integral)
    }

    /// Mean absolute difference per channel (0–255) of two images scaled to 64 × 64.
    private func difference(_ a: CGImage, _ b: CGImage) -> Double {
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: 64 * 64 * 4)
            data.withUnsafeMutableBytes { bytes in
                let context = CGContext(
                    data: bytes.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            return data
        }
        let (x, y) = (pixels(a), pixels(b))
        let total = zip(x, y).enumerated().reduce(0) { sum, item in
            item.offset % 4 == 3 ? sum : sum + abs(Int(item.element.0) - Int(item.element.1))
        }
        return Double(total) / Double(64 * 64 * 3)
    }

    // MARK: - QA harness host (state.json and the command queue)

    /// The harness's `.mission/qa` directory, when `qa_ios.sh uitest` passes it.
    private var hostDirectory: String? {
        ProcessInfo.processInfo.environment["SIGHTLINE_QA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func hostState() -> [String: Any]? {
        guard let directory = hostDirectory,
            let data = FileManager.default.contents(atPath: directory + "/state.json")
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func camera(_ state: [String: Any]) -> [String: Any] { state["camera"] as? [String: Any] ?? [:] }
    private func controls(_ state: [String: Any]) -> [String: Any] { state["controls"] as? [String: Any] ?? [:] }
    private func session(_ state: [String: Any]) -> [String: Any] { state["session"] as? [String: Any] ?? [:] }

    /// Polls `state.json` (rewritten at 5 Hz) until `check` accepts it; the last state either way.
    @discardableResult
    private func waitForHost(
        _ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
        _ check: ([String: Any]) -> Bool
    ) -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var state: [String: Any] = [:]
        repeat {
            if let current = hostState() {
                state = current
                if check(current) { return current }
            }
            usleep(100_000)
        } while Date() < deadline
        XCTFail(
            "Blender never had \(what): camera \(camera(state)), controls \(controls(state))", file: file, line: line)
        return state
    }

    /// Queues a harness command (qa_host.py: write under another name, then rename) and returns
    /// its result.
    private func hostCommand(_ command: [String: Any], timeout: TimeInterval = 15) -> [String: Any]? {
        guard let directory = hostDirectory,
            let data = try? JSONSerialization.data(withJSONObject: command)
        else { return nil }
        let name = "uitest-\(UUID().uuidString)"
        let queue = URL(fileURLWithPath: directory).appending(path: "cmd")
        let staged = queue.appending(path: "\(name).tmp")
        let result = queue.appending(path: "\(name).result.json")
        do {
            try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
            try data.write(to: staged)
            try FileManager.default.moveItem(at: staged, to: queue.appending(path: "\(name).json"))
        } catch {
            XCTFail("can't queue \(command): \(error)")
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let reply = FileManager.default.contents(atPath: result.path) {
                try? FileManager.default.removeItem(at: result)
                return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
            }
            usleep(100_000)
        }
        XCTFail("no result for \(command)")
        return nil
    }

    /// Opens Settings, sets the rule of thirds, centre cross and horizon level, and closes it.
    private func setFraming(_ app: XCUIApplication, on: Bool) {
        showControls(app)
        app.buttons["control.settings"].tap()
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 10))
        for id in ["settings.framing.thirds", "settings.framing.centreCross", "settings.framing.horizon"] {
            setSwitch(scrollTo(app, id), on: on)
        }
        attachScreenshot(app, on ? "3 settings, framing on" : "5 settings, framing off")
        app.buttons["settings.done"].tap()
        XCTAssertTrue(app.buttons["settings.done"].waitForNonExistence(timeout: 10))
    }

    /// Scrolls the Settings form until the element (a toggle's switch, for toggles) is in view below
    /// the navigation bar. Only drags that hold still before lifting, so the list never coasts past
    /// a row; a row not in the tree yet is looked for further down first, then further up.
    private func scrollTo(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let target = element(app, identifier)
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.exists || form.waitForExistence(timeout: 10), "settings form")
        let visible = form.frame.inset(by: UIEdgeInsets(top: 80, left: 0, bottom: 10, right: 0))
        let limit = visible.height * 0.7
        for attempt in 0..<24 {
            let offset: CGFloat
            if target.exists {
                let inner = target.switches.firstMatch
                let frame = inner.exists ? inner.frame : target.frame
                if frame.minY >= visible.minY, frame.maxY <= visible.maxY, target.isHittable {
                    return target
                }
                offset = max(-limit, min(limit, visible.midY - frame.midY))
            } else {
                offset = attempt < 12 ? -limit : limit
            }
            let centre = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            centre.withOffset(CGVector(dx: 0, dy: -offset / 2)).press(
                forDuration: 0.05, thenDragTo: centre.withOffset(CGVector(dx: 0, dy: offset / 2)),
                withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTFail("\(identifier) not on screen")
        return target
    }

    /// A Form toggle's element spans its row, and a tap in the row's middle doesn't flip it: tap the
    /// switch itself.
    private func setSwitch(_ toggle: XCUIElement, on: Bool) {
        let wanted = on ? "1" : "0"
        guard toggle.value as? String != wanted else { return }
        let inner = toggle.switches.firstMatch
        if inner.exists {
            inner.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        wait(for: toggle, value: wanted)
    }

    /// The control rail hides a few seconds into a run; a tap beside the picture brings it back (or
    /// the lens panel, if that was open: closed here). A 16:9 stream leaves a pillar bar at the
    /// leading edge (a tap on the picture would focus), and without video any tap works. Not
    /// halfway down: the Dynamic Island takes touches there.
    private func showControls(_ app: XCUIApplication) {
        let settings = app.buttons["control.settings"]
        if settings.exists && settings.isHittable { return }
        revealChrome(app)
        closeLensPanel(app)
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "control rail")
    }

    /// Hidden controls leave the hierarchy, so `exists` (not `isHittable`: the lens panel scrolls)
    /// says whether they show. Polls for either kind: the 4 s timer runs from the tap.
    private func revealChrome(_ app: XCUIApplication) {
        let done = app.buttons["lens.done"]
        let settings = app.buttons["control.settings"]
        if done.exists || settings.exists { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.25)).tap()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !(done.exists || settings.exists) { usleep(100_000) }
    }

    /// The lens panel hides with the rest of the controls and comes back in the rail's place. The
    /// controls may hide between a check and a tap, so both helpers retry.
    private func openLensPanel(_ app: XCUIApplication) {
        let panel = element(app, "lens.panel")
        let lens = app.buttons["control.lens"]
        for _ in 0..<3 {
            revealChrome(app)
            if panel.exists { return }
            if lens.exists {
                lens.tap()
                if panel.waitForExistence(timeout: 3) { return }
            }
        }
        XCTFail("lens panel")
    }

    private func closeLensPanel(_ app: XCUIApplication) {
        let panel = element(app, "lens.panel")
        let done = app.buttons["lens.done"]
        for _ in 0..<3 {
            revealChrome(app)
            guard panel.exists else { return }
            if done.exists {
                done.tap()
                if panel.waitForNonExistence(timeout: 3) { break }
            }
        }
        XCTAssertFalse(panel.exists, "lens panel closed")
    }

    private func text(of element: XCUIElement) -> String {
        [element.label, element.value as? String].compactMap { $0 }.joined(separator: " ")
    }

    private func wait(for element: XCUIElement, label: String, timeout: TimeInterval = 10) {
        expect(element, NSPredicate(format: "label == %@", label), timeout: timeout)
    }

    private func wait(for element: XCUIElement, value: String, timeout: TimeInterval = 10) {
        expect(element, NSPredicate(format: "value == %@", value), timeout: timeout)
    }

    private func expect(
        _ element: XCUIElement, _ predicate: NSPredicate, timeout: TimeInterval,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        if XCTWaiter().wait(for: [expectation], timeout: timeout) != .completed {
            let current = element.exists ? "label '\(element.label)', value '\(element.value ?? "nil")'" : "missing"
            XCTFail("\(element) never matched \(predicate) (\(current))", file: file, line: line)
        }
    }

    /// The screen as the user sees it. The capture is the simulator's portrait framebuffer tagged
    /// with the interface's orientation, which an attachment's PNG drops (and `app.screenshot()`
    /// crops a landscape-only app), so it is redrawn upright first.
    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(image: upright(XCUIScreen.main.screenshot().image), quality: .original)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func upright(_ screen: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = screen.scale
        return UIGraphicsImageRenderer(size: screen.size, format: format).image { _ in
            screen.draw(in: CGRect(origin: .zero, size: screen.size))
        }
    }
}
