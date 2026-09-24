//
//  ContentView.swift
//  VCamIOS
//
//  Created by 0xKr4t0s on 7/4/2026.
//

import SwiftUI

struct ContentView: View {
    @Bindable var controller: TrackingSessionController
    @State private var browser = HostBrowser()

    var body: some View {
        NavigationStack {
            Form {
                Section("Blender on this network") {
                    ForEach(browser.hosts) { host in
                        VStack(alignment: .leading) {
                            Text(host.machine)
                            Text(host.isCompatible ? host.fileLabel : "\(host.fileLabel) · unsupported VCP version")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if browser.hosts.isEmpty {
                        Text("Searching… Start a VCam session in Blender's sidebar.")
                            .foregroundStyle(.secondary)
                    }
                    if let problem = browser.problem {
                        Text(problem)
                            .foregroundStyle(.red)
                    }
                }

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
                    if controller.sessionEndpoint == nil {
                        Text("Not paired with Blender: poses are shown here but not sent.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Pose (Blender axes)") {
                    let pose = controller.latestPose
                    LabeledContent("Seq", value: pose.map { "\($0.seq)" } ?? "–")
                    LabeledContent("Position (m)", value: pose.map { formatted($0.position) } ?? "–")
                    LabeledContent("Orientation (x y z w)", value: pose.map { formatted($0.orientation) } ?? "–")
                }

                Section("Status") {
                    Text(controller.lastError ?? "No errors")
                        .foregroundStyle(controller.lastError == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("VCamIOS")
            .task { await browser.run() }
        }
    }

    private func formatted<V: SIMD>(_ v: V) -> String where V.Scalar == Float {
        v.indices.map { String(format: "%.3f", v[$0]) }.joined(separator: " ")
    }
}

#Preview {
    ContentView(controller: TrackingSessionController())
}
