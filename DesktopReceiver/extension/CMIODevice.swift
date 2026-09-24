// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary
// Phase 3: CMIOExtensionDeviceSource — virtual camera device entity.

import CoreMediaIO
import Foundation

/// Virtual camera device source.
/// Configures supported video formats, owns the stream, responds to system queries.
class VCamDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var streamSource: VCamStreamSource!

    init(localizedName: String) {
        super.init()

        let deviceID = UUID()
        streamSource = VCamStreamSource()

        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: deviceID,
            legacyDeviceID: nil,
            source: self
        )

        do {
            try device.addStream(streamSource.stream)
            logger.info("Device created: \(localizedName) [\(deviceID.uuidString)]")
        } catch {
            logger.error("Failed to add stream: \(error.localizedDescription)")
        }
    }

    /// Access the stream source for pushing frames externally.
    var stream: VCamStreamSource {
        return streamSource
    }

    // MARK: - CMIOExtensionDeviceSource

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = 5  // kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "VCam Blender Virtual Camera"
        }
        return deviceProperties
    }

    func setDeviceProperties(
        _ deviceProperties: CMIOExtensionDeviceProperties
    ) throws {
        // Read-only properties
    }
}
