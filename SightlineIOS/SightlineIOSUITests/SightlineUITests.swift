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

        // The first control state of the run is #1; Set origin sends #2, which Blender acknowledges.
        showControls(app)
        app.buttons["control.settings"].tap()
        // Top to bottom: the form only scrolls down to find a cell, and cells out of view leave the
        // accessibility tree.
        let packets = scrollTo(app, "settings.packetsSent")
        XCTAssertFalse(text(of: packets).hasSuffix(" 0"), "packets sent: \(text(of: packets))")
        let controlStatus = scrollTo(app, "settings.controlStatus")
        expect(
            controlStatus, NSPredicate(format: "label CONTAINS 'Applied (#2)' OR value CONTAINS 'Applied (#2)'"),
            timeout: 10)
        attachScreenshot(app, "3 settings while streaming")
        app.buttons["settings.done"].tap()

        XCTAssertFalse(app.descendants(matching: .any)["video.stalled"].exists, "video stalled while streaming")
        attachScreenshot(app, "4 after set origin")

        showControls(app)
        let startStop = app.buttons["control.startStop"]
        XCTAssertEqual(startStop.label, "Stop")
        startStop.tap()
        wait(for: status, label: "Stopped")
        attachScreenshot(app, "5 stopped")
    }

    // MARK: - Helpers

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
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

    /// The control rail hides a few seconds into a run; a tap on the frame brings it back.
    private func showControls(_ app: XCUIApplication) {
        let settings = app.buttons["control.settings"]
        if settings.exists && settings.isHittable { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "control rail")
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
        let screen = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = screen.scale
        let image = UIGraphicsImageRenderer(size: screen.size, format: format).image { _ in
            screen.draw(in: CGRect(origin: .zero, size: screen.size))
        }
        let attachment = XCTAttachment(image: image, quality: .original)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
