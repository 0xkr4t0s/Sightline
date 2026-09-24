import simd

/// ARKit (Y up, `worldAlignment = .gravity`) → canonical/Blender axes (Z up), done once on the
/// device (docs/protocol/vcp.md §7, DM-002). No Euler angles (DM-003).
nonisolated enum VCPCoordinates {
    /// +90° about X: maps ARKit +Y (up) to canonical +Z.
    static let arkitToCanonical = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))

    /// Canonical position and orientation (x, y, z, w with w ≥ 0) for an ARKit camera transform.
    static func canonicalPose(fromARKit transform: simd_float4x4) -> (position: SIMD3<Float>, orientation: SIMD4<Float>) {
        let t = transform.columns.3
        let position = SIMD3<Float>(t.x, -t.z, t.y)
        let rotation = simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
        var q = (arkitToCanonical * simd_quatf(rotation)).normalized.vector
        if q.w < 0 { q = -q }
        return (position, q)
    }
}
