import SwiftUI
import XCTest

/// The lens panel draws in the iPhone's lens slot before the camera's lens is known, and with a
/// lens, marks and a rack target (the end-to-end taps are in SightlineUITests).
@MainActor
final class LensPanelTests: XCTestCase {
    private func render(_ shown: LensValues, _ lens: LensControls) throws -> UIImage {
        let panel = LensPanel(
            shown: shown, lens: lens, rackDurationMS: 2000, perform: { _ in }, close: {}
        )
        .frame(width: 152, height: 337)
        let renderer = ImageRenderer(content: panel)
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage)
    }

    func testPanelDrawsWithoutAndWithTheCamerasLens() throws {
        let empty = try render(LensValues(), LensControls())
        XCTAssertEqual(empty.size, CGSize(width: 152, height: 337))

        var lens = LensControls()
        lens.setMark(VCPRackFocus.targetA, to: 1.2)
        lens.setMark(VCPRackFocus.targetB, to: 5)
        for focus: Float in [0.3, 1.2, 40] {
            let image = try render(LensValues(lensMM: 85, focusM: focus, fstop: 2, dofOn: true), lens)
            XCTAssertEqual(image.size, CGSize(width: 152, height: 337))
        }
    }
}
