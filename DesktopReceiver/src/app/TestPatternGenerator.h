// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <thread>

#include "../core/FrameBuffer.h"

namespace vcam {

/// Generates test pattern frames for verifying the video pipeline.
/// Produces SMPTE-style color bars at a configurable frame rate.
class TestPatternGenerator {
public:
    using FrameCallback = std::function<void(const FrameBuffer&)>;

    TestPatternGenerator(uint32_t width, uint32_t height, float fps,
                         FrameCallback on_frame);
    ~TestPatternGenerator();

    void start();
    void stop();
    bool isRunning() const { return running_.load(std::memory_order_relaxed); }

private:
    void generateLoop();
    void fillColorBars(FrameBuffer& fb, uint32_t frame_number);

    uint32_t width_;
    uint32_t height_;
    float fps_;
    FrameCallback on_frame_;
    std::atomic<bool> running_{false};
    std::thread thread_;
};

} // namespace vcam
