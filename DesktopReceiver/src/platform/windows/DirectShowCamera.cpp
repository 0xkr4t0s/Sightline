// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary
// Phase 5+: Windows virtual camera via DirectShow/Media Foundation (stub)

#include "DirectShowCamera.h"

namespace vcam {

bool DirectShowCamera::initialize(const CameraConfig&) { return false; }
bool DirectShowCamera::startStream() { return false; }
void DirectShowCamera::stopStream() {}
bool DirectShowCamera::pushFrame(const FrameBuffer&) { return false; }
std::string DirectShowCamera::deviceName() const { return "VCam Blender (DirectShow)"; }
bool DirectShowCamera::isStreaming() const { return false; }

} // namespace vcam
