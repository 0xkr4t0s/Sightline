// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#include "UDPReceiver.h"

#include <array>
#include <iostream>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
using ssize_t = int;
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace vcam {

UDPReceiver::UDPReceiver(uint16_t port, Callback on_data, const std::string& bind_addr)
    : port_(port)
    , bind_addr_(bind_addr)
    , on_data_(std::move(on_data))
{}

UDPReceiver::~UDPReceiver() {
    stop();
}

bool UDPReceiver::start() {
    if (running_.load()) return false;

    sock_fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (sock_fd_ < 0) {
        std::cerr << "[UDPReceiver] Failed to create socket\n";
        return false;
    }

    // Reuse address
    int opt = 1;
    ::setsockopt(sock_fd_, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&opt), sizeof(opt));

    // Non-blocking
#ifdef _WIN32
    unsigned long nonblock = 1;
    ioctlsocket(sock_fd_, FIONBIO, &nonblock);
#else
    int flags = ::fcntl(sock_fd_, F_GETFL, 0);
    ::fcntl(sock_fd_, F_SETFL, flags | O_NONBLOCK);
#endif

    // Bind
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port_);
    ::inet_pton(AF_INET, bind_addr_.c_str(), &addr.sin_addr);

    if (::bind(sock_fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        std::cerr << "[UDPReceiver] Failed to bind to " << bind_addr_ << ":" << port_ << "\n";
#ifdef _WIN32
        ::closesocket(sock_fd_);
#else
        ::close(sock_fd_);
#endif
        sock_fd_ = -1;
        return false;
    }

    running_.store(true, std::memory_order_release);
    thread_ = std::thread(&UDPReceiver::recvLoop, this);

    std::cerr << "[UDPReceiver] Listening on " << bind_addr_ << ":" << port_ << "\n";
    return true;
}

void UDPReceiver::stop() {
    running_.store(false, std::memory_order_release);

    if (sock_fd_ >= 0) {
#ifdef _WIN32
        ::closesocket(sock_fd_);
#else
        ::close(sock_fd_);
#endif
        sock_fd_ = -1;
    }

    if (thread_.joinable()) {
        thread_.join();
    }
}

void UDPReceiver::recvLoop() {
    std::array<uint8_t, 4096> buf;

    while (running_.load(std::memory_order_acquire)) {
        sockaddr_in sender{};
        socklen_t sender_len = sizeof(sender);

        ssize_t n = ::recvfrom(sock_fd_, reinterpret_cast<char*>(buf.data()), buf.size(), 0,
                               reinterpret_cast<sockaddr*>(&sender), &sender_len);

        if (n > 0) {
            on_data_(std::span<const uint8_t>(buf.data(), static_cast<size_t>(n)));
        } else {
            // EAGAIN / EWOULDBLOCK — no data, brief sleep to avoid busy-spin
            std::this_thread::sleep_for(std::chrono::microseconds(500));
        }
    }
}

} // namespace vcam
