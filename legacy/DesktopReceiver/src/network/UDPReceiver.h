// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <span>
#include <string>
#include <thread>

namespace vcam {

/// Non-blocking UDP socket receiver with dedicated thread.
///
/// Calls a user callback on each received datagram from a background thread.
/// Designed for low-latency protocol reception (FreeD, Live Link, etc.).
class UDPReceiver {
public:
    using Callback = std::function<void(std::span<const uint8_t>)>;

    /// @param port UDP port to bind on.
    /// @param on_data Callback invoked for each received packet (from network thread).
    /// @param bind_addr Address to bind (default 0.0.0.0).
    UDPReceiver(uint16_t port, Callback on_data, const std::string& bind_addr = "0.0.0.0");
    ~UDPReceiver();

    // Non-copyable
    UDPReceiver(const UDPReceiver&) = delete;
    UDPReceiver& operator=(const UDPReceiver&) = delete;

    /// Bind socket and start the receiver thread.
    /// @return true on success.
    bool start();

    /// Stop the receiver thread and close the socket.
    void stop();

    bool isRunning() const { return running_.load(std::memory_order_relaxed); }
    uint16_t port() const { return port_; }

private:
    void recvLoop();

    uint16_t port_;
    std::string bind_addr_;
    Callback on_data_;
    int sock_fd_ = -1;
    std::atomic<bool> running_{false};
    std::thread thread_;
};

} // namespace vcam
