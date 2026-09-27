//
//  ContentView.swift
//  SightlineIOS
//

import SwiftUI

/// The landscape status screen (task 1.4.5; FR-UX-003/004) over the viewfinder, which shows the
/// newest frame Blender streams, letterboxed (FR-VF-001/002), with the chosen framing guides on top
/// (FR-VF-003), and says when that frame goes stale (FR-VF-005). Status runs along the top edge, the
/// controls sit in a rail under the right thumb and hide after a few seconds while tracking;
/// `HUDLayout` keeps both out of the centre of the frame. The rail's Lens button swaps it for the
/// lens panel (FR-CTL-001..003), which hides and comes back in the rail's place until it's closed.
///
/// Gestures on the viewfinder, while Blender streams to a live session: a tap on the picture
/// focuses there (FR-CTL-002) and shows the controls; a tap in the letterbox or pillar bars
/// around the picture shows or hides them; a pinch anywhere changes the focal length
/// (FR-CTL-001). Without a streamed frame every tap shows or hides the controls.
struct ContentView: View {
    @Bindable var controller: TrackingSessionController
    @State private var chrome = ChromeVisibility(now: .now)
    @State private var now = ContinuousClock.now
    @State private var showsSettings = false
    @State private var showsLens = false
    @State private var pinchStartMM: Float?
    @State private var focusMark: FocusMark?

