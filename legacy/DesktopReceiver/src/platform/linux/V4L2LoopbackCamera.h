// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary
// Phase 5: Linux virtual camera via v4l2loopback (stub)

#pragma once

#include "../core/IVirtualCamera.h"

namespace vcam {

/// Linux virtual camera implementation via v4l2loopback.
/// Phase 5 implementation.
class V4L2LoopbackCamera : public IVirtualCamera {
public:
    bool initialize(const CameraConfig& config) override;
    bool startStream() override;
    void stopStream() override;
    bool pushFrame(const FrameBuffer& frame) override;
    std::string deviceName() const override;
    bool isStreaming() const override;
};

} // namespace vcam
