// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#include "TrackingRelay.h"

#include <cstdio>
#include <cstring>
#include <iostream>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace vcam {

TrackingRelay::TrackingRelay(const std::string& dest_host, uint16_t dest_port)
    : dest_host_(dest_host)
    , dest_port_(dest_port)
{}

TrackingRelay::~TrackingRelay() {
    stop();
}

bool TrackingRelay::start() {
    sock_fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (sock_fd_ < 0) {
        std::cerr << "[TrackingRelay] Failed to create socket\n";
        return false;
    }
    std::cerr << "[TrackingRelay] Relaying to " << dest_host_ << ":" << dest_port_ << "\n";
    return true;
}

void TrackingRelay::stop() {
    if (sock_fd_ >= 0) {
#ifdef _WIN32
        ::closesocket(sock_fd_);
#else
        ::close(sock_fd_);
#endif
        sock_fd_ = -1;
    }
}

bool TrackingRelay::send(const FreeDFrame& frame) {
    if (sock_fd_ < 0) return false;

    // JSON relay format — human-readable for Wireshark debugging.
    // ~200 bytes per packet, 12KB/s at 60Hz — negligible overhead.
    char buf[512];
    int len = std::snprintf(buf, sizeof(buf),
        R"({"type":"freed","cam":%d,"px":%.6f,"py":%.6f,"pz":%.6f,)"
        R"("pitch":%.4f,"yaw":%.4f,"roll":%.4f,)"
        R"("zoom":%d,"focus":%d,"t":%llu})",
        frame.camera_id,
        frame.pos_x, frame.pos_y, frame.pos_z,
        frame.pitch, frame.yaw, frame.roll,
        static_cast<int>(frame.zoom), static_cast<int>(frame.focus),
        static_cast<unsigned long long>(frame.timestamp_ns)
    );

    if (len <= 0 || len >= static_cast<int>(sizeof(buf))) return false;

    sockaddr_in dest{};
    dest.sin_family = AF_INET;
    dest.sin_port = htons(dest_port_);
    ::inet_pton(AF_INET, dest_host_.c_str(), &dest.sin_addr);

    ssize_t sent = ::sendto(sock_fd_, buf, static_cast<size_t>(len), 0,
                            reinterpret_cast<sockaddr*>(&dest), sizeof(dest));

    if (sent > 0) {
        frames_sent_.fetch_add(1, std::memory_order_relaxed);
        return true;
    }
    return false;
}

} // namespace vcam
