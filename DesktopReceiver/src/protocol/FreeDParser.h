// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#pragma once

#include <cstdint>
#include <optional>
#include <span>

#include "IProtocolParser.h"
#include "FreeDTypes.h"

namespace vcam {

/// FreeD D1 protocol parser.
///
/// Parses 29-byte FreeD D1 camera tracking packets (BBC standard).
/// Zero-allocation — operates on a buffer view.
class FreeDParser : public IProtocolParser {
public:
    static constexpr uint8_t D1_MARKER = 0xD1;
    static constexpr size_t D1_LENGTH = 29;
    static constexpr float ROTATION_DIVISOR = 32768.0f;
    static constexpr float POSITION_DIVISOR = 64.0f;
    static constexpr float MM_TO_METERS = 0.001f;
    static constexpr int32_t LENS_OFFSET = 524288;

    /// Parse a raw FreeD D1 packet.
    /// @param data Raw 29-byte UDP payload.
    /// @return FreeDFrame if valid, std::nullopt on malformed/bad checksum.
    static std::optional<FreeDFrame> parse(std::span<const uint8_t> data);

    /// Encode a FreeDFrame into a 29-byte FreeD D1 packet (for testing).
    static std::array<uint8_t, D1_LENGTH> encode(const FreeDFrame& frame);

    // IProtocolParser interface
    const char* protocolName() const override { return "FreeD D1"; }
    size_t expectedSize() const override { return D1_LENGTH; }

private:
    /// Decode 3 bytes big-endian as signed 24-bit integer.
    static int32_t decode24Signed(const uint8_t* data);

    /// Decode 3 bytes big-endian as unsigned 24-bit integer.
    static uint32_t decode24Unsigned(const uint8_t* data);

    /// Validate FreeD checksum: (0x40 - sum(bytes[0:28])) & 0xFF == bytes[28]
    static bool validateChecksum(std::span<const uint8_t> data);
};

} // namespace vcam
