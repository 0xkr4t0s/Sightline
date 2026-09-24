// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary
// Phase 4: Live Link PacketVersion 6 parser (stub)

#pragma once

#include "IProtocolParser.h"

namespace vcam {

/// Stub for Unreal Engine Live Link protocol parser (Phase 4).
class LiveLinkParser : public IProtocolParser {
public:
    const char* protocolName() const override { return "Live Link v6"; }
    size_t expectedSize() const override { return 0; } // Variable length
};

} // namespace vcam
