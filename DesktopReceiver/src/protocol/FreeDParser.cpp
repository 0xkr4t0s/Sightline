// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#include "FreeDParser.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <numeric>

namespace vcam {

int32_t FreeDParser::decode24Signed(const uint8_t* data) {
    int32_t val = (static_cast<int32_t>(data[0]) << 16)
               | (static_cast<int32_t>(data[1]) << 8)
               | static_cast<int32_t>(data[2]);
    // Sign extension from 24-bit
    if (val & 0x800000) {
        val -= 0x1000000;
    }
    return val;
}

uint32_t FreeDParser::decode24Unsigned(const uint8_t* data) {
    return (static_cast<uint32_t>(data[0]) << 16)
         | (static_cast<uint32_t>(data[1]) << 8)
         | static_cast<uint32_t>(data[2]);
}

bool FreeDParser::validateChecksum(std::span<const uint8_t> data) {
    uint32_t sum = 0;
    for (size_t i = 0; i < 28; ++i) {
        sum += data[i];
    }
    uint8_t expected = static_cast<uint8_t>((0x40 - sum) & 0xFF);
    return expected == data[28];
}

std::optional<FreeDFrame> FreeDParser::parse(std::span<const uint8_t> data) {
    if (data.size() < D1_LENGTH) {
        return std::nullopt;
    }
    if (data[0] != D1_MARKER) {
        return std::nullopt;
    }
    if (!validateChecksum(data)) {
        return std::nullopt;
    }

    auto now = std::chrono::steady_clock::now();
    auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
        now.time_since_epoch()).count();

    FreeDFrame frame;
    frame.camera_id = data[1];

    frame.pitch = static_cast<float>(decode24Signed(&data[2])) / ROTATION_DIVISOR;
    frame.yaw   = static_cast<float>(decode24Signed(&data[5])) / ROTATION_DIVISOR;
    frame.roll  = static_cast<float>(decode24Signed(&data[8])) / ROTATION_DIVISOR;

    frame.pos_z = (static_cast<float>(decode24Signed(&data[11])) / POSITION_DIVISOR) * MM_TO_METERS;
    frame.pos_y = (static_cast<float>(decode24Signed(&data[14])) / POSITION_DIVISOR) * MM_TO_METERS;
    frame.pos_x = (static_cast<float>(decode24Signed(&data[17])) / POSITION_DIVISOR) * MM_TO_METERS;

    int32_t zoom_raw = static_cast<int32_t>(decode24Unsigned(&data[20])) - LENS_OFFSET;
    int32_t focus_raw = static_cast<int32_t>(decode24Unsigned(&data[23])) - LENS_OFFSET;

    frame.zoom = static_cast<uint16_t>(std::max(0, zoom_raw));
    frame.focus = static_cast<uint16_t>(std::max(0, focus_raw));
    frame.timestamp_ns = static_cast<uint64_t>(ns);

    return frame;
}

std::array<uint8_t, FreeDParser::D1_LENGTH> FreeDParser::encode(const FreeDFrame& frame) {
    std::array<uint8_t, D1_LENGTH> buf{};
    buf[0] = D1_MARKER;
    buf[1] = frame.camera_id;

    auto encode24s = [&buf](int32_t val, size_t offset) {
        if (val < 0) val += 0x1000000;
        buf[offset]     = static_cast<uint8_t>((val >> 16) & 0xFF);
        buf[offset + 1] = static_cast<uint8_t>((val >> 8) & 0xFF);
        buf[offset + 2] = static_cast<uint8_t>(val & 0xFF);
    };

    auto encode24u = [&buf](uint32_t val, size_t offset) {
        buf[offset]     = static_cast<uint8_t>((val >> 16) & 0xFF);
        buf[offset + 1] = static_cast<uint8_t>((val >> 8) & 0xFF);
        buf[offset + 2] = static_cast<uint8_t>(val & 0xFF);
    };

    encode24s(static_cast<int32_t>(frame.pitch * ROTATION_DIVISOR), 2);
    encode24s(static_cast<int32_t>(frame.yaw * ROTATION_DIVISOR), 5);
    encode24s(static_cast<int32_t>(frame.roll * ROTATION_DIVISOR), 8);

    encode24s(static_cast<int32_t>(frame.pos_z / MM_TO_METERS * POSITION_DIVISOR), 11);
    encode24s(static_cast<int32_t>(frame.pos_y / MM_TO_METERS * POSITION_DIVISOR), 14);
    encode24s(static_cast<int32_t>(frame.pos_x / MM_TO_METERS * POSITION_DIVISOR), 17);

    encode24u(static_cast<uint32_t>(frame.zoom + LENS_OFFSET), 20);
    encode24u(static_cast<uint32_t>(frame.focus + LENS_OFFSET), 23);

    // Checksum
    uint32_t sum = 0;
    for (size_t i = 0; i < 28; ++i) {
        sum += buf[i];
    }
    buf[28] = static_cast<uint8_t>((0x40 - sum) & 0xFF);

    return buf;
}

} // namespace vcam
