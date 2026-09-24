// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace vcam {

/// Ref-counted video frame container.
///
/// Wraps raw pixel data with metadata (resolution, format, timestamp).
/// Uses shared_ptr semantics for zero-copy passing between threads.
class FrameBuffer {
public:
    FrameBuffer() = default;

    FrameBuffer(uint32_t width, uint32_t height, uint32_t bytes_per_pixel)
        : width_(width)
        , height_(height)
        , bytes_per_pixel_(bytes_per_pixel)
        , data_(std::make_shared<std::vector<uint8_t>>(
              static_cast<size_t>(width) * height * bytes_per_pixel))
    {}

    /// Direct access to pixel data.
    uint8_t* data() { return data_ ? data_->data() : nullptr; }
    const uint8_t* data() const { return data_ ? data_->data() : nullptr; }

    size_t size() const { return data_ ? data_->size() : 0; }
    uint32_t width() const { return width_; }
    uint32_t height() const { return height_; }
    uint32_t bytesPerPixel() const { return bytes_per_pixel_; }
    uint32_t stride() const { return width_ * bytes_per_pixel_; }

    /// Presentation timestamp in nanoseconds (monotonic clock).
    uint64_t timestamp() const { return timestamp_ns_; }
    void setTimestamp(uint64_t ns) { timestamp_ns_ = ns; }

    bool isValid() const { return data_ && !data_->empty(); }

private:
    uint32_t width_ = 0;
    uint32_t height_ = 0;
    uint32_t bytes_per_pixel_ = 4;  // BGRA default
    uint64_t timestamp_ns_ = 0;
    std::shared_ptr<std::vector<uint8_t>> data_;
};

} // namespace vcam
