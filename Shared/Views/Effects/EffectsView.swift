//
//  EffectsView.swift
//  FluxKlang
//
//  The "effects get instruments" screen. The user keeps a list of outboard
//  effects (each wired into known WING output/input jacks) and ticks which
//  instruments feed each one. FluxKlang allocates the bridging bus and return
//  channel automatically (see `EffectRouting`) and can push the whole setup to
//  the console with one tap.
//

import SwiftUI

struct EffectsView: View {
    @Environment(AppModel.self) private var appModel

    @State private var editing: Effect?
    @State private var isApplying = false

    private var effects: [Effect] { appModel.effects.effects }
    private var allocations: [Effect.ID: EffectRouting.Allocation] {
        EffectRouting.allocations(for: effects)
    }

    var body: some View {
        Group {
            if effects.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Effects")
        .toolbar { toolbar }
        .sheet(item: $editing) { effect in
            EffectEditor(
                effect: effect,
                isNew: appModel.effects.effect(effect.id) == nil,
                allEffects: effects,
                onSave: { saved in
                    if appModel.effects.effect(saved.id) == nil {
                        appModel.effects.add(saved)
                    } else {
                        appModel.effects.update(saved)
                    }
                },
                onDelete: appModel.effects.effect(effect.id) == nil ? nil : {
                    appModel.effects.remove(effect)
                }
            )
            .environment(appModel)
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            Section {
                ForEach(Array(effects.enumerated()), id: \.element.id) { index, effect in
                    Button { editing = effect } label: {
                        EffectRow(
                            effect: effect,
                            allocation: allocations[effect.id],
                            destinationName: destinationName(for: effect),
                            equipment: appModel.equipment
                        )
                    }
                    .buttonStyle(.plain)
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
                .onDelete { appModel.effects.remove(at: $0) }
                .onMove { appModel.effects.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("""
                Effects claim buses from the top down — the first uses Bus 16, the next Bus 15, and so on. \
                Drag to reorder, or right-click an effect to move it or delete it.
                """)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Route Effects to Instruments", systemImage: "wand.and.rays")
        } description: {
            Text("""
            Add an outboard effect, pick which instruments feed it, and FluxKlang wires up the buses \
            and returns for you.
            """)
        } actions: {
            Button { addEffect() } label: {
                Label("Add Effect", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Effects")
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
            Button { addEffect() } label: {
                Label("Add Effect", systemImage: "plus")
            }
            .help("Add an outboard effect")
        }
        ToolbarItem {
            Button(action: applyEffects) {
                if isApplying {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Apply", systemImage: "bolt.horizontal.circle")
                }
            }
            .disabled(!appModel.isConnected || appModel.effectSettings().isEmpty || isApplying)
            .help("Send the effect sends and returns to the console")
        }
    }

    // MARK: - Actions

    private func addEffect() {
        editing = Effect(name: "Effect \(effects.count + 1)")
    }

    private func moveUp(_ index: Int) {
        guard index > 0 else { return }
        appModel.effects.move(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
    }

    private func moveDown(_ index: Int) {
        guard index < effects.count - 1 else { return }
        appModel.effects.move(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
    }

    private func delete(_ effect: Effect) {
        appModel.effects.remove(effect)
    }

    private func destinationName(for effect: Effect) -> String? {
        guard let id = effect.destinationEffectID else { return nil }
        return effects.first { $0.id == id }?.name
    }

    private func applyEffects() {
        isApplying = true
        Task {
            await appModel.applyEffects()
            isApplying = false
        }
    }
}

// MARK: - Row

private struct EffectRow: View {
    let effect: Effect
    let allocation: EffectRouting.Allocation?
    let destinationName: String?
    let equipment: EquipmentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(effect.name)
                    .font(.headline)
                Spacer()
                Text(effect.isStereo ? "Stereo" : "Mono")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(instrumentSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(routingSummary, systemImage: "arrow.triangle.branch")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var instrumentSummary: String {
        let count = effect.sourceInstruments.count
        let prefix = count == 1 ? "1 instrument" : "\(count) instruments"
        guard let names = instrumentNames else { return prefix }
        return "\(prefix): \(names)"
    }

    private var instrumentNames: String? {
        let names = effect.sourceInstruments.compactMap { equipment.item($0)?.name }
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown) +\(names.count - 2)" : shown
    }

    /// A compact left-to-right description of the signal path.
    private var routingSummary: String {
        let outs = effect.sendOutputs.map(String.init).joined(separator: "/")
        let ins = effect.returnInputs.map(String.init).joined(separator: "/")
        let destination = destinationName ?? "Main"
        guard let allocation, let bus = allocation.buses.first else {
            return "No free bus available"
        }
        let buses = effect.isStereo && allocation.buses.count > 1 ? "\(bus)/\(allocation.buses[1])" : "\(bus)"
        return "Bus \(buses) → Out \(outs) → In \(ins) → \(destination)"
    }
}

// MARK: - Editor

private struct EffectEditor: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Effect
    let isNew: Bool
    let allEffects: [Effect]
    let onSave: (Effect) -> Void
    let onDelete: (() -> Void)?

    private static let outputRange = 1...8
    private static let inputRange = 1...WingSourceGroup.local.count

    init(
        effect: Effect,
        isNew: Bool,
        allEffects: [Effect],
        onSave: @escaping (Effect) -> Void,
        onDelete: (() -> Void)?
    ) {
        _draft = State(initialValue: effect.normalizingJacks())
        self.isNew = isNew
        self.allEffects = allEffects
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Effect") {
                    TextField("Name", text: $draft.name)
                    Toggle("Stereo", isOn: $draft.isStereo)
                }

                Section("Signal flow") {
                    flowStep(1, "The instruments you pick feed a private bus.")
                    flowStep(2, "That bus is sent out the WING output(s) into your effect.")
                    flowStep(3, "Your effect's output comes back on the WING input(s).")
                    flowStep(4, "The return goes to the Main — or into another effect, to chain them.")
                }

                Section {
                    if appModel.equipment.items.isEmpty {
                        Text("No equipment in your library yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appModel.equipment.items) { item in
                            Toggle(item.name, isOn: instrumentBinding(item.id))
                        }
                    }
                } header: {
                    Text("1 · Instruments")
                } footer: {
                    Text("These instruments are sent to the effect in parallel; their dry signal is untouched.")
                }

                Section {
                    if draft.isStereo {
                        jackStepper("Left output", binding: outputBinding(0), range: Self.outputRange)
                        jackStepper("Right output", binding: outputBinding(1), range: Self.outputRange)
                    } else {
                        jackStepper("WING output", binding: outputBinding(0), range: Self.outputRange)
                    }
                } header: {
                    Text("2 · Out to effect")
                } footer: {
                    Text("The physical WING output jack(s) your effect's input is plugged into.")
                }

                Section {
                    if draft.isStereo {
                        jackStepper("Left input", binding: inputBinding(0), range: Self.inputRange)
                        jackStepper("Right input", binding: inputBinding(1), range: Self.inputRange)
                    } else {
                        jackStepper("WING input", binding: inputBinding(0), range: Self.inputRange)
                    }
                } header: {
                    Text("3 · Back from effect")
                } footer: {
                    Text("The physical WING input jack(s) your effect returns on.")
                }

                Section {
                    Picker("Output goes to", selection: destinationBinding) {
                        Text("Main").tag(Effect.ID?.none)
                        ForEach(destinationOptions) { option in
                            Text(option.name).tag(Effect.ID?.some(option.id))
                        }
                    }
                } header: {
                    Text("4 · Where it goes")
                } footer: {
                    Text("""
                    Send the output to the Main (parallel), or into another effect to chain them in series \
                    (e.g. Synth → Reverb → Delay → Main). Only the last effect in a chain reaches the Main.
                    """)
                }

                if let onDelete {
                    Section {
                        Button("Delete Effect", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Effect" : "Edit Effect")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(sanitizedDraft())
                        dismiss()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 520, idealHeight: 600)
        #endif
    }

    private func flowStep(_ number: Int, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.tint)
        }
        .font(.subheadline)
    }

    private func jackStepper(_ title: String, binding: Binding<Int>, range: ClosedRange<Int>) -> some View {
        LabeledContent(title) {
            Stepper(value: binding, in: range) {
                Text(binding.wrappedValue.description)
                    .monospacedDigit()
            }
        }
    }

    private func instrumentBinding(_ id: Equipment.ID) -> Binding<Bool> {
        Binding(
            get: { draft.feeds(id) },
            set: { draft = draft.togglingSource(id, $0) }
        )
    }

    private var destinationBinding: Binding<Effect.ID?> {
        Binding(
            get: { draft.destinationEffectID },
            set: { draft.destinationEffectID = $0 }
        )
    }

    /// Other effects this one may feed without forming a cycle.
    private var destinationOptions: [Effect] {
        allEffects.filter { $0.id != draft.id && !wouldCycle(feeding: $0) }
    }

    /// Whether routing `draft` into `candidate` would close a loop, i.e. the
    /// candidate already feeds back to `draft` (directly or transitively).
    private func wouldCycle(feeding candidate: Effect) -> Bool {
        let byID = Dictionary(allEffects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var current: Effect.ID? = candidate.destinationEffectID
        var steps = 0
        while let id = current {
            if id == draft.id { return true }
            steps += 1
            if steps > byID.count { return true }
            current = byID[id]?.destinationEffectID
        }
        return false
    }

    private func outputBinding(_ index: Int) -> Binding<Int> {
        jackBinding(\.sendOutputs, index, range: Self.outputRange)
    }

    private func inputBinding(_ index: Int) -> Binding<Int> {
        jackBinding(\.returnInputs, index, range: Self.inputRange)
    }

    private func jackBinding(
        _ keyPath: WritableKeyPath<Effect, [Int]>,
        _ index: Int,
        range: ClosedRange<Int>
    ) -> Binding<Int> {
        Binding(
            get: {
                let values = draft[keyPath: keyPath]
                let raw: Int
                if values.indices.contains(index) {
                    raw = values[index]
                } else if index == 1, let first = values.first {
                    raw = first + 1
                } else {
                    raw = index + 1
                }
                return clamp(raw, to: range)
            },
            set: { newValue in
                var values = draft[keyPath: keyPath]
                while values.count <= index {
                    values.append((values.last ?? 0) + 1)
                }
                values[index] = clamp(newValue, to: range)
                draft[keyPath: keyPath] = values
            }
        )
    }

    /// The draft with its jack arrays sized to the stereo/mono width and every
    /// jack clamped to a physically valid socket number, and any stale or cyclic
    /// destination dropped back to the main.
    private func sanitizedDraft() -> Effect {
        var effect = draft.normalizingJacks()
        effect.sendOutputs = effect.sendOutputs.map { clamp($0, to: Self.outputRange) }
        effect.returnInputs = effect.returnInputs.map { clamp($0, to: Self.inputRange) }
        if let destination = effect.destinationEffectID, !destinationOptions.contains(where: { $0.id == destination }) {
            effect.destinationEffectID = nil
        }
        return effect
    }

    private func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

#Preview {
    NavigationStack {
        EffectsView()
            .environment(AppModel.preview())
    }
}
