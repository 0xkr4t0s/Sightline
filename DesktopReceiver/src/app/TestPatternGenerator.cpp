// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#include "TestPatternGenerator.h"

#include <chrono>
#include <cstring>
#include <iostream>

namespace vcam {

// SMPTE color bar colors (BGRA format)
static constexpr uint8_t COLOR_BARS[][4] = {
    {235, 235, 235, 255},  // White
    {16,  235, 235, 255},  // Yellow
    {235, 235, 16,  255},  // Cyan
    {16,  235, 16,  255},  // Green
    {235, 16,  235, 255},  // Magenta
    {16,  16,  235, 255},  // Red
    {235, 16,  16,  255},  // Blue
};

TestPatternGenerator::TestPatternGenerator(
    uint32_t width, uint32_t height, float fps,
    FrameCallback on_frame)
    : width_(width)
    , height_(height)
    , fps_(fps)
    , on_frame_(std::move(on_frame))
{}

TestPatternGenerator::~TestPatternGenerator() {
    stop();
}

void TestPatternGenerator::start() {
    if (running_.load()) return;
    running_.store(true, std::memory_order_release);
    thread_ = std::thread(&TestPatternGenerator::generateLoop, this);
    std::cerr << "[TestPattern] Generating " << width_ << "x" << height_
              << " @ " << fps_ << "fps\n";
}

void TestPatternGenerator::stop() {
    running_.store(false, std::memory_order_release);
    if (thread_.joinable()) {
        thread_.join();
    }
}

void TestPatternGenerator::generateLoop() {
    const auto frame_duration = std::chrono::nanoseconds(
        static_cast<int64_t>(1e9 / fps_));
    auto next_frame_time = std::chrono::steady_clock::now();
    uint32_t frame_number = 0;

    while (running_.load(std::memory_order_acquire)) {
        FrameBuffer fb(width_, height_, 4);  // BGRA = 4 bytes/pixel
        fillColorBars(fb, frame_number);

        auto now = std::chrono::steady_clock::now();
        fb.setTimestamp(static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                now.time_since_epoch()).count()));

        on_frame_(fb);

        frame_number++;
        next_frame_time += frame_duration;

        auto sleep_time = next_frame_time - std::chrono::steady_clock::now();
        if (sleep_time.count() > 0) {
            std::this_thread::sleep_for(sleep_time);
        }
    }
}

void TestPatternGenerator::fillColorBars(FrameBuffer& fb, uint32_t frame_number) {
    uint8_t* data = fb.data();
    if (!data) return;

    constexpr int NUM_BARS = 7;
    uint32_t bar_width = width_ / NUM_BARS;

    // Animate: shift bars slowly for visual verification
    uint32_t shift = (frame_number / 2) % width_;

    for (uint32_t y = 0; y < height_; ++y) {
        for (uint32_t x = 0; x < width_; ++x) {
            uint32_t shifted_x = (x + shift) % width_;
            int bar_index = static_cast<int>(shifted_x / bar_width);
            if (bar_index >= NUM_BARS) bar_index = NUM_BARS - 1;

            uint32_t offset = (y * fb.stride()) + (x * 4);
            data[offset + 0] = COLOR_BARS[bar_index][0]; // B
            data[offset + 1] = COLOR_BARS[bar_index][1]; // G
            data[offset + 2] = COLOR_BARS[bar_index][2]; // R
            data[offset + 3] = COLOR_BARS[bar_index][3]; // A
        }
    }
}

} // namespace vcam
