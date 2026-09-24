// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#include <gtest/gtest.h>

#include "FreeDParser.h"
#include "FreeDTypes.h"

#include <array>
#include <cmath>

using namespace vcam;

TEST(FreeDParser, RejectsEmptyData) {
    std::array<uint8_t, 0> empty{};
    auto result = FreeDParser::parse(std::span<const uint8_t>(empty.data(), 0));
    EXPECT_FALSE(result.has_value());
}

TEST(FreeDParser, RejectsTruncatedPacket) {
    std::array<uint8_t, 10> short_data{};
    short_data[0] = FreeDParser::D1_MARKER;
    auto result = FreeDParser::parse(short_data);
    EXPECT_FALSE(result.has_value());
}

TEST(FreeDParser, RejectsWrongMarker) {
    std::array<uint8_t, 29> data{};
    data[0] = 0xD2;  // Wrong marker
    auto result = FreeDParser::parse(data);
    EXPECT_FALSE(result.has_value());
}

TEST(FreeDParser, RejectsBadChecksum) {
    // Create a valid-looking packet with wrong checksum
    FreeDFrame frame;
    frame.camera_id = 1;
    frame.pitch = 10.0f;
    frame.yaw = -5.0f;
    auto encoded = FreeDParser::encode(frame);

    // Corrupt the checksum
    encoded[28] = static_cast<uint8_t>(encoded[28] + 1);

    auto result = FreeDParser::parse(encoded);
    EXPECT_FALSE(result.has_value());
}

TEST(FreeDParser, EncodeDecodeRoundtrip) {
    FreeDFrame original;
    original.camera_id = 1;
    original.pitch = 15.5f;
    original.yaw = -30.0f;
    original.roll = 5.25f;
    original.pos_x = 1.5f;
    original.pos_y = -0.75f;
    original.pos_z = 2.0f;
    original.zoom = 2048;
    original.focus = 1024;

    auto encoded = FreeDParser::encode(original);
    ASSERT_EQ(encoded.size(), FreeDParser::D1_LENGTH);
    EXPECT_EQ(encoded[0], FreeDParser::D1_MARKER);

    auto decoded = FreeDParser::parse(encoded);
    ASSERT_TRUE(decoded.has_value());

    auto& f = decoded.value();
    EXPECT_EQ(f.camera_id, original.camera_id);
    EXPECT_NEAR(f.pitch, original.pitch, 0.01f);
    EXPECT_NEAR(f.yaw, original.yaw, 0.01f);
    EXPECT_NEAR(f.roll, original.roll, 0.01f);
    EXPECT_NEAR(f.pos_x, original.pos_x, 0.001f);
    EXPECT_NEAR(f.pos_y, original.pos_y, 0.001f);
    EXPECT_NEAR(f.pos_z, original.pos_z, 0.001f);
    EXPECT_EQ(f.zoom, original.zoom);
    EXPECT_EQ(f.focus, original.focus);
}

TEST(FreeDParser, ZeroFrame) {
    FreeDFrame zero{};
    zero.camera_id = 0;

    auto encoded = FreeDParser::encode(zero);
    auto decoded = FreeDParser::parse(encoded);
    ASSERT_TRUE(decoded.has_value());

    EXPECT_EQ(decoded->camera_id, 0);
    EXPECT_NEAR(decoded->pitch, 0.0f, 0.001f);
    EXPECT_NEAR(decoded->pos_x, 0.0f, 0.001f);
}

TEST(FreeDParser, NegativeAngles) {
    FreeDFrame frame;
    frame.camera_id = 5;
    frame.pitch = -45.0f;
    frame.yaw = -180.0f;
    frame.roll = -90.0f;
    frame.pos_x = -10.0f;
    frame.pos_y = -20.0f;
    frame.pos_z = -5.0f;

    auto encoded = FreeDParser::encode(frame);
    auto decoded = FreeDParser::parse(encoded);
    ASSERT_TRUE(decoded.has_value());

    EXPECT_NEAR(decoded->pitch, -45.0f, 0.01f);
    EXPECT_NEAR(decoded->yaw, -180.0f, 0.01f);
    EXPECT_NEAR(decoded->roll, -90.0f, 0.01f);
    EXPECT_NEAR(decoded->pos_x, -10.0f, 0.01f);
}
