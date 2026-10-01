import CoreGraphics
import Foundation

/// How the lens panel and the viewfinder gestures turn into `LensControls` values
/// (FR-CTL-001..003). The ranges here are the panel's; the wire allows more (`VCPLensRange`).
nonisolated enum LensInput {
    static let primesMM: [Float] = [18, 24, 35, 50, 85, 135]
    /// The focal slider's and the pinch's range.
    static let focalRange: ClosedRange<Float> = 12...300
    /// The focus wheel's range, metres.
    static let focusRange: ClosedRange<Float> = 0.1...100
    /// Full stops, widest first.
    static let apertureStops: [Float] = [1.4, 2, 2.8, 4, 5.6, 8, 11, 16, 22]
    /// Rack durations the panel offers; 0 jumps.
    static let rackDurationsMS: [Int] = [0, 500, 1000, 2000, 3000, 5000, 8000]
    /// A drag this long on the focus wheel doubles or halves the distance.
    static let wheelPointsPerDoubling = 40.0
    /// Relative slack when comparing values that went through Blender's binary32 storage.
    static let tolerance: Float = 1e-3

    /// Normalized (u, v) of `point` in the streamed picture drawn at `image` (both in the same view
    /// coordinates), with (0, 0) at the picture's top left as vcp.md §6.2 wants; nil for a point
    /// in the letterbox bars around it, or with no picture.
    static func pictureTap(at point: CGPoint, image: CGRect) -> (u: Float, v: Float)? {
        guard image.width > 0, image.height > 0 else { return nil }
        let u = (point.x - image.minX) / image.width
        let v = (point.y - image.minY) / image.height
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        return (Float(u), Float(v))
    }

    /// Where `mm` sits on the logarithmic focal slider, 0...1.
    static func focalPosition(_ mm: Float) -> Double {
        let clamped = min(max(Double(mm), Double(focalRange.lowerBound)), Double(focalRange.upperBound))
        return log(clamped / Double(focalRange.lowerBound))
            / log(Double(focalRange.upperBound) / Double(focalRange.lowerBound))
    }

    /// The focal length at a slider position, in whole millimetres.
    static func focal(atPosition position: Double) -> Float {
        let t = min(max(position, 0), 1)
        let low = Double(focalRange.lowerBound)
        return wholeMM(low * pow(Double(focalRange.upperBound) / low, t))
    }

    /// Pinching out (`magnification` > 1) lengthens the lens, like zooming in.
    static func pinch(from mm: Float, magnification: CGFloat) -> Float {
        guard magnification.isFinite, magnification > 0 else { return mm }
        return wholeMM(Double(mm) * Double(magnification))
    }

    /// The wheel is a ruler with farther distances to the right that follows the finger: dragging
    /// it left brings farther marks under the index.
    static func wheel(from metres: Float, dragX: CGFloat) -> Float {
        centimetres(Double(metres) * pow(2, -Double(dragX) / wheelPointsPerDoubling))
    }

    /// One accessibility increment or decrement of the wheel: a quarter of a doubling.
    static func wheelStep(from metres: Float, farther: Bool) -> Float {
        centimetres(Double(metres) * pow(2, farther ? 0.25 : -0.25))
    }

    /// The next full stop wider (smaller f-number) or narrower than `fstop`; `fstop` itself at the
    /// end of the series.
    static func aperture(from fstop: Float, wider: Bool) -> Float {
        let next =
            wider
            ? apertureStops.last { $0 < fstop * (1 - tolerance) }
            : apertureStops.first { $0 > fstop * (1 + tolerance) }
        return next ?? fstop
    }

    static func rackDuration(from ms: Int, longer: Bool) -> Int {
        let next = longer ? rackDurationsMS.first { $0 > ms } : rackDurationsMS.last { $0 < ms }
        return next ?? ms
    }

    /// "Rack A↔B": to the mark farther from the current focus (B on a tie or with the focus
    /// unknown), or to the only mark set; nil without marks.
    static func rackTarget(focus: Float?, markA: Float?, markB: Float?) -> UInt8? {
        switch (markA, markB) {
        case let (a?, b?):
            guard let focus else { return VCPRackFocus.targetB }
            return abs(a - focus) > abs(b - focus) ? VCPRackFocus.targetA : VCPRackFocus.targetB
        case (_?, nil): return VCPRackFocus.targetA
        case (nil, _?): return VCPRackFocus.targetB
        case (nil, nil): return nil
        }
    }

    static func matches(_ a: Float, _ b: Float) -> Bool {
        abs(a - b) <= tolerance * max(1, abs(b))
    }

    private static func wholeMM(_ mm: Double) -> Float {
        Float(min(max(mm.rounded(), Double(focalRange.lowerBound)), Double(focalRange.upperBound)))
    }

    private static func centimetres(_ metres: Double) -> Float {
        let rounded = (metres * 100).rounded() / 100
        return Float(min(max(rounded, Double(focusRange.lowerBound)), Double(focusRange.upperBound)))
    }
}

/// What the operator asks for with the lens panel or the viewfinder gestures.
nonisolated enum LensAction: Equatable, Sendable {
    case lens(Float)
    case focus(Float)
    case fstop(Float)
    case dof(Bool)
    /// Tap-to-focus at (u, v) in the streamed picture.
    case tap(u: Float, v: Float)
    /// Store the shown focus as mark A or B (`VCPRackFocus.targetA`/`targetB`).
    case mark(UInt8)
    /// Rack A↔B over the chosen duration.
    case rack
    case rackDuration(longer: Bool)
}

