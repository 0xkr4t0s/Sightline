// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#include <gtest/gtest.h>

#include "UDPReceiver.h"

#include <atomic>
#include <chrono>
#include <cstring>
#include <thread>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

using namespace vcam;

TEST(UDPReceiver, StartsAndStops) {
    std::atomic<int> count{0};
    UDPReceiver receiver(19000, [&](std::span<const uint8_t>) {
        count.fetch_add(1);
    });

    ASSERT_TRUE(receiver.start());
    EXPECT_TRUE(receiver.isRunning());

    receiver.stop();
    EXPECT_FALSE(receiver.isRunning());
}

TEST(UDPReceiver, ReceivesPacket) {
    std::atomic<int> count{0};
    std::vector<uint8_t> received_data;
    std::mutex mtx;

    UDPReceiver receiver(19001, [&](std::span<const uint8_t> data) {
        std::lock_guard lock(mtx);
        received_data.assign(data.begin(), data.end());
        count.fetch_add(1);
    });

    ASSERT_TRUE(receiver.start());

    // Send a test packet from another socket
    int send_sock = ::socket(AF_INET, SOCK_DGRAM, 0);
    ASSERT_GE(send_sock, 0);

    sockaddr_in dest{};
    dest.sin_family = AF_INET;
    dest.sin_port = htons(19001);
    ::inet_pton(AF_INET, "127.0.0.1", &dest.sin_addr);

    const char* msg = "hello";
    ::sendto(send_sock, msg, 5, 0, reinterpret_cast<sockaddr*>(&dest), sizeof(dest));

    // Wait briefly for reception
    std::this_thread::sleep_for(std::chrono::milliseconds(50));

    EXPECT_GE(count.load(), 1);

    {
        std::lock_guard lock(mtx);
        ASSERT_EQ(received_data.size(), 5u);
        EXPECT_EQ(std::memcmp(received_data.data(), "hello", 5), 0);
    }

#ifdef _WIN32
    ::closesocket(send_sock);
#else
    ::close(send_sock);
#endif

    receiver.stop();
}
