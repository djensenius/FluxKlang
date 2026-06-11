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
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(appModel)
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            FluxKlangCommands(appModel: appModel)
        }

        Settings {
            SettingsContentView()
                .environment(appModel)
        }

        MenuBarExtra("FluxKlang", systemImage: "slider.vertical.3") {
            MenuBarMixer()
                .environment(appModel)
        }
        .menuBarExtraStyle(.window)
    }
}