/// The lens values the panel shows.
nonisolated struct LensValues: Equatable, Sendable {
    var lensMM: Float?
    var focusM: Float?
    var fstop: Float?
    var dofOn: Bool?
}

/// The lens panel's state around `LensControls`. It shows the camera's lens as STATUS reports it
/// (vcp.md §6.4), because taps, racks and edits in Blender change the camera without the phone's
/// request changing. The exception is a value the operator set that STATUS doesn't show yet: it
/// shows the request until an applied value matches it, so a control doesn't jump back while the
/// change is on its way.
nonisolated struct LensPanelModel: Equatable, Sendable {
    enum Field: Sendable { case lens, focus, fstop, dof }

    private var pending: Set<Field> = []
    /// The duration the next rack asks for; only sent with the rack.
    private(set) var rackDurationMS = Int(LensControls.defaultRackDurationMS)

    func shown(_ lens: LensControls, applied: VCPAppliedLens?) -> LensValues {
        func pick<T>(_ field: Field, _ request: T?, _ camera: T?) -> T? {
            pending.contains(field) ? request ?? camera : camera ?? request
        }
        return LensValues(
            lensMM: pick(.lens, lens.lensMM, applied?.lensMM),
            focusM: pick(.focus, lens.focusDistanceM, applied?.focusDistanceM),
            fstop: pick(.fstop, lens.fstop, applied?.fstop),
            dofOn: pick(.dof, lens.dofOn, applied?.dofOn))
    }

    /// The focal length a pinch scales: the shown one, but only once STATUS has reported the
    /// camera's lens. Before that (at connect, or after a reconnect with an old request) a pinch
    /// would scale a guess and overwrite the camera.
    func pinchBase(_ lens: LensControls, applied: VCPAppliedLens?) -> Float? {
        guard applied != nil else { return nil }
        return shown(lens, applied: applied).lensMM
    }

    /// A new STATUS: requests the camera now shows are settled.
    mutating func statusChanged(_ lens: LensControls, applied: VCPAppliedLens) {
        func settle(_ field: Field, _ request: Float?, _ camera: Float) {
            if let request, LensInput.matches(camera, request) { pending.remove(field) }
        }
        settle(.lens, lens.lensMM, applied.lensMM)
        settle(.focus, lens.focusDistanceM, applied.focusDistanceM)
        settle(.fstop, lens.fstop, applied.fstop)
        if lens.dofOn == applied.dofOn { pending.remove(.dof) }
    }

    /// Carries out `action` on the request; false if it asked for nothing (a non-number tap, a
    /// mark without a known focus, a rack without marks).
    @discardableResult
    mutating func perform(_ action: LensAction, _ lens: inout LensControls, applied: VCPAppliedLens?) -> Bool {
        switch action {
        case .lens(let mm): setLens(mm, &lens)
        case .focus(let metres): setFocus(metres, &lens)
        case .fstop(let fstop): setFstop(fstop, &lens)
        case .dof(let on): setDoF(on, &lens)
        case let .tap(u, v): return tap(u: u, v: v, &lens)
        case .mark(let target): return setMark(target, &lens, applied: applied)
        case .rack: return rack(&lens, applied: applied) != nil
        case .rackDuration(let longer): stepRackDuration(longer: longer)
        }
        return true
    }

    mutating func setLens(_ mm: Float, _ lens: inout LensControls) {
        lens.setLens(mm)
        pending.insert(.lens)
    }

    mutating func setFocus(_ metres: Float, _ lens: inout LensControls) {
        lens.setFocus(metres)
        pending.insert(.focus)
    }

    mutating func setFstop(_ fstop: Float, _ lens: inout LensControls) {
        lens.setFstop(fstop)
        pending.insert(.fstop)
    }

    mutating func setDoF(_ on: Bool, _ lens: inout LensControls) {
        lens.setDoF(on)
        pending.insert(.dof)
    }

    /// Tap-to-focus: the host picks the distance, so the shown focus follows STATUS again.
    mutating func tap(u: Float, v: Float, _ lens: inout LensControls) -> Bool {
        guard lens.tap(u: u, v: v) else { return false }
        pending.remove(.focus)
        return true
    }

    /// Stores the shown focus as mark A or B; false if no focus is known yet.
    mutating func setMark(_ target: UInt8, _ lens: inout LensControls, applied: VCPAppliedLens?) -> Bool {
        guard let focus = shown(lens, applied: applied).focusM else { return false }
        lens.setMark(target, to: focus)
        return true
    }

    /// Racks to the mark farther from the shown focus over `rackDurationMS`; the target, or nil
    /// without marks.
    mutating func rack(_ lens: inout LensControls, applied: VCPAppliedLens?) -> UInt8? {
        let focus = shown(lens, applied: applied).focusM
        guard let target = LensInput.rackTarget(focus: focus, markA: lens.markA, markB: lens.markB),
            lens.startRack(to: target, durationMS: rackDurationMS)
        else { return nil }
        pending.remove(.focus)
        return target
    }

    mutating func stepRackDuration(longer: Bool) {
        rackDurationMS = LensInput.rackDuration(from: rackDurationMS, longer: longer)
    }
}
