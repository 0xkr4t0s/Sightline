// VCamReceiver - Enterprise Virtual Camera Driver
// SPDX-License-Identifier: Proprietary

#include "ReceiverEngine.h"

#include "../network/UDPReceiver.h"
#include "../protocol/FreeDParser.h"
#include "../transport/TrackingRelay.h"

#include <iostream>

namespace vcam {

ReceiverEngine::ReceiverEngine(const Config& config)
    : config_(config)
{}

ReceiverEngine::~ReceiverEngine() {
    stop();
}

bool ReceiverEngine::start() {
    // Create the tracking relay (output to Blender)
    relay_ = std::make_unique<TrackingRelay>(config_.relay_host, config_.relay_port);
    if (!relay_->start()) {
        std::cerr << "[ReceiverEngine] Failed to start tracking relay\n";
        return false;
    }

    // Create the UDP receiver with FreeD parser callback
    auto on_packet = [this](std::span<const uint8_t> data) {
        auto frame = FreeDParser::parse(data);
        if (frame.has_value()) {
            relay_->send(frame.value());
        }
    };

    receiver_ = std::make_unique<UDPReceiver>(config_.freed_port, std::move(on_packet));
    if (!receiver_->start()) {
        std::cerr << "[ReceiverEngine] Failed to start UDP receiver\n";
        relay_->stop();
        return false;
    }

    std::cerr << "[ReceiverEngine] Pipeline started: FreeD:" << config_.freed_port
              << " -> Relay:" << config_.relay_host << ":" << config_.relay_port << "\n";
    return true;
}

void ReceiverEngine::stop() {
    if (receiver_) {
        receiver_->stop();
        receiver_.reset();
    }
    if (relay_) {
        relay_->stop();
        relay_.reset();
    }
    std::cerr << "[ReceiverEngine] Pipeline stopped\n";
}

bool ReceiverEngine::isRunning() const {
    return receiver_ && receiver_->isRunning();
}

} // namespace vcam
