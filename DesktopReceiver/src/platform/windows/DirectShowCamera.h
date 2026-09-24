// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary
// Phase 5+: Windows virtual camera via DirectShow/Media Foundation (stub)

#pragma once

#include "../core/IVirtualCamera.h"

namespace vcam {

class DirectShowCamera : public IVirtualCamera {
public:
    bool initialize(const CameraConfig& config) override;
    bool startStream() override;
    void stopStream() override;
    bool pushFrame(const FrameBuffer& frame) override;
    std::string deviceName() const override;
    bool isStreaming() const override;
};

} // namespace vcam
