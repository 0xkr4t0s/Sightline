// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#pragma once

#include <cstdint>
#include <span>

namespace vcam {

/// Abstract base class for network protocol parsers (FreeD, Live Link, etc.).
class IProtocolParser {
public:
    virtual ~IProtocolParser() = default;

    /// Human-readable protocol name.
    virtual const char* protocolName() const = 0;

    /// Expected packet size (0 if variable-length).
    virtual size_t expectedSize() const = 0;
};

} // namespace vcam
