import Foundation

/// Inclusive wire ranges of the T2 lens fields (docs/protocol/vcp.md §6.2, §6.4).
nonisolated enum VCPLensRange {
    static let lensMM: ClosedRange<Float> = 1...2500
    static let distanceM: ClosedRange<Float> = 0.01...100_000
    static let fstop: ClosedRange<Float> = 0.1...128
    static let tap: ClosedRange<Float> = 0...1
    static let sensorWidthMM: ClosedRange<Float> = 1...1000
    static let renderAspect: ClosedRange<Float> = 0.1...10
    static let rackDurationMS: ClosedRange<UInt16> = 0...60_000

    static func contains(_ value: Float, _ range: ClosedRange<Float>) -> Bool {
        value.isFinite && range.contains(value)
    }
}

/// Tap-to-focus request (`CONTROL_STATE` bit 8, vcp.md §6.2).
nonisolated struct VCPTapFocus: Equatable, Sendable {
    /// Normalized position in the streamed picture: 0 at the left / top.
    var u: Float
    var v: Float
    /// Request identity: a change (including the wrap) starts one tap on the host.
    var seq: UInt16

    var isValid: Bool {
        VCPLensRange.contains(u, VCPLensRange.tap) && VCPLensRange.contains(v, VCPLensRange.tap)
    }
}

/// Host-executed A/B focus rack (`CONTROL_STATE` bit 9, vcp.md §6.2).
nonisolated struct VCPRackFocus: Equatable, Sendable {
    static let targetNone: UInt8 = 0
    static let targetA: UInt8 = 1
    static let targetB: UInt8 = 2

    /// A and B marks along the view axis, metres.
    var aM: Float
    var bM: Float
    var target: UInt8
    /// 0 jumps to the target at once.
    var durationMS: UInt16
    /// Request identity: a change (including the wrap) starts one rack if `target` ≠ 0.
    var seq: UInt16

    var isValid: Bool {
        VCPLensRange.contains(aM, VCPLensRange.distanceM) && VCPLensRange.contains(bM, VCPLensRange.distanceM)
            && target <= Self.targetB && VCPLensRange.rackDurationMS.contains(durationMS)
    }
}

/// The lens the host camera actually has (`STATUS` flags bit 2, vcp.md §6.4), not the device's
/// request.
nonisolated struct VCPAppliedLens: Equatable, Sendable {
    static let length = 24
    static let fitHorizontal: UInt8 = 0
    static let fitAuto: UInt8 = 2
    /// Diagonal of the 36 × 24 mm reference frame, rounded as §6.4 specifies.
    static let fullFrameDiagonalMM = 43.27

    var lensMM: Float
    /// Along the view axis, metres.
    var focusDistanceM: Float
    var fstop: Float
    var dofOn: Bool
    /// Blender's `sensor_fit`: 0 horizontal, 1 vertical, 2 auto.
    var sensorFit: UInt8
    var sensorWidthMM: Float
    /// Scene `resolution_x × pixel_aspect_x / (resolution_y × pixel_aspect_y)`.
    var renderAspect: Float

    var isValid: Bool {
        VCPLensRange.contains(lensMM, VCPLensRange.lensMM)
            && VCPLensRange.contains(focusDistanceM, VCPLensRange.distanceM)
            && VCPLensRange.contains(fstop, VCPLensRange.fstop) && sensorFit <= Self.fitAuto
            && VCPLensRange.contains(sensorWidthMM, VCPLensRange.sensorWidthMM)
            && VCPLensRange.contains(renderAspect, VCPLensRange.renderAspect)
    }

    /// Horizontal field of view in degrees and 35 mm-equivalent focal length in mm (§6.4), from the
    /// binary32 wire values in double precision. `nil` unless the fit is horizontal: a vertical or
    /// auto fit also depends on the sensor height, which STATUS doesn't carry.
    var horizontalFOVAndEquivalent: (fovDegrees: Double, equivalentMM: Double)? {
        guard sensorFit == Self.fitHorizontal, isValid else { return nil }
        let width = Double(sensorWidthMM)
        let lens = Double(lensMM)
        let diagonal = (width * width + (width / Double(renderAspect)) * (width / Double(renderAspect))).squareRoot()
        return (2 * atan(width / (2 * lens)) * 180 / .pi, lens * Self.fullFrameDiagonalMM / diagonal)
    }

    static func decode(_ block: ArraySlice<UInt8>) throws(VCPPayloadError) -> VCPAppliedLens {
        var r = VCPReader(block)
        guard let lens = r.f32(), let focus = r.f32(), let fstop = r.f32(), let dof = r.u8(), let fit = r.u8(),
            r.skip(2), let width = r.f32(), let aspect = r.f32()
        else { throw .tooShort }
        guard dof <= 1 else { throw .lensRange }
        let applied = VCPAppliedLens(
            lensMM: lens, focusDistanceM: focus, fstop: fstop, dofOn: dof == 1, sensorFit: fit,
            sensorWidthMM: width, renderAspect: aspect)
        guard applied.isValid else { throw .lensRange }
        return applied
    }

    func encode(into out: inout [UInt8]) throws(VCPPayloadError) {
        guard isValid else { throw .lensRange }
        for value in [lensMM, focusDistanceM, fstop] { out.appendLE(value.bitPattern) }
        out.append(contentsOf: [dofOn ? 1 : 0, sensorFit, 0, 0])
        out.appendLE(sensorWidthMM.bitPattern)
        out.appendLE(renderAspect.bitPattern)
    }
}

