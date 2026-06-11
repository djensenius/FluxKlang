//
//  MacCommands.swift
//  FluxKlang
//
//  Menu-bar commands and keyboard shortcuts for the native Mac app, wired to the
//  AppModel: connect / disconnect, demo mode, presets, scene recall (⌘1–9) and
//  the detail inspector.
//

#if os(macOS)
import SwiftUI

struct FluxKlangCommands: Commands {
    let appModel: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Preset") { appModel.requestNewPreset() }
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("WING") {
            Button(appModel.isConnected ? "Disconnect" : "Connect to Last WING") {
                Task { await appModel.toggleConnection() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!appModel.canToggleConnection)

            Button("Enter Demo Mode") {
                Task { await appModel.enterDemoMode() }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(appModel.isDemo)

            Divider()

            sceneRecallMenu

            Divider()

            Button("Toggle Inspector") { appModel.isInspectorPresented.toggle() }
                .keyboardShortcut("i", modifiers: [.option, .command])
        }
    }

    @ViewBuilder
    private var sceneRecallMenu: some View {
        let presets = appModel.presets.presets
        Menu("Recall Scene") {
            if presets.isEmpty {
                Text("No Presets")
            } else {
                ForEach(Array(presets.prefix(9).enumerated()), id: \.element.id) { offset, preset in
                    Button(preset.name) {
                        Task { await appModel.recall(preset) }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(offset + 1)")), modifiers: .command)
                    .disabled(!appModel.isConnected)
                }
            }
        }
    }
}
#endif
