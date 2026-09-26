import CoreGraphics
import Foundation
import SwiftUI

/// Which framing guides the operator wants over the viewfinder (FR-VF-003). Saved between launches.
nonisolated struct FramingSettings: Equatable, Sendable {
    /// FR-VF-003's aspect masks, widest first; anything else via a custom ratio.
    static let presets: [Double] = [2.39, 2.00, 1.85, 1.78, 1.33]
    /// Custom masks from 1:2 (tall) to 4:1 (wide).
    static let aspectRange: ClosedRange<Double> = 0.5...4

    /// Width ÷ height of the delivered picture, nil for no mask.
    var maskAspect: Double?
    var thirds = false
    var centreCross = false
    var safeAreas = false

    /// A ratio typed by the operator ("2.2", "2,2", "16:9"), or nil if it isn't one in `aspectRange`.
    static func parseAspect(_ text: String) -> Double? {
        let parts = text.replacing(",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        let value: Double?
        switch parts.count {
        case 1: value = parts[0]
        case 2: value = parts[0].flatMap { width in parts[1].map { width / $0 } }
        default: value = nil
        }
        guard let value, value.isFinite, aspectRange.contains(value) else { return nil }
        return value
    }

    func save(userDefaults: UserDefaults = .standard) {
        userDefaults.set(maskAspect ?? 0, forKey: Keys.maskAspect)
        userDefaults.set(thirds, forKey: Keys.thirds)
        userDefaults.set(centreCross, forKey: Keys.centreCross)
        userDefaults.set(safeAreas, forKey: Keys.safeAreas)
    }

    /// A stored ratio outside `aspectRange` (or none) loads as no mask.
    static func load(userDefaults: UserDefaults = .standard) -> FramingSettings {
        let aspect = userDefaults.double(forKey: Keys.maskAspect)
        return FramingSettings(
            maskAspect: aspectRange.contains(aspect) ? aspect : nil,
            thirds: userDefaults.bool(forKey: Keys.thirds),
            centreCross: userDefaults.bool(forKey: Keys.centreCross),
            safeAreas: userDefaults.bool(forKey: Keys.safeAreas)
        )
    }

    private enum Keys {
        static let maskAspect = "viewfinder.framing.maskAspect"
        static let thirds = "viewfinder.framing.thirds"
        static let centreCross = "viewfinder.framing.centreCross"
        static let safeAreas = "viewfinder.framing.safeAreas"
    }
}

/// Where the framing guides go, in the viewfinder view's points (FR-VF-003). The image is where
/// the Metal view draws the frame (`ViewfinderLayout`); the picture is the part of it the aspect
/// mask leaves open (the whole image without a mask). Thirds, centre and safe areas belong to the
/// picture, because that's what gets delivered.
nonisolated struct FramingGeometry: Equatable, Sendable {
    /// SMPTE ST 2046-1: action safe is the central 93 % of the picture, title safe the central 90 %.
    static let actionSafe = 0.93
    static let titleSafe = 0.90

    let image: CGRect
    let picture: CGRect
    /// The two bars the mask covers (top and bottom, or left and right); empty without a mask or
    /// when the mask is within 0.5 % of the image's aspect (1.78 on a 16:9 stream leaves no
    /// hairline bars; the nearest other preset, 1.85, is 4 % away).
    let maskBars: [CGRect]

    /// Nil when either size is empty.
    init?(frame: CGSize, view: CGSize, maskAspect: Double?) {
        let scale = ViewfinderLayout.quadScale(frame: frame, drawable: view)
        guard scale != .zero else { return nil }
        let size = CGSize(width: view.width * CGFloat(scale.x), height: view.height * CGFloat(scale.y))
        image = CGRect(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2,
                       width: size.width, height: size.height)
        guard let maskAspect, maskAspect > 0 else {
            picture = image
            maskBars = []
            return
        }
        let imageAspect = image.width / image.height
        if abs(maskAspect / imageAspect - 1) < 0.005 {
            picture = image
            maskBars = []
        } else if maskAspect > imageAspect {
            let height = image.width / maskAspect
            picture = image.insetBy(dx: 0, dy: (image.height - height) / 2)
            maskBars = [
                CGRect(x: image.minX, y: image.minY, width: image.width, height: picture.minY - image.minY),
                CGRect(x: image.minX, y: picture.maxY, width: image.width, height: image.maxY - picture.maxY),
            ]
        } else {
            let width = image.height * maskAspect
            picture = image.insetBy(dx: (image.width - width) / 2, dy: 0)
            maskBars = [
                CGRect(x: image.minX, y: image.minY, width: picture.minX - image.minX, height: image.height),
                CGRect(x: picture.maxX, y: image.minY, width: image.maxX - picture.maxX, height: image.height),
            ]
        }
    }

    /// The two vertical then the two horizontal rule-of-thirds lines across the picture.
    var thirdsLines: [(CGPoint, CGPoint)] {
        let p = picture
        return [1.0, 2.0].map { k in
            let x = p.minX + p.width * k / 3
            return (CGPoint(x: x, y: p.minY), CGPoint(x: x, y: p.maxY))
        } + [1.0, 2.0].map { k in
            let y = p.minY + p.height * k / 3
            return (CGPoint(x: p.minX, y: y), CGPoint(x: p.maxX, y: y))
        }
    }

    var centre: CGPoint { CGPoint(x: picture.midX, y: picture.midY) }

    /// The central `share` of the picture on each axis.
    func safeArea(_ share: Double) -> CGRect {
        picture.insetBy(dx: picture.width * (1 - share) / 2, dy: picture.height * (1 - share) / 2)
    }
}

/// Draws the enabled guides over the viewfinder. Nothing is drawn before the first frame, because
/// the image's place on screen isn't known until then. Doesn't take touches.
struct FramingOverlayView: View {
    let settings: FramingSettings
    /// Pixel size of the frame on screen, nil before the first.
    let frameSize: CGSize?

    /// Length of each arm of the centre cross, in points.
    static let crossArm: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            guard let frameSize,
                  let geometry = FramingGeometry(frame: frameSize, view: size, maskAspect: settings.maskAspect)
            else { return }
            for bar in geometry.maskBars {
                context.fill(Path(bar), with: .color(.black.opacity(0.8)))
            }
            var guides = Path()
            if !geometry.maskBars.isEmpty {
                guides.addRect(geometry.picture)
            }
            if settings.thirds {
                for (start, end) in geometry.thirdsLines {
                    guides.move(to: start)
                    guides.addLine(to: end)
                }
            }
            if settings.centreCross {
                let c = geometry.centre
                guides.move(to: CGPoint(x: c.x - Self.crossArm, y: c.y))
                guides.addLine(to: CGPoint(x: c.x + Self.crossArm, y: c.y))
                guides.move(to: CGPoint(x: c.x, y: c.y - Self.crossArm))
                guides.addLine(to: CGPoint(x: c.x, y: c.y + Self.crossArm))
            }
            if settings.safeAreas {
                guides.addRect(geometry.safeArea(FramingGeometry.actionSafe))
            }
            // A dark edge under each light line keeps the guides visible on bright and dark frames.
            context.stroke(guides, with: .color(.black.opacity(0.5)), lineWidth: 2)
            context.stroke(guides, with: .color(.white.opacity(0.7)), lineWidth: 1)
            if settings.safeAreas {
                let title = Path(geometry.safeArea(FramingGeometry.titleSafe))
                context.stroke(title, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                context.stroke(title, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
