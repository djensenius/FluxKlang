//
//  MacCommands.swift
//  FluxKlang
//
//  Menu-bar commands and keyboard shortcuts for the native Mac app. The menu
//  structure and shortcuts are established now; the actions are wired to the
//  WingController and stores in later phases.
//

#if os(macOS)
import SwiftUI

struct FluxKlangCommands: Commands {
    let appModel: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Preset") {}
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("WING") {
            Button("Enter Demo Mode") {
                Task { await appModel.enterDemoMode() }
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("Disconnect") {
                Task { await appModel.disconnect() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!appModel.isConnected)

            Divider()
            Button("Toggle Inspector") {}
                .keyboardShortcut("i", modifiers: [.option, .command])
        }
    }
}
#endif
