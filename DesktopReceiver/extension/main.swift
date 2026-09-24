// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary
// Phase 3: CMIO Extension entry point.

import CoreMediaIO
import Foundation

// Create the provider and start the CMIO extension service.
// This is the NSExtensionPrincipalClass entry point.
let providerSource = VCamProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

// Keep the extension alive
CFRunLoopRun()
