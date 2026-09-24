// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#pragma once

#include <string>

namespace vcam {

/// Plugin descriptor interface.
///
/// Each dynamically loaded plugin (.dylib, .so, .dll) must export a
/// C function `vcam_get_plugin_desc()` returning a pointer to this struct.
/// The plugin registry uses these descriptors for discovery and factory creation.
struct PluginDesc {
    const char* name;        // Human-readable plugin name
    const char* version;     // Semantic version string
    const char* platform;    // "macos", "linux", "windows"
    const char* description; // One-line description
};

} // namespace vcam

/// C-linkage entry point that each plugin shared library must export.
extern "C" {
    using VCamPluginDescFn = const vcam::PluginDesc* (*)();
    using VCamCreateCameraFn = vcam::IVirtualCamera* (*)();
}
