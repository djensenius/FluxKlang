//
//  EquipmentLibraryView.swift
//  FluxKlang
//
//  Picker sheet for adding nodes to the chain: WING endpoints (inputs, channels,
//  buses, mains, outputs) and the user's equipment library.
//

import SwiftUI

struct EquipmentLibraryView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    /// Called with the node kind and a display title to add.
    let onAdd: (ChainNodeKind, String) -> Void

    private let localInputCount = 24
    private let localOutputCount = 8

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { onAdd(.effect(UUID()), "") } label: {
                        Label("New Effect", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Effects")
                } footer: {
                    Text("An outboard effect (aux send). Wire instruments into it, and its output to Main.")
                }

                Section {
                    ForEach(appModel.equipment.items) { item in
                        Button {
                            onAdd(.effectSource(item.id), item.name)
                        } label: {
                            Label(item.name, systemImage: "pianokeys")
                        }
                    }
                } header: {
                    Text("Instruments")
                } footer: {
                    Text("Drop an instrument, then drag from it to an effect to feed it.")
                }

                Section("WING Endpoints") {
                    endpointMenu("WING Input", systemImage: "arrow.right.to.line", count: localInputCount) { index in
                        onAdd(.wingInput(index), "Local \(index)")
                    }
                    endpointMenu("Channel", systemImage: "dial.medium", count: WingNodeKind.channel.count) { index in
                        onAdd(.wingChannel(index), channelTitle(index))
                    }
                    endpointMenu("Bus", systemImage: "arrow.triangle.merge", count: WingNodeKind.bus.count) { index in
                        onAdd(.wingBus(index), "Bus \(index)")
                    }
                    endpointMenu("Main", systemImage: "speaker.wave.3", count: WingNodeKind.main.count) { index in
                        onAdd(.wingMain(index), "Main \(index)")
                    }
                    endpointMenu("WING Output", systemImage: "arrow.left.to.line", count: localOutputCount) { index in
                        onAdd(.wingOutput(index), "Output \(index)")
                    }
                }

                Section {
                    ForEach(appModel.equipment.items) { item in
                        Button {
                            onAdd(.equipment(item.id), item.name)
                        } label: {
                            Label(item.name, systemImage: "cable.connector")
                        }
                    }
                } header: {
                    Text("Gear (raw patch)")
                } footer: {
                    Text("For hand-patching gear to raw WING endpoints, outside the effect routing.")
                }
            }
            .navigationTitle("Add Node")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 460)
        #endif
    }

    private func channelTitle(_ index: Int) -> String {
        appModel.wing.name(.channel, index) ?? "Channel \(index)"
    }

    private func endpointMenu(
        _ title: String,
        systemImage: String,
        count: Int,
        add: @escaping (Int) -> Void
    ) -> some View {
        Menu {
            ForEach(1...count, id: \.self) { index in
                Button("\(title) \(index)") { add(index) }
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

#Preview {
    EquipmentLibraryView { _, _ in }
        .environment(AppModel.preview())
}
