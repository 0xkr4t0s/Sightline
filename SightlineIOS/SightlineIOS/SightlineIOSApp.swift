//
//  SightlineIOSApp.swift
//  SightlineIOS
//

import SwiftUI

@main
struct SightlineIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = TrackingSessionController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
        .onChange(of: scenePhase) { _, newPhase in
            controller.handleScenePhase(newPhase)
        }
    }
}