/// `CONTROL_STATE` bits 4–9: fixed offsets, whatever the earlier bits say (§6.2).
nonisolated enum VCPLensLayout {
    static let lensBit: UInt32 = 1 << 4
    static let focusBit: UInt32 = 1 << 5
    static let fstopBit: UInt32 = 1 << 6
    static let dofBit: UInt32 = 1 << 7
    static let tapBit: UInt32 = 1 << 8
    static let rackBit: UInt32 = 1 << 9
    static let lens = 20..<24
    static let focus = 24..<28
    static let fstop = 28..<32
    static let dof = 32..<36
    static let tap = 36..<48
    static let rack = 48..<64

    /// The present group at its offset in `payload`, or `nil` if its bit is clear. A set bit needs
    /// the whole group; bytes behind a clear bit are never read.
    static func group(
        _ payload: ArraySlice<UInt8>, _ fields: UInt32, _ bit: UInt32, _ bytes: Range<Int>
    ) throws(VCPPayloadError) -> VCPReader? {
        guard fields & bit != 0 else { return nil }
        guard payload.count >= bytes.upperBound else { throw .tooShort }
        let start = payload.startIndex
        return VCPReader(payload[start + bytes.lowerBound..<start + bytes.upperBound])
    }

    static func float(
        _ payload: ArraySlice<UInt8>, _ fields: UInt32, _ bit: UInt32, _ bytes: Range<Int>,
        _ range: ClosedRange<Float>
    ) throws(VCPPayloadError) -> Float? {
        guard var r = try group(payload, fields, bit, bytes) else { return nil }
        guard let value = r.f32() else { throw .tooShort }
        guard VCPLensRange.contains(value, range) else { throw .lensRange }
        return value
    }

    static func tap(_ payload: ArraySlice<UInt8>, _ fields: UInt32) throws(VCPPayloadError) -> VCPTapFocus? {
        guard var r = try group(payload, fields, tapBit, tap) else { return nil }
        guard let u = r.f32(), let v = r.f32(), let seq = r.u16() else { throw .tooShort }
        let tap = VCPTapFocus(u: u, v: v, seq: seq)
        guard tap.isValid else { throw .lensRange }
        return tap
    }

    static func rack(_ payload: ArraySlice<UInt8>, _ fields: UInt32) throws(VCPPayloadError) -> VCPRackFocus? {
        guard var r = try group(payload, fields, rackBit, rack) else { return nil }
        guard let a = r.f32(), let b = r.f32(), let target = r.u8(), r.skip(1), let duration = r.u16(),
            let seq = r.u16()
        else { throw .tooShort }
        let rack = VCPRackFocus(aM: a, bM: b, target: target, durationMS: duration, seq: seq)
        guard rack.isValid else { throw .lensRange }
        return rack
    }
}
