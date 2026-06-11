//
//  PresetsView.swift
//  FluxKlang
//
//  Save and recall named snapshots of the mixer + routing. Scene buttons give
//  one-tap recall; the list below manages (recalls / deletes) saved presets.
//

import SwiftUI

struct PresetsView: View {
    @Environment(AppModel.self) private var appModel

    @State private var isNaming = false
    @State private var draftName = ""

    private var presets: [Preset] { appModel.presets.presets }

    var body: some View {
        Group {
            if presets.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Presets")
        .toolbar { toolbar }
        .alert("Save Preset", isPresented: $isNaming) {
            TextField("Name", text: $draftName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Captures the current fader levels, mutes and routing.")
        }
    }

    private var list: some View {
        List {
            Section("Scenes") {
                SceneButtonsView(presets: presets, onRecall: recall, isEnabled: appModel.isConnected)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            Section("All Presets") {
                ForEach(presets) { preset in
                    Button { recall(preset) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(preset.name)
                                Text("\(preset.settings.count) settings")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.left.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!appModel.isConnected)
                }
                .onDelete { appModel.presets.remove(at: $0) }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                draftName = defaultName()
                isNaming = true
            } label: {
                Label("Save Preset", systemImage: "plus")
            }
            .disabled(!appModel.isConnected)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Presets", systemImage: "square.grid.2x2")
        } description: {
            Text("Save the current fader levels, mutes and routing as a preset, then recall it with one tap.")
        } actions: {
            Button {
                draftName = defaultName()
                isNaming = true
            } label: {
                Label("Save Current State", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!appModel.isConnected)
        }
    }

    private func save() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        appModel.savePreset(named: name)
    }

    private func recall(_ preset: Preset) {
        Task { await appModel.recall(preset) }
    }

    private func defaultName() -> String {
        "Preset \(presets.count + 1)"
    }
}

#Preview {
    NavigationStack { PresetsView() }
        .environment(AppModel.preview())
}
