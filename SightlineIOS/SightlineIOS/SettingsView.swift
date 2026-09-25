//
//  SettingsView.swift
//  SightlineIOS
//
//  Created by 0xKr4t0s on 7/4/2026.
//

import SwiftUI

/// Everything that isn't shot-time status: discovery, destination, rig and pose details. The
/// status screen opens it as a sheet (task 1.4.5); discovery browses while it is open.
struct SettingsView: View {
    @Bindable var controller: TrackingSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var browser = HostBrowser()
    @State private var customScale = ""
    @State private var pairingCode = ""

    /// FR-CTL-004's examples: 1:1, 1:2, 1:10, plus 1:5; anything else via Custom.
    private static let scalePresets: [Float] = [1, 2, 5, 10]

    var body: some View {
        NavigationStack {
            Form {
                Section("Blender on this network") {
                    ForEach(browser.hosts) { host in
                        Button {
                            controller.select(host)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(host.machine)
                                    Text(host.isCompatible ? host.fileLabel : "\(host.fileLabel) · unsupported VCP version")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if controller.selectedServiceName == host.id {
                                    Image(systemName: "checkmark").accessibilityLabel("Selected")
                                }
                            }
                        }
                        .disabled(!host.isCompatible || controller.isTracking || controller.isPairing)
                    }
                    if browser.hosts.isEmpty {
                        Text("Searching… Start a Sightline session in Blender's sidebar.")
                            .foregroundStyle(.secondary)
                    }
                    if let problem = browser.problem {
                        Text(problem)
                            .foregroundStyle(.red)
                    }
                }

                Section("Blender") {
                    Button("Use manual address") { controller.selectManual() }
                        .disabled(controller.selectedServiceName == nil || controller.isTracking || controller.isPairing)
                    TextField("Address or name of the Mac/PC running Blender", text: $controller.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(controller.selectedServiceName != nil || controller.isTracking || controller.isPairing || controller.isStarting)
                        .onChange(of: controller.host) { controller.manualAddressChanged() }

                    TextField("Control port (\(TrackingSettings.defaultPort))", text: $controller.portText)
                        .keyboardType(.numberPad)
                        .onChange(of: controller.portText) { controller.manualAddressChanged() }
                        .disabled(controller.selectedServiceName != nil || controller.isTracking || controller.isPairing || controller.isStarting)
                    if let selected = controller.selectedServiceName {
                        Text("Selected network host: \(browser.hosts.first { $0.id == selected }?.machine ?? selected)")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Pair with Blender") {
                    Text("In Blender, enable pairing in the Sightline sidebar and enter its six-digit code. Keep both devices on the same network. Allow Local Network access for Sightline on iOS and Blender on macOS; on Windows, allow Blender through the firewall prompt.")
                        .font(.footnote)
                    TextField("Six-digit code", text: $pairingCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    Button(controller.isPairing ? "Pairing…" : "Pair") {
                        Task {
                            await controller.pair(code: pairingCode)
                            if controller.pairing != nil { pairingCode = "" }
                        }
                    }
                    .disabled(controller.isPairing || controller.isTracking)
                    Text(controller.pairing == nil ? "Not paired" : "Paired with selected Blender host")
                        .foregroundStyle(.secondary)
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
                    if let leg = controller.sendLeg {
                        LabeledContent("Send leg p95", value: Self.sendLegText(leg))
                            .foregroundStyle(leg.meetsTarget ? Color.primary : Color.orange)
                    }
                    LabeledContent("Session", value: controller.sessionStatus)
                    if let seconds = controller.lastReconnectSeconds {
                        LabeledContent("Last reconnect", value: String(format: "%.2f s", seconds))
                    }
                    if let understanding = controller.sceneUnderstanding {
                        LabeledContent("Scene understanding", value: understanding.summary)
                    }
                    if controller.pairing == nil {
                        Text("Not paired with Blender: poses are shown here but not sent.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Rig") {
                    Button("Set Origin") {
                        controller.controls.setOrigin()
                    }
                    .disabled(!controller.isTracking)

                    Picker("Motion scale", selection: $controller.controls.motionScale) {
                        ForEach(Self.scalePresets, id: \.self) { scale in
                            Text("1:\(Self.format(scale))").tag(scale)
                        }
                        if !Self.scalePresets.contains(controller.controls.motionScale) {
                            Text("1:\(Self.format(controller.controls.motionScale))")
                                .tag(controller.controls.motionScale)
                        }
                    }
                    HStack {
                        Text("Custom 1:")
                        TextField("25", text: $customScale)
                            .keyboardType(.decimalPad)
                        Button("Apply") {
                            if let scale = DeviceControls.parseScale(customScale) {
                                controller.controls.motionScale = scale
                            }
                        }
                        .disabled(DeviceControls.parseScale(customScale) == nil)
                    }

                    Toggle("Lock height", isOn: lock(DeviceControls.lockHeight))
                    Toggle("Lock roll", isOn: lock(DeviceControls.lockRoll))
                    Toggle("Pan only (lock position)", isOn: lock(DeviceControls.panOnly))
                    LabeledContent("Blender", value: controlStatus)
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
            .navigationTitle("Sightline")
            .toolbar {
                Button("Done") { dismiss() }
            }
            .task { await browser.run() }
            .disabled(controller.isStarting)
        }
    }

    private func formatted<V: SIMD>(_ v: V) -> String where V.Scalar == Float {
        v.indices.map { String(format: "%.3f", v[$0]) }.joined(separator: " ")
    }

    private static func format(_ scale: Float) -> String {
        String(format: "%g", scale)
    }

    /// NFR-LAT-002: "0.04 ms (p99 0.06, max 0.31, 1234 poses)".
    private static func sendLegText(_ leg: SendLegSummary) -> String {
        func ms(_ ns: UInt64) -> String { String(format: "%.2f", Double(ns) / 1e6) }
        return "\(ms(leg.p95)) ms (p99 \(ms(leg.p99)), max \(ms(leg.max)), \(leg.count) poses)"
    }

    private func lock(_ flag: UInt8) -> Binding<Bool> {
        Binding(get: { controller.controls.isLocked(flag) },
                set: { controller.controls.setLock(flag, $0) })
    }

    /// Whether Blender has applied the latest controls (`STATUS.control_ack`, vcp.md §6.2).
    private var controlStatus: String {
        if controller.pairing == nil {
            return "Not sent (not paired)"
        }
        if !controller.isTracking {
            return "Sent when tracking starts"
        }
        if controller.controlSeq > 0, controller.controlAck >= controller.controlSeq {
            return "Applied (#\(controller.controlSeq))"
        }
        return "Waiting for Blender (#\(controller.controlSeq))"
    }
}

#Preview {
    SettingsView(controller: TrackingSessionController())
}