    var body: some View {
        // The full-screen viewfinder is the root, so taps in the bars beside the picture reach it
        // even inside the safe-area insets; the status, HUD and controls lie over it.
        viewfinder
            .overlay {
                GeometryReader { proxy in
                    let fullSize = CGSize(
                        width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                        height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
                    let picture =
                        controller.videoFrameSize.flatMap {
                            FramingGeometry(frame: $0, view: fullSize, maskAspect: controller.framing.maskAspect)?
                                .picture
                        } ?? CGRect(origin: .zero, size: fullSize)
                    let layout = HUDLayout(
                        size: proxy.size,
                        picture: picture.offsetBy(dx: -proxy.safeAreaInsets.leading, dy: -proxy.safeAreaInsets.top),
                        viewfinder: CGRect(
                            x: -proxy.safeAreaInsets.leading, y: -proxy.safeAreaInsets.top,
                            width: fullSize.width, height: fullSize.height))
                    let controlsShown = chrome.isShown(at: now, tracking: controller.isTracking)
                    ZStack(alignment: .topLeading) {
                        // Taps and pinches go through to the viewfinder's gesture layer.
                        Color.clear
                            .allowsHitTesting(false)
                        if controller.videoStalled {
                            stalledOverlay
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .allowsHitTesting(false)
                        }
                        // The status and HUD are read-only: taps and pinches on them reach the viewfinder.
                        statusStrip
                            .frame(width: layout.statusStrip.width, height: layout.statusStrip.height)
                            .offset(x: layout.statusStrip.minX, y: layout.statusStrip.minY)
                            .allowsHitTesting(false)
                        dataPanel
                            .frame(width: layout.dataPanel.width, height: layout.dataPanel.height)
                            .clipped()
                            .background {
                                Color.black.opacity(0.7)
                                    .accessibilityLabel("HUD panel")
                                    .accessibilityIdentifier("hud.panel")
                            }
                            .offset(x: layout.dataPanel.minX, y: layout.dataPanel.minY)
                            .allowsHitTesting(false)
                        if showsLens && controlsShown {
                            LensPanel(
                                shown: controller.shownLens, lens: controller.controls.lens,
                                rackDurationMS: controller.lensPanel.rackDurationMS,
                                perform: { action in
                                    interact()
                                    controller.performLens(action)
                                },
                                close: {
                                    showsLens = false
                                    interact()
                                }
                            )
                            .frame(width: layout.lensPanel.width, height: layout.lensPanel.height)
                            .offset(x: layout.lensPanel.minX, y: layout.lensPanel.minY)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        } else if controlsShown {
                            controlRail
                                .frame(width: layout.controlRail.width, height: layout.controlRail.height)
                                .offset(x: layout.controlRail.minX, y: layout.controlRail.minY)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: controlsShown)
                    .animation(.easeInOut(duration: 0.25), value: showsLens)
                }
            }
            .preferredColorScheme(.dark)
            // Re-check visibility once the hide delay has passed since the last change.
            .task(id: chrome) {
                try? await Task.sleep(for: ChromeVisibility.hideAfter)
                now = .now
            }
            .task(id: focusMark) {
                guard focusMark != nil else { return }
                try? await Task.sleep(for: .seconds(1))
                focusMark = nil
            }
            .onChange(of: controller.isTracking) {
                interact()
            }
            .sheet(isPresented: $showsSettings, onDismiss: interact) {
                SettingsView(controller: controller)
            }
    }

    /// Same full-screen space as the Metal view, so the guides and taps line up with the frame.
    private var viewfinder: some View {
        ZStack {
            ViewfinderView(renderer: controller.viewfinder)
            FramingOverlayView(
                settings: controller.framing, frameSize: controller.videoFrameSize,
                horizonAngle: controller.horizonAngle)
            GeometryReader { screen in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        viewfinderTapped(at: location, screen: screen.size)
                    }
                    .simultaneousGesture(pinch)
                    .overlay(alignment: .topLeading) {
                        if let focusMark {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.yellow, lineWidth: 1.5)
                                .frame(width: 56, height: 56)
                                .position(focusMark.point)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Viewfinder")
        .accessibilityValue(viewfinderDescription)
        .accessibilityIdentifier("viewfinder")
    }

    private var statusStrip: some View {
        HStack(spacing: 16) {
            Label {
                Text(controller.sessionStatus)
                    .accessibilityIdentifier("status.session")
            } icon: {
                Circle()
                    .fill(trackingColor)
                    .frame(width: 10, height: 10)
            }
            Text(HUDFields.tracking(running: controller.isTracking, state: controller.latestPose?.trackingState))
                .accessibilityValue(
                    HUDFields.tracking(running: controller.isTracking, state: controller.latestPose?.trackingState)
                )
                .accessibilityIdentifier("hud.tracking")
            Text(controller.poseRate.map { "\(Int($0.rounded())) Hz" } ?? "– Hz")
                .accessibilityIdentifier("status.rate")
            Text(connection)
                .accessibilityIdentifier("status.connection")
            Label("Thermal: \(controller.thermal.label)", systemImage: "thermometer.medium")
                .foregroundStyle(controller.thermal.isWarning ? Color.orange : Color.white)
                .accessibilityIdentifier("status.thermal")
            if let error = controller.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("status.error")
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
    }

    /// Persistent measurements and placeholders sit along the bottom-left edge, independently of
    /// the right-hand rail's four-second auto-hide. This leaves the picture's middle half clear.
    private var dataPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(connection)
                    .accessibilityValue(connection)
                    .accessibilityIdentifier("hud.connection")
                if let stream = controller.stream {
                    Text(stream.label)
                        .accessibilityValue(stream.label)
                        .accessibilityIdentifier("hud.stream")
                    Text(stream.quality.label)
                        .foregroundStyle(qualityColor(stream.quality))
                        .accessibilityValue(stream.quality.label)
                        .accessibilityIdentifier("hud.quality")
                } else if controller.isReconnecting {
                    Text(ConnectionQuality.poor.label)
                        .foregroundStyle(qualityColor(.poor))
                        .accessibilityValue(ConnectionQuality.poor.label)
                        .accessibilityIdentifier("hud.quality")
                }
            }
            HStack(spacing: 12) {
                Text(controller.videoLevel ?? "q— · —")
                    .accessibilityValue(controller.videoLevel ?? "—")
                    .accessibilityIdentifier("hud.level")
                Text("M2P \(HUDFields.m2p)")
                    .accessibilityValue(HUDFields.m2p)
                    .accessibilityIdentifier("hud.m2p")
            }
            Text(HUDFields.lens(controller.appliedLens))
                .minimumScaleFactor(0.8)
                .accessibilityValue(HUDFields.lens(controller.appliedLens))
                .accessibilityIdentifier("hud.lens")
            HStack(spacing: 10) {
                Text("REC n/a")
                    .accessibilityLabel(HUDFields.recording)
                    .accessibilityValue(HUDFields.recording)
                    .accessibilityIdentifier("hud.recording")
                Text(HUDFields.thermal(controller.thermal))
                    .foregroundStyle(controller.thermal.isWarning ? Color.orange : Color.white)
                    .accessibilityValue(HUDFields.thermal(controller.thermal))
                    .accessibilityIdentifier("hud.thermal")
            }
        }
        .lineLimit(1)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// Centred over the stale frame; taps go through to the viewfinder.
    private var stalledOverlay: some View {
        VStack(spacing: 4) {
            Label("Video stalled", systemImage: "video.slash.fill")
                .font(.headline)
            Text("Tracking continues")
                .font(.caption)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.75), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("video.stalled")
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
            .accessibilityIdentifier("control.startStop")
            railButton("Origin", systemImage: "scope") {
                controller.controls.setOrigin()
            }
            .disabled(!controller.isTracking)
            .accessibilityIdentifier("control.origin")
            railButton("Lens", systemImage: "camera.aperture") {
                showsLens = true
            }
            .accessibilityIdentifier("control.lens")
            railButton("Settings", systemImage: "gearshape") {
                showsSettings = true
            }
            .accessibilityIdentifier("control.settings")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    /// The viewfinder's accessibility value: the frame on screen and the guides drawn over it, so
    /// VoiceOver users and UI tests can tell what is shown ("1280x720; thirds, centre cross").
    private var viewfinderDescription: String {
        let frame = controller.videoFrameSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "No video"
        let framing = controller.framing
        var guides: [String] = []
        if let aspect = framing.maskAspect { guides.append(String(format: "mask %.2f:1", aspect)) }
        if framing.thirds { guides.append("thirds") }
        if framing.centreCross { guides.append("centre cross") }
        if framing.safeAreas { guides.append("safe areas") }
        if framing.horizon { guides.append("horizon") }
        return guides.isEmpty ? frame : "\(frame); \(guides.joined(separator: ", "))"
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

    /// `location` is in the full-screen viewfinder's points, where the frame is drawn.
    private func viewfinderTapped(at location: CGPoint, screen: CGSize) {
        if controller.lensGesturesEnabled, let frame = controller.videoFrameSize,
            let image = FramingGeometry(frame: frame, view: screen, maskAspect: nil)?.image,
            let point = LensInput.pictureTap(at: location, image: image)
        {
            controller.performLens(.tap(u: point.u, v: point.v))
            focusMark = FocusMark(point: location)
            interact()
            return
        }
        now = .now
        chrome.tapFrame(at: now, tracking: controller.isTracking)
    }

    /// Pinching out lengthens the lens from where it was when the pinch began.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard controller.lensGesturesEnabled else { return }
                let start = pinchStartMM ?? controller.shownLens.lensMM ?? 50
                pinchStartMM = start
                controller.performLens(.lens(LensInput.pinch(from: start, magnification: value.magnification)))
            }
            .onEnded { _ in
                pinchStartMM = nil
            }
    }

    /// Green when ARKit tracks normally, yellow when limited, grey when not tracking.
    private var trackingColor: Color {
        guard controller.isTracking else {
            return .gray
        }
        return controller.latestPose?.trackingState == VCPPose.trackingNormal ? .green : .yellow
    }

    private func qualityColor(_ quality: ConnectionQuality) -> Color {
        switch quality {
        case .good: .green
        case .fair: .yellow
        case .poor: .red
        }
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

/// Where the last tap-to-focus landed; shown for a moment.
private struct FocusMark: Equatable {
    let point: CGPoint
    let id = UUID()
}

#Preview {
    ContentView(controller: TrackingSessionController())
}
