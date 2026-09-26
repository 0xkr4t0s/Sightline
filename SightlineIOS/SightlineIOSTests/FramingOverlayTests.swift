import CoreGraphics
import Foundation
import SwiftUI
import XCTest

/// Framing guides over the viewfinder (task 2.3e1; FR-VF-003): aspect masks, rule of thirds,
/// centre cross and action/title safe, placed on the frame as the Metal view draws it.
final class FramingOverlayTests: XCTestCase {
    private static let hd = CGSize(width: 1920, height: 1080)
    private static let phone = CGSize(width: 874, height: 402)  // iPhone 17 Pro landscape

    /// To a thousandth of a point: the image comes from the Metal quad's `Float` scale.
    private func assertRect(_ rect: CGRect, _ x: Double, _ y: Double, _ width: Double, _ height: Double,
                            _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        for (got, want, name) in [(rect.minX, x, "x"), (rect.minY, y, "y"), (rect.width, width, "width"),
                                  (rect.height, height, "height")] {
            XCTAssertEqual(got, want, accuracy: 1e-3, "\(message): \(name)", file: file, line: line)
        }
    }

    func testImageIsWhereTheMetalQuadDrawsTheFrame() throws {
        // 16:9 in a wider phone screen: pillarboxed, full height.
        let pillar = try XCTUnwrap(FramingGeometry(frame: Self.hd, view: Self.phone, maskAspect: nil))
        let width = 402.0 * 16 / 9
        assertRect(pillar.image, (874 - width) / 2, 0, width, 402, "pillarbox")
        XCTAssertEqual(pillar.picture, pillar.image, "no mask: the picture is the whole image")
        XCTAssertEqual(pillar.maskBars, [])
        // 16:9 on a 4:3 iPad: letterboxed, full width.
        let letter = try XCTUnwrap(FramingGeometry(frame: Self.hd, view: CGSize(width: 1024, height: 768), maskAspect: nil))
        assertRect(letter.image, 0, (768 - 576) / 2, 1024, 576, "letterbox")
        // The same place as the quad: its half-extent in NDC times the view's half-size.
        let scale = ViewfinderLayout.quadScale(frame: Self.hd, drawable: Self.phone)
        XCTAssertEqual(pillar.image.width, 874 * Double(scale.x), accuracy: 1e-9)
        XCTAssertEqual(pillar.image.height, 402 * Double(scale.y), accuracy: 1e-9)

        XCTAssertNil(FramingGeometry(frame: .zero, view: Self.phone, maskAspect: 2.39))
        XCTAssertNil(FramingGeometry(frame: Self.hd, view: CGSize(width: 874, height: 0), maskAspect: 2.39))
    }

