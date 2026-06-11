//
//  InspectorView.swift
//  FluxKlang
//
//  The Mac detail inspector (⌥⌘I). Shows the live connection state and, when a
//  fader strip is selected, its details with native editable controls.
//

import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var appModel
    @State private var draftLabel = ""

    private var controller: WingController { appModel.wing }

    var body: some View {
        Form {
            connectionSection
            if let strip = appModel.selectedStrip {
                stripSection(strip)
            } else {
                Section {
                    ContentUnavailableView(
                        "No Selection",
                        systemImage: "sidebar.right",
                        description: Text("Select a fader strip to inspect and edit it here.")
                    )
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Inspector")
        .onChange(of: appModel.selectedFaderID) { _, _ in syncDraft() }
        .onAppear { syncDraft() }
    }

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("Mode", value: appModel.isDemo ? "Demo" : "Live")
            LabeledContent("Status", value: controller.connection.statusLabel)
            if let host = controller.host {
                LabeledContent("Host", value: host)
            }
            LabeledContent("OSC port", value: String(controller.port))
        }
    }

    private func stripSection(_ strip: FaderStrip) -> some View {
        let kind = strip.node.kind
        let index = strip.node.index
        return Section("Strip") {
            TextField("Label", text: $draftLabel)
                .onSubmit { appModel.faderLayout.setLabel(draftLabel, for: strip.id) }
            LabeledContent("Node", value: "\(kind.label) \(index)")
            LabeledContent("Level", value: FaderMath.label(forPosition: livePosition(kind, index)))
            Toggle("Mute", isOn: muteBinding(kind, index))

            Button(role: .destructive) {
                appModel.faderLayout.remove(strip)
                appModel.selectedFaderID = nil
            } label: {
                Label("Remove Strip", systemImage: "trash")
            }
        }
    }

    private func livePosition(_ kind: WingNodeKind, _ index: Int) -> Float {
        controller.faderPosition(kind, index) ?? FaderMath.unityPosition
    }

    private func muteBinding(_ kind: WingNodeKind, _ index: Int) -> Binding<Bool> {
        Binding(
            get: { controller.isMuted(kind, index) ?? false },
            set: { newValue in Task { await controller.setMute(kind, index, muted: newValue) } }
        )
    }

    private func syncDraft() {
        draftLabel = appModel.selectedStrip?.customLabel ?? ""
    }
}

#Preview {
    InspectorView()
        .environment(AppModel.preview())
        .frame(width: 300, height: 500)
}
