import SwiftUI
import AppKit

@main
struct TappityTapApp: App {
    @StateObject private var coordinator = Coordinator()

    init() {
        // Background app — no Dock icon, just the menu-bar item.
        // Use NSApplication.shared (not NSApp); the latter is still nil at App.init time.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(coordinator)
        } label: {
            Image(systemName: coordinator.enabled ? "waveform" : "waveform.slash")
        }
        .menuBarExtraStyle(.window)
    }
}
