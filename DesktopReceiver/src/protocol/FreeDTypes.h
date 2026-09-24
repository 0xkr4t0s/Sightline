// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#pragma once

#include <cstdint>

namespace vcam {

/// Decoded FreeD D1 camera tracking frame.
struct FreeDFrame {
    uint8_t camera_id = 0;
    float pitch = 0.0f;    // degrees
    float yaw = 0.0f;      // degrees
    float roll = 0.0f;     // degrees
    float pos_x = 0.0f;    // meters
    float pos_y = 0.0f;    // meters
    float pos_z = 0.0f;    // meters
    uint16_t zoom = 0;     // raw encoder 0-4095
    uint16_t focus = 0;    // raw encoder 0-4095
    uint64_t timestamp_ns = 0;  // monotonic nanoseconds
};

} // namespace vcam