    func testMasksCoverTheImageOutsideTheChosenAspect() throws {
        let view = CGSize(width: 1600, height: 900)  // the image fills it exactly
        // Wider than 16:9: bars top and bottom.
        let scope = try XCTUnwrap(FramingGeometry(frame: Self.hd, view: view, maskAspect: 2.39))
        let height = 1600 / 2.39
        assertRect(scope.picture, 0, (900 - height) / 2, 1600, height, "2.39 picture")
        assertRect(scope.maskBars[0], 0, 0, 1600, (900 - height) / 2, "2.39 top bar")
        assertRect(scope.maskBars[1], 0, (900 + height) / 2, 1600, (900 - height) / 2, "2.39 bottom bar")
        // Narrower: bars left and right.
        let academy = try XCTUnwrap(FramingGeometry(frame: Self.hd, view: view, maskAspect: 1.33))
        let width = 900 * 1.33
        assertRect(academy.picture, (1600 - width) / 2, 0, width, 900, "1.33 picture")
        assertRect(academy.maskBars[0], 0, 0, (1600 - width) / 2, 900, "1.33 left bar")
        assertRect(academy.maskBars[1], (1600 + width) / 2, 0, (1600 - width) / 2, 900, "1.33 right bar")
        // Every preset leaves a picture of its own aspect inside the image, and bars plus picture
        // tile the image.
        for aspect in FramingSettings.presets + [0.5, 4] {
            for frame in [Self.hd, CGSize(width: 1280, height: 960)] {
                let g = try XCTUnwrap(FramingGeometry(frame: frame, view: Self.phone, maskAspect: aspect))
                XCTAssertTrue(g.image.contains(g.picture), "\(aspect)")
                let area = g.maskBars.reduce(g.picture.width * g.picture.height) { $0 + $1.width * $1.height }
                XCTAssertEqual(area, g.image.width * g.image.height, accuracy: 1e-6, "\(aspect)")
                if !g.maskBars.isEmpty {
                    XCTAssertEqual(g.picture.width / g.picture.height, aspect, accuracy: 1e-9, "\(aspect)")
                }
            }
        }
        // 1.78 on a 16:9 stream (1.7778) and 1.33 on 4:3 (1.3333) leave no hairline bars; 1.85 does mask.
        XCTAssertEqual(try XCTUnwrap(FramingGeometry(frame: Self.hd, view: view, maskAspect: 1.78)).maskBars, [])
        XCTAssertEqual(try XCTUnwrap(FramingGeometry(frame: CGSize(width: 1280, height: 960), view: view,
                                                     maskAspect: 1.33)).maskBars, [])
        XCTAssertEqual(try XCTUnwrap(FramingGeometry(frame: Self.hd, view: view, maskAspect: 1.85)).maskBars.count, 2)
    }

    func testThirdsCentreAndSafeAreasBelongToTheMaskedPicture() throws {
        let g = try XCTUnwrap(FramingGeometry(frame: Self.hd, view: CGSize(width: 1600, height: 900), maskAspect: 2.39))
        let p = g.picture
        XCTAssertGreaterThan(p.minY, 0, "masked")
        let lines = g.thirdsLines
        XCTAssertEqual(lines.count, 4)
        for (i, (start, end)) in lines.prefix(2).enumerated() {
            XCTAssertEqual(start.x, p.minX + p.width * Double(i + 1) / 3, accuracy: 1e-9)
            XCTAssertEqual(end.x, start.x)
            XCTAssertEqual(start.y, p.minY, accuracy: 1e-9)
            XCTAssertEqual(end.y, p.maxY, accuracy: 1e-9)
        }
        for (i, (start, end)) in lines.suffix(2).enumerated() {
            XCTAssertEqual(start.y, p.minY + p.height * Double(i + 1) / 3, accuracy: 1e-9)
            XCTAssertEqual(end.y, start.y)
            XCTAssertEqual(start.x, p.minX, accuracy: 1e-9)
            XCTAssertEqual(end.x, p.maxX, accuracy: 1e-9)
        }
        XCTAssertEqual(g.centre, CGPoint(x: p.midX, y: p.midY))
        // SMPTE ST 2046-1: 93 % action, 90 % title, centred in the picture.
        let action = g.safeArea(FramingGeometry.actionSafe)
        assertRect(action, p.width * 0.035, p.minY + p.height * 0.035, p.width * 0.93, p.height * 0.93, "action safe")
        let title = g.safeArea(FramingGeometry.titleSafe)
        assertRect(title, p.width * 0.05, p.minY + p.height * 0.05, p.width * 0.9, p.height * 0.9, "title safe")
    }

    func testCustomAspectInput() throws {
        XCTAssertEqual(FramingSettings.parseAspect("2.2"), 2.2)
        XCTAssertEqual(FramingSettings.parseAspect(" 2,2 "), 2.2)
        XCTAssertEqual(try XCTUnwrap(FramingSettings.parseAspect("16:9")), 16.0 / 9, accuracy: 1e-12)
        XCTAssertEqual(FramingSettings.parseAspect(" 4 : 1 "), 4)
        XCTAssertEqual(FramingSettings.parseAspect("1:2"), 0.5)
        for bad in ["0.49", "4.01", "9:19", "1:0", "0:1", "16:", ":9", "2:3:4", "", "x", "inf", "nan", "-2"] {
            XCTAssertNil(FramingSettings.parseAspect(bad), bad)
        }
    }

