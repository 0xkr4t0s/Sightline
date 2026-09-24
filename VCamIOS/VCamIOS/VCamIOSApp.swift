//
//  VCamIOSApp.swift
//  VCamIOS
//
//  Created by 0xKr4t0s on 7/4/2026.
//

import SwiftUI

@main
struct VCamIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = TrackingSessionController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
        .onChange(of: scenePhase) { _, newPhase in
            controller.handleScenePhase(newPhase)
        }
    }
}
