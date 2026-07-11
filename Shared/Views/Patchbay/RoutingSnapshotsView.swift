//
//  RoutingSnapshotsView.swift
//  FluxKlang
//
//  Save and recall named "routing snapshots" — the Flock PATCH-style capture of
//  the whole patchbay (input + output patches). Recall re-patches everything with
//  one tap without touching fader levels, mutes or sends.
//

import SwiftUI

struct RoutingSnapshotsView: View {
    @Environment(AppModel.self) private var appModel

    @State private var isNaming = false
    @State private var draftName = ""

    private var snapshots: [Preset] { appModel.routingSnapshots.snapshots }

    var body: some View {
        Group {
            if snapshots.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .safeAreaInset(edge: .top) { toolbar }
        .alert("Save Routing Snapshot", isPresented: $isNaming) {
            TextField("Name", text: $draftName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Captures the whole patchbay — every channel input patch and output source.")
        }
    }

    private var toolbar: some View {
        HStack {
            Text("Routing Snapshots")
                .font(.headline)
            Spacer()
            Button {
                draftName = defaultName()
                isNaming = true
            } label: {
                Label("Save Snapshot", systemImage: "plus")
            }
            .disabled(!appModel.isConnected)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var list: some View {
        List {
            ForEach(snapshots) { snapshot in
                Button { recall(snapshot) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(snapshot.name)
                            Text("\(snapshot.settings.count) routing points")
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
            .onDelete { appModel.routingSnapshots.remove(at: $0) }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Snapshots", systemImage: "camera.on.rectangle")
        } description: {
            Text("Save the current input and output patch as a snapshot, then recall the whole routing with one tap.")
        } actions: {
            Button {
                draftName = defaultName()
                isNaming = true
            } label: {
                Label("Save Current Routing", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!appModel.isConnected)
        }
    }

    private func save() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        appModel.saveRoutingSnapshot(named: name)
    }

    private func recall(_ snapshot: Preset) {
        Task { await appModel.recallRoutingSnapshot(snapshot) }
    }

    private func defaultName() -> String {
        "Patch \(snapshots.count + 1)"
    }
}

#Preview {
    NavigationStack { RoutingSnapshotsView() }
        .environment(AppModel.preview())
}