    func testSettingsSurviveARelaunch() throws {
        let suite = "FramingOverlayTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(FramingSettings.load(userDefaults: defaults), FramingSettings(), "first launch: all off")
        let chosen = FramingSettings(maskAspect: 2.39, thirds: true, centreCross: false, safeAreas: true)
        chosen.save(userDefaults: defaults)
        XCTAssertEqual(FramingSettings.load(userDefaults: defaults), chosen)
        var off = chosen
        off.maskAspect = nil
        off.save(userDefaults: defaults)
        XCTAssertEqual(FramingSettings.load(userDefaults: defaults), off, "mask turned off stays off")
        defaults.set(9.0, forKey: "viewfinder.framing.maskAspect")
        XCTAssertNil(FramingSettings.load(userDefaults: defaults).maskAspect, "an out-of-range ratio isn't drawn")
    }

    // MARK: - Drawing

    /// The overlay drawn over white at 1 pt per pixel, as 8-bit red values, row 0 at the top.
    @MainActor
    private func render(_ settings: FramingSettings, frameSize: CGSize?, size: CGSize) throws -> (Int, [UInt8]) {
        let renderer = ImageRenderer(content: ZStack {
            Color.white
            FramingOverlayView(settings: settings, frameSize: frameSize)
        }.frame(width: size.width, height: size.height))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let (w, h) = (image.width, image.height)
        XCTAssertEqual(w, Int(size.width))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                                  bytesPerRow: w * 4, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, stride(from: 0, to: rgba.count, by: 4).map { rgba[$0] })
    }

    /// Darkest red value in the window (inclusive pixel ranges).
    private func darkest(_ picture: (Int, [UInt8]), x: ClosedRange<Int>, y: ClosedRange<Int>) -> UInt8 {
        y.flatMap { row in x.map { picture.1[row * picture.0 + $0] } }.min() ?? 255
    }

    @MainActor
    func testOverlayDrawsTheChosenGuidesOnTheFrame() throws {
        // 16:9 in 400×200: image x 22.2–377.8; a 2.39 mask leaves the picture at y 25.6–174.4.
        let size = CGSize(width: 400, height: 200)
        let all = FramingSettings(maskAspect: 2.39, thirds: true, centreCross: true, safeAreas: true)
        let g = try XCTUnwrap(FramingGeometry(frame: Self.hd, view: size, maskAspect: 2.39))
        let drawn = try render(all, frameSize: Self.hd, size: size)
        let bare = try render(FramingSettings(), frameSize: Self.hd, size: size)
        let none = try render(all, frameSize: nil, size: size)

        let thirdX = Int(g.thirdsLines[0].0.x)
        let actionX = Int(g.safeArea(FramingGeometry.actionSafe).minX)
        let edgeY = Int(g.picture.minY)
        let windows: [(String, ClosedRange<Int>, ClosedRange<Int>)] = [
            ("rule-of-thirds line", thirdX - 1...thirdX + 1, 100...100),
            ("centre cross", 199...201, 106...106),
            ("action safe", actionX - 1...actionX + 1, 100...100),
            ("mask edge", 200...200, edgeY - 1...edgeY + 1),
        ]
        for (name, x, y) in windows {
            XCTAssertLessThan(darkest(drawn, x: x, y: y), 235, "\(name) drawn")
            XCTAssertEqual(darkest(bare, x: x, y: y), 255, "\(name) not drawn when off")
        }
        XCTAssertLessThan(darkest(drawn, x: 100...300, y: 5...20), 80, "top mask bar darkens the frame")
        XCTAssertLessThan(darkest(drawn, x: 100...300, y: 180...195), 80, "bottom mask bar darkens the frame")
        XCTAssertEqual(darkest(drawn, x: 225...235, y: 95...105), 255, "the picture between guides is untouched")
        XCTAssertEqual(darkest(drawn, x: 0...18, y: 0...199), 255, "nothing outside the image")
        XCTAssertEqual(darkest(none, x: 0...399, y: 0...199), 255, "nothing before the first frame")
    }
}
