//
//  EnvironmentsView.swift
//  FluxKlang
//
//  The Environments screen: named, switchable routing setups. The user picks an
//  active environment, then keeps a list of outboard effects (each wired into
//  known WING output/input jacks) and ticks which instruments feed each one.
//  FluxKlang allocates the bridging bus and return channel automatically (see
//  `EffectRouting`) and can push the whole setup to the console with one tap.
//  Switching environments swaps the entire rig.
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
    private var voices: [EnvironmentVoice] { appModel.environmentVoices() }
    private var allocations: [Effect.ID: EffectRouting.Allocation] {
        EffectRouting.allocations(for: effects)
    }

    /// Whether the name prompt is creating a new environment or renaming one.
    enum NameMode {
        case new, rename
    }

    var body: some View {
        Group {
            if environments.isEmpty {
                noEnvironmentsState
            } else {
                list
            }
        }
        .navigationTitle(navigationTitle)
        .toolbar { toolbar }
        .sheet(item: $editing) { effect in
            EffectEditor(
                effect: effect,
                isNew: store.effect(effect.id) == nil,
                allEffects: effects,
                onSave: { saved in
                    if store.effect(saved.id) == nil {
                        store.add(saved)
                    } else {
                        store.update(saved)
                    }
                },
                onDelete: store.effect(effect.id) == nil ? nil : {
                    store.remove(effect)
                }
            )
            .environment(appModel)
        }
        .alert(nameMode == .rename ? "Rename Environment" : "New Environment", isPresented: nameAlertPresented) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) { nameMode = nil }
            Button(nameMode == .rename ? "Rename" : "Create") { commitName() }
        }
    }

    private var navigationTitle: String {
        store.active?.name ?? "Environments"
    }

    // MARK: - List

    private var list: some View {
        List {
            environmentSection
            effectsSection
            if !voices.isEmpty {
                voicesSection
            }
        }
    }

    private var environmentSection: some View {
        Section {
            Picker("Active", selection: activeBinding) {
                ForEach(environments) { environment in
                    Text(environment.name).tag(environment.id)
                }
            }
            #if os(macOS)
            .pickerStyle(.menu)
            #endif
        } header: {
            Text("Environment")
        } footer: {
            Text("""
            Switch setups instantly. Use the menu in the toolbar to add, rename, \
            duplicate, or delete environments.
            """)
        }
    }

    private var effectsSection: some View {
        Section {
            if effects.isEmpty {
                Button { addEffect() } label: {
                    Label("Add your first effect", systemImage: "plus")
                }
            }
            ForEach(Array(effects.enumerated()), id: \.element.id) { index, effect in
                HStack(spacing: 8) {
                    Button { editing = effect } label: {
                        EffectRow(
                            effect: effect,
                            allocation: allocations[effect.id],
                            destinationName: destinationName(for: effect),
                            equipment: appModel.equipment
                        )
                    }
.buttonStyle(.plain)
#if os(macOS)
Image(systemName: "line.3.horizontal")
    .font(.body)
    .foregroundStyle(.tertiary)
    .accessibilityHidden(true)
    .help("Drag to reorder")
#endif
                }
                .contextMenu {
                    Button { editing = effect } label: { Label("Edit…", systemImage: "pencil") }
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
        } header: {
            Text("Effects")
        } footer: {
            Text(effectsFooterText)
        }
    }

    private var effectsFooterText: LocalizedStringKey {
        #if os(macOS)
        """
        Order sets bus allocation — the first effect uses Bus 16, the next Bus 15, and so on. \
        Drag the grip handle to reorder, or right-click an effect to move it, edit it, or delete it.
        """
        #else
        """
        Order sets bus allocation — the first effect uses Bus 16, the next Bus 15, and so on. \
        Tap Edit to reorder, or touch and hold an effect to move it, edit it, or delete it.
        """
        #endif
    }

    private var voicesSection: some View {
        Section {
            Button { appModel.requestSpatialPlacement() } label: {
                Label("Open Spatial to place", systemImage: "hifispeaker.2")
            }
            ForEach(voices) { voice in
                VoiceRow(voice: voice)
            }
        } header: {
            Text("Spatial voices preview")
        } footer: {
            Text("""
            A preview of what you can place in space — these rows aren't draggable here. \
            Open the Spatial tab to position them. A shared effect sums its sources, so its return is \
            one voice carrying every instrument that feeds it; those move together.
            """)
        }
    }

    // MARK: - Empty state

    private var noEnvironmentsState: some View {
        ContentUnavailableView {
            Label("Create an Environment", systemImage: "rectangle.3.group")
        } description: {
            Text("""
            An environment is a named, switchable setup — your effects, how instruments feed them, and \
            where they go. Make one per song or scene and flip between them with a tap.
            """)
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
            .help("Add an outboard effect to this environment")
        }
        ToolbarItem {
            Button(action: applyEnvironment) {
                if isApplying {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Apply", systemImage: "bolt.horizontal.circle")
                }
            }
            .disabled(!appModel.isConnected || appModel.environmentSettings().isEmpty || isApplying)
            .help("Send this environment's sends and returns to the console")
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
        .help("Add, rename, duplicate, or delete environments")
    }

    // MARK: - Actions

    private func addEffect() {
        editing = Effect(name: "Effect \(effects.count + 1)")
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

// MARK: - Voice row

private struct VoiceRow: View {
    let voice: EnvironmentVoice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: voice.kind == .source ? "pianokeys" : "waveform")
                .foregroundStyle(voice.kind == .source ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name)
                    .font(.subheadline)
                if voice.isShared {
                    Text(voice.sourcesLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !voice.channels.isEmpty {
                Text(channelLabel)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var channelLabel: String {
        let channels = voice.channels.map(String.init).joined(separator: "/")
        let prefix = voice.kind == .source ? "Ch" : "Rtn"
        return "\(prefix) \(channels)"
    }
}

#Preview {
    NavigationStack {
        EnvironmentsView()
            .environment(AppModel.preview())
    }
}
