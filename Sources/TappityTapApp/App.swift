import SwiftUI
import AppKit

@main
struct TappityTapApp: App {
    @StateObject private var coordinator = Coordinator()

    init() {
        // Background app — no Dock icon, just the menu-bar item.
        NSApp.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(coordinator)
        } label: {
            // Drum icon — shows in the menu bar.
            Image(systemName: coordinator.enabled ? "drum.fill" : "drum")
        }
        .menuBarExtraStyle(.window)
    }
}
