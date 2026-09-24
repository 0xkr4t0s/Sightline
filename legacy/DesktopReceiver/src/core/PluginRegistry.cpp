// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#include "PluginRegistry.h"

#include <iostream>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace vcam {

PluginRegistry::~PluginRegistry() {
    for (auto& plugin : plugins_) {
        if (plugin.handle) {
#ifdef _WIN32
            FreeLibrary(static_cast<HMODULE>(plugin.handle));
#else
            dlclose(plugin.handle);
#endif
        }
    }
}

bool PluginRegistry::loadPlugin(const std::string& path) {
#ifdef _WIN32
    void* handle = static_cast<void*>(LoadLibraryA(path.c_str()));
#else
    void* handle = dlopen(path.c_str(), RTLD_LAZY);
#endif
    if (!handle) {
        std::cerr << "[PluginRegistry] Failed to load: " << path << "\n";
        return false;
    }

    // Resolve plugin descriptor
#ifdef _WIN32
    auto desc_fn = reinterpret_cast<VCamPluginDescFn>(
        GetProcAddress(static_cast<HMODULE>(handle), "vcam_get_plugin_desc"));
    auto factory_fn = reinterpret_cast<VCamCreateCameraFn>(
        GetProcAddress(static_cast<HMODULE>(handle), "vcam_create_camera"));
#else
    auto desc_fn = reinterpret_cast<VCamPluginDescFn>(dlsym(handle, "vcam_get_plugin_desc"));
    auto factory_fn = reinterpret_cast<VCamCreateCameraFn>(dlsym(handle, "vcam_create_camera"));
#endif

    if (!desc_fn || !factory_fn) {
        std::cerr << "[PluginRegistry] Missing entry points in: " << path << "\n";
#ifdef _WIN32
        FreeLibrary(static_cast<HMODULE>(handle));
#else
        dlclose(handle);
#endif
        return false;
    }

    const PluginDesc* desc = desc_fn();
    if (!desc) {
        std::cerr << "[PluginRegistry] Null descriptor from: " << path << "\n";
#ifdef _WIN32
        FreeLibrary(static_cast<HMODULE>(handle));
#else
        dlclose(handle);
#endif
        return false;
    }

    plugins_.push_back({handle, desc, factory_fn});
    std::cerr << "[PluginRegistry] Loaded: " << desc->name
              << " v" << desc->version
              << " (" << desc->platform << ")\n";
    return true;
}

std::unique_ptr<IVirtualCamera> PluginRegistry::createCamera() const {
    if (plugins_.empty()) {
        return nullptr;
    }
    // Use first available plugin
    IVirtualCamera* cam = plugins_.front().factory();
    return std::unique_ptr<IVirtualCamera>(cam);
}

std::vector<const PluginDesc*> PluginRegistry::plugins() const {
    std::vector<const PluginDesc*> result;
    result.reserve(plugins_.size());
    for (const auto& p : plugins_) {
        result.push_back(p.desc);
    }
    return result;
}

} // namespace vcam
