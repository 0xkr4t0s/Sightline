// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#include "ReceiverEngine.h"
#include "TestPatternGenerator.h"

#include <atomic>
#include <csignal>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>

static std::atomic<bool> g_running{true};

static void signalHandler(int sig) {
    std::cerr << "\n[VCamReceiver] Caught signal " << sig << ", shutting down...\n";
    g_running.store(false, std::memory_order_release);
}

static void printUsage(const char* prog) {
    std::cerr << "Usage: " << prog << " [options]\n"
              << "Options:\n"
              << "  --freed-port PORT   FreeD input UDP port (default: 7000)\n"
              << "  --relay-host HOST   Relay destination host (default: 127.0.0.1)\n"
              << "  --relay-port PORT   Relay destination port (default: 6000)\n"
              << "  --test-pattern      Generate SMPTE color bars (no network input)\n"
              << "  --help              Show this help\n";
}

int main(int argc, char* argv[]) {
    vcam::ReceiverEngine::Config config;
    bool test_pattern = false;

    // Parse command-line arguments
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--freed-port") == 0 && i + 1 < argc) {
            config.freed_port = static_cast<uint16_t>(std::stoi(argv[++i]));
        } else if (std::strcmp(argv[i], "--relay-host") == 0 && i + 1 < argc) {
            config.relay_host = argv[++i];
        } else if (std::strcmp(argv[i], "--relay-port") == 0 && i + 1 < argc) {
            config.relay_port = static_cast<uint16_t>(std::stoi(argv[++i]));
        } else if (std::strcmp(argv[i], "--test-pattern") == 0) {
            test_pattern = true;
        } else if (std::strcmp(argv[i], "--help") == 0) {
            printUsage(argv[0]);
            return 0;
        } else {
            std::cerr << "Unknown option: " << argv[i] << "\n";
            printUsage(argv[0]);
            return 1;
        }
    }

    // Register signal handlers
    std::signal(SIGINT, signalHandler);
    std::signal(SIGTERM, signalHandler);

    std::cerr << "=== VCam Receiver v0.1.0 ===\n";

    if (test_pattern) {
        // Test pattern mode: generate SMPTE color bars
        // When CMIO extension is active, these frames would be pushed to it.
        // For now, just verify the frame generation pipeline works.
        uint64_t frame_count = 0;
        vcam::TestPatternGenerator generator(1920, 1080, 30.0f,
            [&frame_count](const vcam::FrameBuffer& fb) {
                frame_count++;
                if (frame_count % 30 == 0) {
                    std::cerr << "\r[TestPattern] Frames generated: " << frame_count
                              << " (" << fb.width() << "x" << fb.height() << ")"
                              << std::flush;
                }
            }
        );

        generator.start();

        while (g_running.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }

        generator.stop();
        std::cerr << "\n[TestPattern] Total frames: " << frame_count << "\n";
    } else {
        // Normal mode: receive FreeD and relay to Blender
        vcam::ReceiverEngine engine(config);
        if (!engine.start()) {
            std::cerr << "[VCamReceiver] Failed to start. Exiting.\n";
            return 1;
        }

        while (g_running.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }

        engine.stop();
    }

    std::cerr << "[VCamReceiver] Clean shutdown complete.\n";
    return 0;
}
