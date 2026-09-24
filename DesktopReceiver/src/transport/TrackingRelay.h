// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#pragma once

#include <atomic>
#include <cstdint>
#include <string>

#include "../protocol/FreeDTypes.h"

namespace vcam {

/// Relays decoded tracking data to the Blender add-on via localhost UDP.
///
/// This is the GPL compliance firewall: the proprietary C++ receiver and
/// the GPL Blender add-on communicate only via this IPC channel (UDP socket).
/// No linking occurs between the two codebases.
///
/// Phase 2: JSON-over-UDP format for debuggability.
class TrackingRelay {
public:
    /// @param dest_host Destination host (default 127.0.0.1).
    /// @param dest_port Destination UDP port (default 6000 — Blender add-on).
    TrackingRelay(const std::string& dest_host = "127.0.0.1", uint16_t dest_port = 6000);
    ~TrackingRelay();

    // Non-copyable
    TrackingRelay(const TrackingRelay&) = delete;
    TrackingRelay& operator=(const TrackingRelay&) = delete;

    /// Open the UDP socket for sending.
    bool start();

    /// Close the socket.
    void stop();

    /// Send a decoded tracking frame to the Blender add-on.
    /// Thread-safe — can be called from the network thread.
    bool send(const FreeDFrame& frame);

    uint64_t framesSent() const { return frames_sent_.load(std::memory_order_relaxed); }

private:
    std::string dest_host_;
    uint16_t dest_port_;
    int sock_fd_ = -1;
    std::atomic<uint64_t> frames_sent_{0};
};

} // namespace vcam
