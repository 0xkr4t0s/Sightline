// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary
// Phase 3: CMIOExtensionProviderSource — root singleton for the CMIO extension.

import CoreMediaIO
import Foundation
import os.log

let logger = Logger(subsystem: "com.vcamblender.receiver.extension", category: "CMIO")

/// Root provider source for the VCam Blender CMIO camera extension.
/// Manages device discovery and client connections.
class VCamProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: VCamDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        deviceSource = VCamDeviceSource(localizedName: "VCam Blender")
        provider = CMIOExtensionProvider(
            source: self,
            clientQueue: clientQueue
        )
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            logger.error("Failed to add device: \(error.localizedDescription)")
        }
        logger.info("VCam provider initialized")
    }

    // MARK: - CMIOExtensionProviderSource

    func connect(to client: CMIOExtensionClient) throws {
        logger.info("Client connected: \(client.description)")
    }

    func disconnect(from client: CMIOExtensionClient) {
        logger.info("Client disconnected: \(client.description)")
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "VCamBlender"
        }
        return providerProperties
    }

    func setProviderProperties(
        _ providerProperties: CMIOExtensionProviderProperties
    ) throws {
        // Read-only properties
    }
}
