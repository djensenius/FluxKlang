//
//  FluxKlangMacApp.swift
//  FluxKlangMac
//
//  Native macOS entry point. Composed as a real Mac app: a main WindowGroup,
//  a Settings scene (⌘,), menu-bar Commands with keyboard shortcuts, and a
//  MenuBarExtra quick-mixer — not a ported iOS scene.
//

import SwiftUI

@main
struct FluxKlangMacApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            FluxKlangCommands()
        }

        Settings {
            SettingsContentView()
        }

        MenuBarExtra("FluxKlang", systemImage: "slider.vertical.3") {
            MenuBarMixer()
        }
        .menuBarExtraStyle(.window)
    }
}
