import ARKit

/// The optional world-tracking aids turned on for stability when the device has them (FR-TRK-004):
/// plane detection on every device that runs world tracking, and LiDAR scene reconstruction
/// (`.mesh`) where `ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)` says so.
/// Neither changes what is sent: POSE still carries only the camera transform.
nonisolated struct SceneUnderstanding: Equatable, Sendable {
    var planeDetection: ARWorldTrackingConfiguration.PlaneDetection
    var sceneReconstruction: ARConfiguration.SceneReconstruction

    /// Planes always; the LiDAR mesh only on devices that report support for it.
    static func best(meshSupported: Bool) -> SceneUnderstanding {
        SceneUnderstanding(planeDetection: [.horizontal, .vertical],
                           sceneReconstruction: meshSupported ? .mesh : [])
    }

    static func forThisDevice() -> SceneUnderstanding {
        best(meshSupported: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh))
    }

    /// The session configuration: gravity-aligned world tracking (vcp.md §7) plus these aids.
    func makeConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = planeDetection
        configuration.sceneReconstruction = sceneReconstruction
        return configuration
    }

    /// A short label for the UI: "LiDAR mesh + planes", "Planes" or "Off".
    var summary: String {
        switch (sceneReconstruction.contains(.mesh), !planeDetection.isEmpty) {
        case (true, true): "LiDAR mesh + planes"
        case (true, false): "LiDAR mesh"
        case (false, true): "Planes"
        case (false, false): "Off"
        }
    }
}
