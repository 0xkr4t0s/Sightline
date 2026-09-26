//
//  ContentView.swift
//  SightlineIOS
//

import SwiftUI

/// The landscape status screen (task 1.4.5; FR-UX-003/004) over the viewfinder, which shows the
/// newest frame Blender streams, letterboxed (FR-VF-001/002). Status runs along the top edge, the
/// controls sit in a rail under the right thumb and hide after a few seconds while tracking;
/// `HUDLayout` keeps both out of the centre of the frame.
struct ContentView: View {
    @Bindable var controller: TrackingSessionController
    @State private var chrome = ChromeVisibility(now: .now)
    @State private var now = ContinuousClock.now
    @State private var showsSettings = false

    var body: some View {
        GeometryReader { proxy in
            let layout = HUDLayout(size: proxy.size)
            let controlsShown = chrome.isShown(at: now, tracking: controller.isTracking)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        now = .now
                        chrome.tapFrame(at: now, tracking: controller.isTracking)
                    }
                statusStrip
                    .frame(width: layout.statusStrip.width, height: layout.statusStrip.height)
                    .offset(x: layout.statusStrip.minX, y: layout.statusStrip.minY)
                if controlsShown {
                    controlRail
                        .frame(width: layout.controlRail.width, height: layout.controlRail.height)
                        .offset(x: layout.controlRail.minX, y: layout.controlRail.minY)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: controlsShown)
        }
        .background(ViewfinderView(renderer: controller.viewfinder).ignoresSafeArea())
        .preferredColorScheme(.dark)
        // Re-check visibility once the hide delay has passed since the last change.
        .task(id: chrome) {
            try? await Task.sleep(for: ChromeVisibility.hideAfter)
            now = .now
        }
        .onChange(of: controller.isTracking) {
            interact()
        }
        .sheet(isPresented: $showsSettings, onDismiss: interact) {
            SettingsView(controller: controller)
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 16) {
            Label {
                Text(controller.sessionStatus)
            } icon: {
                Circle()
                    .fill(trackingColor)
                    .frame(width: 10, height: 10)
            }
            Text(controller.poseRate.map { "\(Int($0.rounded())) Hz" } ?? "– Hz")
            Text(connection)
            Label("Thermal: \(controller.thermal.label)", systemImage: "thermometer.medium")
                .foregroundStyle(controller.thermal.isWarning ? Color.orange : Color.white)
            if let error = controller.lastError {
                Text(error)
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
    }

    private var controlRail: some View {
        VStack(spacing: 20) {
            let running = controller.isTracking || controller.isStarting
            railButton(running ? "Stop" : "Start", systemImage: running ? "stop.fill" : "play.fill") {
                if running {
                    controller.stopTracking()
                } else {
                    Task { await controller.startTracking() }
                }
            }
            railButton("Origin", systemImage: "scope") {
                controller.controls.setOrigin()
            }
            .disabled(!controller.isTracking)
            railButton("Settings", systemImage: "gearshape") {
                showsSettings = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private func railButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            interact()
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title2)
                Text(title)
                    .font(.caption)
            }
            .frame(minWidth: 64, minHeight: 56)
        }
        .tint(.white)
    }

    private func interact() {
        now = .now
        chrome.interact(at: now)
    }

    /// Green when ARKit tracks normally, yellow when limited, grey when not tracking.
    private var trackingColor: Color {
        guard controller.isTracking else {
            return .gray
        }
        return controller.latestPose?.trackingState == VCPPose.trackingNormal ? .green : .yellow
    }

    private var connection: String {
        if controller.pairing == nil {
            return "Not paired"
        }
        if controller.sessionStatus == "Send error" {
            return "Send error"
        }
        if controller.isReconnecting {
            return "Reconnecting"
        }
        return controller.sessionEndpoint != nil ? "Sending to Blender" : "Paired"
    }
}

#Preview {
    ContentView(controller: TrackingSessionController())
}
