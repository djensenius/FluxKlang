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
                ForEach(effects) { effect in
                    Button { editing = effect } label: {
                        EffectRow(effect: effect, allocation: allocations[effect.id], equipment: appModel.equipment)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { appModel.effects.remove(at: $0) }
                .onMove { appModel.effects.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("""
                Buses and return channels are assigned automatically, counting down from the top so your \
                channel rig stays free. Reorder to change which effect claims which bus.
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
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts: [String] = []
        let count = effect.sourceInstruments.count
        parts.append(count == 1 ? "1 instrument" : "\(count) instruments")
        if let names = instrumentNames {
            parts.append(names)
        }
        if let busText { parts.append(busText) }
        return parts.joined(separator: " · ")
    }

    private var instrumentNames: String? {
        let names = effect.sourceInstruments.compactMap { equipment.item($0)?.name }
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown) +\(names.count - 2)" : shown
    }

    private var busText: String? {
        guard let allocation else { return nil }
        guard let bus = allocation.buses.first else { return "No free bus" }
        let buses = effect.isStereo && allocation.buses.count > 1 ? "Bus \(bus)/\(allocation.buses[1])" : "Bus \(bus)"
        let outs = effect.sendOutputs.map(String.init).joined(separator: "/")
        return "\(buses) → Out \(outs)"
    }
}

// MARK: - Editor

private struct EffectEditor: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Effect
    let isNew: Bool
    let onSave: (Effect) -> Void
    let onDelete: (() -> Void)?

    private static let outputRange = 1...8
    private static let inputRange = 1...WingSourceGroup.local.count

    init(effect: Effect, isNew: Bool, onSave: @escaping (Effect) -> Void, onDelete: (() -> Void)?) {
        _draft = State(initialValue: effect.normalizingJacks())
        self.isNew = isNew
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

                Section {
                    jackStepper("Send output (left)", binding: outputBinding(0), range: Self.outputRange)
                    if draft.isStereo {
                        jackStepper("Send output (right)", binding: outputBinding(1), range: Self.outputRange)
                    }
                } header: {
                    Text(draft.isStereo ? "WING Outputs → Effect Input" : "WING Output → Effect Input")
                } footer: {
                    Text("The physical output jacks your effect's input is plugged into.")
                }

                Section {
                    jackStepper("Return input (left)", binding: inputBinding(0), range: Self.inputRange)
                    if draft.isStereo {
                        jackStepper("Return input (right)", binding: inputBinding(1), range: Self.inputRange)
                    }
                } header: {
                    Text(draft.isStereo ? "Effect Output → WING Inputs" : "Effect Output → WING Input")
                } footer: {
                    Text("""
                    The physical input jacks your effect returns on. FluxKlang routes them to the main \
                    automatically.
                    """)
                }

                Section("Instruments") {
                    if appModel.equipment.items.isEmpty {
                        Text("No equipment in your library yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appModel.equipment.items) { item in
                            Toggle(item.name, isOn: instrumentBinding(item.id))
                        }
                    }
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
        .frame(minWidth: 380, minHeight: 460)
        #endif
    }

    private func jackStepper(_ title: String, binding: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: binding, in: range) {
            LabeledContent(title, value: "\(binding.wrappedValue)")
        }
    }

    private func instrumentBinding(_ id: Equipment.ID) -> Binding<Bool> {
        Binding(
            get: { draft.feeds(id) },
            set: { draft = draft.togglingSource(id, $0) }
        )
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
    /// jack clamped to a physically valid socket number.
    private func sanitizedDraft() -> Effect {
        var effect = draft.normalizingJacks()
        effect.sendOutputs = effect.sendOutputs.map { clamp($0, to: Self.outputRange) }
        effect.returnInputs = effect.returnInputs.map { clamp($0, to: Self.inputRange) }
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
