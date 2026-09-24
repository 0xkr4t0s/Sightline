// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#pragma once

#include <cstdint>
#include <memory>
#include <string>

namespace vcam {

class UDPReceiver;
class FreeDParser;
class TrackingRelay;

/// Top-level orchestrator for the VCam receiver pipeline.
///
/// Wires together: UDPReceiver → FreeDParser → TrackingRelay → Blender.
/// Manages lifecycle, configuration, and graceful shutdown.
class ReceiverEngine {
public:
    struct Config {
        uint16_t freed_port = 7000;       // Incoming FreeD UDP port
        std::string relay_host = "127.0.0.1";
        uint16_t relay_port = 6000;       // Outgoing relay to Blender
    };

    explicit ReceiverEngine(const Config& config);
    ~ReceiverEngine();

    // Non-copyable
    ReceiverEngine(const ReceiverEngine&) = delete;
    ReceiverEngine& operator=(const ReceiverEngine&) = delete;

    /// Start the receiver pipeline.
    bool start();

    /// Stop all threads and release resources.
    void stop();

    bool isRunning() const;

private:
    Config config_;
    std::unique_ptr<UDPReceiver> receiver_;
    std::unique_ptr<TrackingRelay> relay_;
};

} // namespace vcam
