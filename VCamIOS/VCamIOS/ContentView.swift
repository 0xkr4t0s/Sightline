//
//  ContentView.swift
//  VCamIOS
//
//  Created by 0xKr4t0s on 7/4/2026.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: TrackingSessionController

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    TextField("Desktop receiver host", text: $controller.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("7000", text: $controller.portText)
                        .keyboardType(.numberPad)
                }

                Section("Tracking") {
                    Button(controller.isTracking ? "Stop Tracking" : "Start Tracking") {
                        if controller.isTracking {
                            controller.stopTracking()
                        } else {
                            Task {
                                await controller.startTracking()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    LabeledContent("Packets Sent", value: "\(controller.packetsSent)")
                    LabeledContent("Session", value: controller.sessionStatus)
                }

                Section("Pose") {
                    LabeledContent("X", value: formatted(controller.latestPose.x))
                    LabeledContent("Y", value: formatted(controller.latestPose.y))
                    LabeledContent("Z", value: formatted(controller.latestPose.z))
                    LabeledContent("Pitch", value: formatted(controller.latestPose.pitch))
                    LabeledContent("Yaw", value: formatted(controller.latestPose.yaw))
                    LabeledContent("Roll", value: formatted(controller.latestPose.roll))
                }

                Section("Status") {
                    Text(controller.lastError ?? "No errors")
                        .foregroundStyle(controller.lastError == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("VCamIOS")
        }
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

#Preview {
    ContentView(controller: TrackingSessionController())
}
