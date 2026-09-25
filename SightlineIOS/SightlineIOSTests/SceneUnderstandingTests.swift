import ARKit
import XCTest

/// LiDAR scene reconstruction and plane detection when supported (task 1.4.4b; FR-TRK-004).
final class SceneUnderstandingTests: XCTestCase {
    func testMeshOnlyWhenSupportedPlanesAlways() {
        let lidar = SceneUnderstanding.best(meshSupported: true)
        XCTAssertEqual(lidar.sceneReconstruction, .mesh)
        XCTAssertEqual(lidar.planeDetection, [.horizontal, .vertical])
        XCTAssertEqual(lidar.summary, "LiDAR mesh + planes")

        let noLidar = SceneUnderstanding.best(meshSupported: false)
        XCTAssertEqual(noLidar.sceneReconstruction, [], "never ask for a mesh the device can't build")
        XCTAssertEqual(noLidar.planeDetection, [.horizontal, .vertical])
        XCTAssertEqual(noLidar.summary, "Planes")
    }

    func testThisDeviceFollowsARKitSupport() {
        // The simulator has no LiDAR; on a device this follows the same ARKit query.
        let supported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        XCTAssertEqual(SceneUnderstanding.forThisDevice(), .best(meshSupported: supported))
    }

    func testConfigurationKeepsGravityAlignmentAndCarriesTheAids() {
        for meshSupported in [false, true] {
            let understanding = SceneUnderstanding.best(meshSupported: meshSupported)
            let configuration = understanding.makeConfiguration()
            // vcp.md §7's canonical axes assume a gravity-aligned world.
            XCTAssertEqual(configuration.worldAlignment, .gravity)
            XCTAssertEqual(configuration.planeDetection, understanding.planeDetection)
            XCTAssertEqual(configuration.sceneReconstruction, understanding.sceneReconstruction)
        }
    }
}
