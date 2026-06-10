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
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Preset") {}
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("WING") {
            Button("Connect / Disconnect") {}
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Toggle Inspector") {}
                .keyboardShortcut("i", modifiers: [.option, .command])
        }
    }
}
#endif
