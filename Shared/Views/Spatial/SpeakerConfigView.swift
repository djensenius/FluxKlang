//
//  SpeakerConfigView.swift
//  FluxKlang
//
//  Sheet for mapping each speaker to a WING bus, naming it and positioning it in
//  the array. Speakers default to the standard quad (buses 1–4) but the layout
//  is fully editable for larger or non-standard rigs.
//

import SwiftUI

struct SpeakerConfigView: View {
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    private var store: SpatialStore { appModel.spatial }
    private let buses = Array(1...WingNodeKind.bus.count)

    var body: some View {
        NavigationStack {
            Form {
                ForEach(store.array.speakers) { speaker in
                    Section(speaker.name) {
                        speakerRows(speaker)
                    }
                }
                Section {
                    Button("Reset to Standard Quad", role: .destructive) {
                        store.resetArray()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Configure Speakers")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 420)
    }

    @ViewBuilder
    private func speakerRows(_ speaker: Speaker) -> some View {
        TextField("Name", text: nameBinding(speaker))
        Picker("Driven by", selection: nodeBinding(speaker)) {
            ForEach(buses, id: \.self) { bus in
                Text(busLabel(bus)).tag(bus)
            }
        }
        positionSlider("Left / Right", value: positionBinding(speaker, axis: .horizontal))
        positionSlider("Front / Back", value: positionBinding(speaker, axis: .vertical))
    }

    private func positionSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
                .frame(width: 110, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text(String(format: "%.0f%%", value.wrappedValue * 100))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func busLabel(_ bus: Int) -> String {
        appModel.wing.name(.bus, bus) ?? "Bus \(bus)"
    }

    // MARK: - Bindings

    private func nameBinding(_ speaker: Speaker) -> Binding<String> {
        Binding(
            get: { speaker.name },
            set: { store.setSpeakerName(speaker.id, to: $0) }
        )
    }

    private func nodeBinding(_ speaker: Speaker) -> Binding<Int> {
        Binding(
            get: { speaker.node.index },
            set: { store.setSpeakerNode(speaker.id, to: .bus($0)) }
        )
    }

    private enum Axis { case horizontal, vertical }

    private func positionBinding(_ speaker: Speaker, axis: Axis) -> Binding<Double> {
        Binding(
            get: { axis == .horizontal ? Double(speaker.position.x) : Double(speaker.position.y) },
            set: { newValue in
                let position = axis == .horizontal
                    ? CGPoint(x: newValue, y: Double(speaker.position.y))
                    : CGPoint(x: Double(speaker.position.x), y: newValue)
                store.setSpeakerPosition(speaker.id, to: position)
            }
        )
    }
}

#Preview {
    let model = AppModel.preview()
    return SpeakerConfigView(appModel: model)
        .task { await model.spatial.load() }
}
