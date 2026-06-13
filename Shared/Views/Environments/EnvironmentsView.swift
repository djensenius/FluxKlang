//
//  EnvironmentsView.swift
//  FluxKlang
//
//  A simple environment builder. The screen is deliberately not a patchbay:
//  create the effects in this setup, choose which instruments feed them, then
//  place the resulting voices in space and apply the whole rig.
//

import SwiftUI

struct EnvironmentsView: View {
    @Environment(AppModel.self) private var appModel

    @State private var editing: Effect?
    @State private var isApplying = false
    @State private var nameMode: NameMode?
    @State private var nameDraft = ""

    private var store: EnvironmentStore { appModel.environments }
    private var environments: [RoutingEnvironment] { store.environments }
    private var effects: [Effect] { store.activeEffects }
    private var assignments: [Equipment.ChannelAssignment] {
        Equipment.channelAssignments(from: appModel.equipment.items)
    }
    private var voices: [EnvironmentVoice] { appModel.environmentVoices() }
    private var allocations: [Effect.ID: EffectRouting.Allocation] {
        EffectRouting.allocations(for: effects)
    }

    enum NameMode {
        case new, rename
    }

    var body: some View {
        Group {
            if environments.isEmpty {
                noEnvironmentsState
            } else {
                builder
            }
        }
        .navigationTitle(store.active?.name ?? "Environments")
        .toolbar { toolbar }
        .sheet(item: $editing) { effect in
            EffectEditor(
                effect: effect,
                isNew: store.effect(effect.id) == nil,
                allEffects: effects,
                onSave: save,
                onDelete: store.effect(effect.id) == nil ? nil : { store.remove(effect) }
            )
            .environment(appModel)
        }
        .alert(nameMode == .rename ? "Rename Environment" : "New Environment", isPresented: nameAlertPresented) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) { nameMode = nil }
            Button(nameMode == .rename ? "Rename" : "Create") { commitName() }
        }
    }

    // MARK: - Builder

    private var builder: some View {
        List {
            environmentSection
            effectsSection
            instrumentsSection
            spaceSection
        }
    }

    private var environmentSection: some View {
        Section {
            Picker("Environment", selection: activeBinding) {
                ForEach(environments) { environment in
                    Text(environment.name).tag(environment.id)
                }
            }
            #if os(macOS)
            .pickerStyle(.menu)
            #endif

            EnvironmentSummary(effects: effects, voices: voices)
        } header: {
            Text("Environment")
        } footer: {
            Text("A saved rig: effects, instrument sends, spatial placement, and routing you can recall together.")
        }
    }

    private var effectsSection: some View {
        Section {
            if effects.isEmpty {
                ContentUnavailableView {
                    Label("No Effects Yet", systemImage: "waveform.path.ecg")
                } description: {
                    Text("Add the outboard boxes you want in this environment.")
                } actions: {
                    Button { addEffect() } label: {
                        Label("Add Effect", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ForEach(Array(effects.enumerated()), id: \.element.id) { index, effect in
                    SimpleEffectCard(
                        effect: effect,
                        allocation: allocations[effect.id],
                        sourceNames: sourceNames(for: effect),
                        destinationName: destinationName(for: effect),
                        onEdit: { editing = effect }
                    )
                    .contextMenu {
                        Button { editing = effect } label: { Label("Edit Details", systemImage: "slider.horizontal.3") }
                        Divider()
                        Button { moveUp(index) } label: { Label("Move Up", systemImage: "arrow.up") }
                            .disabled(index == 0)
                        Button { moveDown(index) } label: { Label("Move Down", systemImage: "arrow.down") }
                            .disabled(index == effects.count - 1)
                        Divider()
                        Button(role: .destructive) { delete(effect) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { delete(effect) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                .onDelete { store.remove(at: $0) }
                .onMove { store.move(fromOffsets: $0, toOffset: $1) }

                Button { addEffect() } label: {
                    Label("Add Effect", systemImage: "plus")
                }
            }
        } header: {
            Text("1 · Effects")
        } footer: {
            Text("Order only decides the automatic bus/return allocation. Tap a card for hardware jacks or chaining.")
        }
    }

    private var instrumentsSection: some View {
        Section {
            if assignments.isEmpty {
                ContentUnavailableView("No Instruments", systemImage: "pianokeys")
            } else if effects.isEmpty {
                Label("Add an effect first, then choose which instruments feed it.", systemImage: "arrow.up")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(assignments) { assignment in
                    InstrumentSendRow(
                        assignment: assignment,
                        effects: effects,
                        isSending: { effect in effect.feeds(assignment.equipment.id) },
                        toggle: { effect, isOn in
                            setInstrument(assignment.equipment.id, feeding: effect.id, isOn: isOn)
                        }
                    )
                }
            }
        } header: {
            Text("2 · Instrument Sends")
        } footer: {
            Text("Tap an effect name to send that instrument there. Dry sound stays on the main mix.")
        }
    }

    private var spaceSection: some View {
        Section {
            Button { appModel.requestSpatialPlacement() } label: {
                Label("Place This Environment in Space", systemImage: "hifispeaker.2")
            }
            .disabled(voices.isEmpty)

            if voices.isEmpty {
                Text("Once instruments feed effects, their dry signals and effect returns become placeable voices.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(voices) { voice in
                    VoiceRow(voice: voice)
                }
            }
        } header: {
            Text("3 · Space")
        } footer: {
            Text("Spatial placement stays part of this environment, so switching environments recalls the stage.")
        }
    }

    // MARK: - Empty state

    private var noEnvironmentsState: some View {
        ContentUnavailableView {
            Label("Create an Environment", systemImage: "rectangle.3.group")
        } description: {
            Text("Make one simple rig per song, set, or setup.")
        } actions: {
            Button { promptNewEnvironment() } label: {
                Label("New Environment", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Environments")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if !os(macOS)
        ToolbarItem(placement: .topBarLeading) {
            EditButton()
        }
        #endif
        ToolbarItem {
            environmentMenu
        }
        ToolbarItem {
            Button { addEffect() } label: {
                Label("Add Effect", systemImage: "plus")
            }
        }
        ToolbarItem {
            Button(action: applyEnvironment) {
                if isApplying {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Apply Environment", systemImage: "bolt.horizontal.circle")
                }
            }
            .disabled(!appModel.isConnected || appModel.environmentSettings().isEmpty || isApplying)
            .help("Send this environment to the console")
        }
    }

    private var environmentMenu: some View {
        Menu {
            Button { promptNewEnvironment() } label: {
                Label("New Environment", systemImage: "plus.rectangle.on.folder")
            }
            Button { promptRenameEnvironment() } label: {
                Label("Rename…", systemImage: "pencil")
            }
            .disabled(store.active == nil)
            Button { store.duplicateActive() } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .disabled(store.active == nil)
            Divider()
            Button(role: .destructive) { store.removeActive() } label: {
                Label("Delete Environment", systemImage: "trash")
            }
            .disabled(store.active == nil)
        } label: {
            Label("Environments", systemImage: "rectangle.3.group")
        }
    }

    // MARK: - Actions

    private func addEffect() {
        editing = Effect(name: "Effect \(effects.count + 1)")
    }

    private func save(_ effect: Effect) {
        if store.effect(effect.id) == nil {
            store.add(effect)
        } else {
            store.update(effect)
        }
    }

    private func setInstrument(_ instrument: Equipment.ID, feeding effectID: Effect.ID, isOn: Bool) {
        guard let effect = store.effect(effectID) else { return }
        store.update(effect.togglingSource(instrument, isOn))
    }

    private func moveUp(_ index: Int) {
        guard index > 0 else { return }
        store.move(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
    }

    private func moveDown(_ index: Int) {
        guard index < effects.count - 1 else { return }
        store.move(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
    }

    private func delete(_ effect: Effect) {
        store.remove(effect)
    }

    private func sourceNames(for effect: Effect) -> [String] {
        effect.sourceInstruments.compactMap { appModel.equipment.item($0)?.name }
    }

    private func destinationName(for effect: Effect) -> String? {
        guard let id = effect.destinationEffectID else { return nil }
        return effects.first { $0.id == id }?.name
    }

    private var activeBinding: Binding<RoutingEnvironment.ID> {
        Binding(
            get: { store.active?.id ?? store.environments.first?.id ?? UUID() },
            set: { store.setActive($0) }
        )
    }

    private var nameAlertPresented: Binding<Bool> {
        Binding(get: { nameMode != nil }, set: { if !$0 { nameMode = nil } })
    }

    private func promptNewEnvironment() {
        nameDraft = ""
        nameMode = .new
    }

    private func promptRenameEnvironment() {
        nameDraft = store.active?.name ?? ""
        nameMode = .rename
    }

    private func commitName() {
        let name = nameDraft.trimmingCharacters(in: .whitespaces)
        let mode = nameMode
        nameMode = nil
        guard !name.isEmpty else { return }
        switch mode {
        case .new: store.addEnvironment(named: name)
        case .rename: store.renameActive(to: name)
        case .none: break
        }
    }

    private func applyEnvironment() {
        isApplying = true
        Task {
            await appModel.applyEnvironment()
            isApplying = false
        }
    }
}

#Preview {
    NavigationStack {
        EnvironmentsView()
            .environment(AppModel.preview())
    }
}
