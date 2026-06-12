//
//  EffectEditor.swift
//  FluxKlang
//
//  The add/edit sheet for a single outboard effect within an environment. The
//  user names it, picks stereo/mono, ticks which instruments feed it, sets the
//  physical WING output/input jacks it is patched to, and chooses where its
//  return goes — the Main (parallel) or another effect (serial chain). Cyclic
//  destinations are filtered out so a chain can never loop back on itself.
//

import SwiftUI

struct EffectEditor: View {
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
                        jackStepper(
                            "Left output", binding: outputBinding(0), range: Self.outputRange, name: outputName
                        )
                        jackStepper(
                            "Right output", binding: outputBinding(1), range: Self.outputRange, name: outputName
                        )
                    } else {
                        jackStepper("WING output", binding: outputBinding(0), range: Self.outputRange, name: outputName)
                    }
                } header: {
                    Text("2 · Out to effect")
                } footer: {
                    Text("The physical WING output jack(s) your effect's input is plugged into.")
                }

                Section {
                    if draft.isStereo {
                        jackStepper(
                            "Left input", binding: inputBinding(0), range: Self.inputRange, name: inputName
                        )
                        jackStepper(
                            "Right input", binding: inputBinding(1), range: Self.inputRange, name: inputName
                        )
                    } else {
                        jackStepper("WING input", binding: inputBinding(0), range: Self.inputRange, name: inputName)
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

    private func jackStepper(
        _ title: String,
        binding: Binding<Int>,
        range: ClosedRange<Int>,
        name: (Int) -> String?
    ) -> some View {
        let connector = binding.wrappedValue
        let label = name(connector).flatMap { $0.isEmpty ? nil : $0 }
        return LabeledContent(title) {
            Stepper(value: binding, in: range) {
                Text(label.map { "\(connector) · \($0)" } ?? connector.description)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    /// The WING name of an output connector, when the console has reported one.
    private func outputName(_ connector: Int) -> String? {
        appModel.wing.outputName(connector)
    }

    /// The WING name of an input connector, when the console has reported one.
    private func inputName(_ connector: Int) -> String? {
        appModel.wing.inputName(connector)
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
