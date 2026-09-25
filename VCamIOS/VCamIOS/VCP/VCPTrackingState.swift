import ARKit

/// `POSE.tracking_state` codes (docs/protocol/vcp.md §6.1, FR-TRK-002).
nonisolated enum VCPTrackingState {
    static let notAvailable: UInt8 = 0
    static let initializing: UInt8 = 1
    static let excessiveMotion: UInt8 = 2
    static let insufficientFeatures: UInt8 = 3
    static let relocalizing: UInt8 = 4
    static let normal: UInt8 = 5
    static let limitedOther: UInt8 = 6

    static func code(for state: ARCamera.TrackingState) -> UInt8 {
        switch state {
        case .notAvailable:
            return notAvailable
        case .normal:
            return normal
        case .limited(let reason):
            switch reason {
            case .initializing:
                return initializing
            case .excessiveMotion:
                return excessiveMotion
            case .insufficientFeatures:
                return insufficientFeatures
            case .relocalizing:
                return relocalizing
            @unknown default:
                return limitedOther
            }
        }
    }
}
