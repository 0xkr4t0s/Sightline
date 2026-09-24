// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary
// Phase 5: Linux virtual camera via v4l2loopback (stub)

#include "V4L2LoopbackCamera.h"

namespace vcam {

bool V4L2LoopbackCamera::initialize(const CameraConfig&) { return false; }
bool V4L2LoopbackCamera::startStream() { return false; }
void V4L2LoopbackCamera::stopStream() {}
bool V4L2LoopbackCamera::pushFrame(const FrameBuffer&) { return false; }
std::string V4L2LoopbackCamera::deviceName() const { return "VCam Blender (V4L2)"; }
bool V4L2LoopbackCamera::isStreaming() const { return false; }

} // namespace vcam
