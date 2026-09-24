// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary
// ObjC++ bridge between C++ FrameBuffer and CoreMediaIO types.

#pragma once

#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

/// Create a CVPixelBuffer from raw BGRA pixel data.
/// The pixel data is copied into the CVPixelBuffer (safe for async use).
/// @param pixel_data Pointer to BGRA pixel data.
/// @param width Frame width in pixels.
/// @param height Frame height in pixels.
/// @param bytes_per_row Stride (typically width * 4 for BGRA).
/// @return CVPixelBufferRef (caller owns, must CFRelease). NULL on failure.
void* vcam_bridge_create_pixel_buffer(
    const void* pixel_data,
    uint32_t width,
    uint32_t height,
    uint32_t bytes_per_row
);

/// Create a CMSampleBuffer wrapping a CVPixelBuffer with timing info.
/// @param pixel_buffer CVPixelBufferRef (retained by the sample buffer).
/// @param timestamp_ns Presentation timestamp in nanoseconds.
/// @return CMSampleBufferRef (caller owns, must CFRelease). NULL on failure.
void* vcam_bridge_create_sample_buffer(
    void* pixel_buffer,
    uint64_t timestamp_ns
);

/// Create a CVPixelBuffer filled with a solid color (for testing).
/// @return CVPixelBufferRef (caller owns). NULL on failure.
void* vcam_bridge_create_test_frame(
    uint32_t width,
    uint32_t height,
    uint8_t red,
    uint8_t green,
    uint8_t blue
);

#ifdef __cplusplus
}
#endif
