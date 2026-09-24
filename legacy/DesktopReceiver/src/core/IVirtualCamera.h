// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#pragma once

#include <cstdint>
#include <string>

#include "FrameBuffer.h"

namespace vcam {

/// Video format description for virtual camera output.
struct CameraConfig {
    uint32_t width = 1920;
    uint32_t height = 1080;
    float fps = 30.0f;
    enum class PixelFormat : uint8_t {
        BGRA,          // 32BGRA — universal compatibility
        YUV422,        // 422YpCbCr8 — broadcast standard
    } pixel_format = PixelFormat::BGRA;
};

/// Abstract base class for platform virtual camera implementations.
///
/// Each platform (macOS CMIO, Linux V4L2, Windows DirectShow) provides
/// a concrete implementation. The core application interacts only through
/// this interface, enabling cross-platform compilation from a single codebase.
class IVirtualCamera {
public:
    virtual ~IVirtualCamera() = default;

    /// Initialize the virtual camera with the given format.
    /// @return true on success.
    virtual bool initialize(const CameraConfig& config) = 0;

    /// Begin streaming frames to consuming applications.
    virtual bool startStream() = 0;

    /// Stop streaming and release system resources.
    virtual void stopStream() = 0;

    /// Push a decoded video frame to the virtual camera output.
    /// @param frame Ref-counted frame buffer. Must match the configured format.
    /// @return true if the frame was accepted.
    virtual bool pushFrame(const FrameBuffer& frame) = 0;

    /// Human-readable device name shown to users (e.g., "VCam Blender").
    virtual std::string deviceName() const = 0;

    /// Whether the camera is currently streaming.
    virtual bool isStreaming() const = 0;
};

} // namespace vcam
