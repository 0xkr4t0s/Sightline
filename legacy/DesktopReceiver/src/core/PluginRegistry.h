// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#pragma once

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "IVirtualCamera.h"
#include "PluginDesc.h"

namespace vcam {

/// Factory and dynamic loader for platform virtual camera plugins.
///
/// Uses dlopen() on POSIX / LoadLibrary() on Windows to load
/// platform-specific shared libraries at runtime.
class PluginRegistry {
public:
    PluginRegistry() = default;
    ~PluginRegistry();

    // Non-copyable
    PluginRegistry(const PluginRegistry&) = delete;
    PluginRegistry& operator=(const PluginRegistry&) = delete;

    /// Load a plugin from a shared library path.
    /// @return true if the plugin was loaded and registered successfully.
    bool loadPlugin(const std::string& path);

    /// Create a virtual camera from the first available plugin.
    std::unique_ptr<IVirtualCamera> createCamera() const;

    /// List all registered plugin descriptors.
    std::vector<const PluginDesc*> plugins() const;

private:
    struct LoadedPlugin {
        void* handle = nullptr;
        const PluginDesc* desc = nullptr;
        VCamCreateCameraFn factory = nullptr;
    };

    std::vector<LoadedPlugin> plugins_;
};

} // namespace vcam
