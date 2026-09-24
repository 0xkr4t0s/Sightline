// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#pragma once

namespace vcam {

/// Abstract base class for video transports (WebRTC, NDI, ST 2110).
/// Phase 5+.
class ITransport {
public:
    virtual ~ITransport() = default;
    virtual const char* transportName() const = 0;
};

} // namespace vcam
