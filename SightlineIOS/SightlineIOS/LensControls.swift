import Foundation

/// The operator's lens request (FR-CTL-001..003), sent as absolute state in every `CONTROL_STATE`
/// (vcp.md §6.2, FR-CTL-009). Values are clamped to the wire ranges when set, so a message built
/// from them always seals.
///
/// Blender owns the lens (LNS-001): focal length, focus, f-stop and DoF stay `nil` until the
/// operator sets them or `adopt` copies what the camera has, so connecting never changes the
/// camera. The tap and rack groups always go out: the host takes the first sequence it sees in a
/// session as a baseline, so they must be there before the first real request.
///
/// A tap or a rack hands the focus to the host: the focus request is cleared (bit 5 goes out
/// clear) and `adopt` doesn't refill it, so later changes don't undo the tap or rack, and the
/// operator's next focus, even at the earlier distance, is a new request that the host applies.
nonisolated struct LensControls: Equatable, Sendable {
    /// What an unset A/B mark goes out as. A rack to an unset mark is refused, so the host never
    /// uses it.
    static let unsetMarkM: Float = 1
    static let defaultRackDurationMS: UInt16 = 2000

    private(set) var lensMM: Float?
    private(set) var focusDistanceM: Float?
    /// True after a tap or rack until the operator sets a focus again.
    private(set) var focusFromHost = false
    private(set) var fstop: Float?
    private(set) var dofOn: Bool?
    private(set) var markA: Float?
    private(set) var markB: Float?
    /// The last tap point and its request identity (`tap_seq`).
    private(set) var tap = VCPTapFocus(u: 0.5, v: 0.5, seq: 0)
    private(set) var rackTarget = VCPRackFocus.targetNone
    private(set) var rackDurationMS = Self.defaultRackDurationMS
    /// Request identity of the last rack (`rack_seq`).
    private(set) var rackSeq: UInt16 = 0

    var rack: VCPRackFocus {
        VCPRackFocus(
            aM: markA ?? Self.unsetMarkM, bM: markB ?? Self.unsetMarkM, target: rackTarget,
            durationMS: rackDurationMS, seq: rackSeq)
    }

    /// `value` clamped into `range`, or nil if it isn't a number.
    static func clamp(_ value: Float, _ range: ClosedRange<Float>) -> Float? {
        guard value.isFinite else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    mutating func setLens(_ mm: Float) {
        if let mm = Self.clamp(mm, VCPLensRange.lensMM) { lensMM = mm }
    }

    /// A manual focus distance; on the host it also cancels a running rack (§6.2).
    mutating func setFocus(_ metres: Float) {
        guard let metres = Self.clamp(metres, VCPLensRange.distanceM) else { return }
        focusDistanceM = metres
        focusFromHost = false
    }

    mutating func setFstop(_ fstop: Float) {
        if let fstop = Self.clamp(fstop, VCPLensRange.fstop) { self.fstop = fstop }
    }

    mutating func setDoF(_ on: Bool) {
        dofOn = on
    }

    /// A new tap-to-focus at normalized coordinates in the streamed picture (0, 0 top left).
    /// Returns false, and changes nothing, for a non-number.
    @discardableResult
    mutating func tap(u: Float, v: Float) -> Bool {
        guard let u = Self.clamp(u, VCPLensRange.tap), let v = Self.clamp(v, VCPLensRange.tap) else { return false }
        tap = VCPTapFocus(u: u, v: v, seq: tap.seq &+ 1)
        handFocusToHost()
        return true
    }

    /// Stores focus mark A or B (`VCPRackFocus.targetA`/`targetB`).
    mutating func setMark(_ target: UInt8, to metres: Float) {
        guard let metres = Self.clamp(metres, VCPLensRange.distanceM) else { return }
        switch target {
        case VCPRackFocus.targetA: markA = metres
        case VCPRackFocus.targetB: markB = metres
        default: break
        }
    }

    /// Asks the host to rack focus to mark A or B over `durationMS` (clamped to 0...60 000; 0 jumps).
    /// Returns false, and changes nothing, if that mark isn't set.
    @discardableResult
    mutating func startRack(to target: UInt8, durationMS: Int) -> Bool {
        let mark =
            switch target {
            case VCPRackFocus.targetA: markA
            case VCPRackFocus.targetB: markB
            default: Float?.none
            }
        guard mark != nil else { return false }
        let range = VCPLensRange.rackDurationMS
        rackTarget = target
        rackDurationMS = UInt16(min(max(durationMS, Int(range.lowerBound)), Int(range.upperBound)))
        rackSeq &+= 1
        handFocusToHost()
        return true
    }

    private mutating func handFocusToHost() {
        focusDistanceM = nil
        focusFromHost = true
    }

    /// Fills the values the operator hasn't set (nor handed to the host with a tap or rack) from
    /// the camera's applied lens. Returns true if
    /// anything changed. Set values are never replaced: a host-side edit shows on the phone from
    /// STATUS without becoming the phone's request.
    @discardableResult
    mutating func adopt(_ applied: VCPAppliedLens) -> Bool {
        let before = self
        if lensMM == nil { setLens(applied.lensMM) }
        if focusDistanceM == nil, !focusFromHost { setFocus(applied.focusDistanceM) }
        if fstop == nil { setFstop(applied.fstop) }
        if dofOn == nil { dofOn = applied.dofOn }
        return self != before
    }

    /// Writes the lens groups (bits 4–9) into a state message.
    func fill(_ state: inout VCPControlState) {
        state.lensMM = lensMM
        state.focusDistanceM = focusDistanceM
        state.fstop = fstop
        state.dofOn = dofOn
        state.tap = tap
        state.rack = rack
    }
}
