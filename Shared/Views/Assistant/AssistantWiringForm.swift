import SwiftUI

struct AssistantWiringForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel
    @State private var sourceIDs: Set<Equipment.ID> = []
    @State private var effectIDs: Set<Effect.ID> = []
    @State private var destination = StudioEndpointDestination.finalMix

    var body: some View {
        NavigationStack {
            Form {
                Section("Sources") {
                    ForEach(appModel.equipment.items) { equipment in
                        toggle(equipment.name, id: equipment.id, selection: $sourceIDs)
                    }
                }
                Section("Effects") {
                    ForEach(appModel.environments.activeEffects) { effect in
                        toggle(effect.name, id: effect.id, selection: $effectIDs)
                    }
                }
                Section("Destination") {
                    Picker("Destination", selection: $destination) {
                        Text("Final Mix").tag(StudioEndpointDestination.finalMix)
                        Text("Space").tag(StudioEndpointDestination.space)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Safety") {
                    Text("This creates a pending draft only. Review is required and no WING settings are written.")
                }
            }
            .navigationTitle("Wiring Draft")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Draft") {
                        appModel.assistantChat.createWiringDraft(
                            sourceIDs: appModel.equipment.items
                                .filter { sourceIDs.contains($0.id) }
                                .map(\.id),
                            effectIDs: appModel.environments.activeEffects
                                .filter { effectIDs.contains($0.id) }
                                .map(\.id),
                            destination: destination,
                            context: appModel.assistantToolContext()
                        )
                        dismiss()
                    }
                    .disabled(sourceIDs.isEmpty)
                }
            }
        }
    }

    private func toggle<ID: Hashable>(
        _ title: String,
        id: ID,
        selection: Binding<Set<ID>>
    ) -> some View {
        Button {
            if selection.wrappedValue.contains(id) {
                selection.wrappedValue.remove(id)
            } else {
                selection.wrappedValue.insert(id)
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                if selection.wrappedValue.contains(id) {
                    Image(systemName: "checkmark")
                }
            }
        }
        .buttonStyle(.plain)
    }
}
