//
//  StudioConnectorEditor.swift
//  FluxKlang
//

import SwiftUI

enum StudioConnectorDirection: Equatable {
    case input
    case output

    var title: String {
        switch self {
        case .input: "WING Input"
        case .output: "WING Output"
        }
    }

    var equipmentSide: String {
        switch self {
        case .input: "Equipment Output"
        case .output: "Equipment Input"
        }
    }
}

struct StudioConnectorEditor: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let direction: StudioConnectorDirection
    let connector: Int
    var outputBank: WingOutputConnectorBank = .local

    @State private var equipmentID: Equipment.ID?
    @State private var port: Int?
    @State private var namedDestination = ""
    @State private var labelOverride = ""
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var isSaving = false

    private var equipment: [Equipment] { appModel.equipment.items }
    private var home: StudioHomeConnections { appModel.studioConnections.connections.home }
    private var selectedEquipment: Equipment? { equipment.first { $0.id == equipmentID } }

    var body: some View {
        Form {
            assignmentSection
            labelSection
            actionSection
        }
        .navigationTitle(connectorTitle)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { loadDraft() }
        .alert("Couldn’t Save Connection", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "The assignment could not be saved.")
        }
    }

    private var assignmentSection: some View {
        Section("Assignment") {
            if direction == .output {
                TextField("Named destination", text: $namedDestination)
                    .accessibilityIdentifier("studio-connection-named-destination")
                Text("Use this for speakers or another destination that is not in Equipment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Equipment", selection: equipmentBinding) {
                Text("Not assigned").tag(Equipment.ID?.none)
                if let equipmentID,
                   !equipment.contains(where: { $0.id == equipmentID }) {
                    Text("Missing equipment").tag(Equipment.ID?.some(equipmentID))
                }
                ForEach(equipment) { item in
                    Text(item.name).tag(Equipment.ID?.some(item.id))
                }
            }
            .accessibilityIdentifier("studio-connection-equipment")

            if let selectedEquipment {
                Picker(direction.equipmentSide, selection: portBinding) {
                    Text("Select a port").tag(Int?.none)
                    ForEach(Array(portNames(for: selectedEquipment).enumerated()), id: \.offset) { index, name in
                        Text("\(index + 1) · \(name)")
                            .tag(Int?.some(index))
                            .disabled(isPortInUse(equipmentID: selectedEquipment.id, port: index))
                    }
                }
                .accessibilityIdentifier("studio-connection-port")

                if portNames(for: selectedEquipment).isEmpty {
                    Label(
                        "\(selectedEquipment.name) has no \(direction.equipmentSide.lowercased()) ports.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
            }
        }
    }

    private var labelSection: some View {
        Section {
            TextField("Optional label override", text: $labelOverride)
                .accessibilityIdentifier("studio-connection-label-override")
            LabeledContent("Derived label", value: derivedLabel)
            if let suggestion = inputScribbleSuggestion {
                Button("Use “\(suggestion)” as label") {
                    labelOverride = suggestion
                }
                .accessibilityIdentifier("studio-connection-import-input-name")
                Text("Confirmed live WING input scribble name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Friendly Label")
        } footer: {
            Text("\(connectorTitle) is always shown with this friendly name.")
        }
    }

    private var actionSection: some View {
        Section {
            Button("Save Home Assignment") { save() }
                .disabled(!canSave || isSaving)
                .accessibilityIdentifier("studio-connection-save")
            if isAssigned {
                Button("Clear Assignment", role: .destructive) { clear() }
                    .disabled(isSaving)
                    .accessibilityIdentifier("studio-connection-clear")
            }
        }
    }

    private var equipmentBinding: Binding<Equipment.ID?> {
        Binding(
            get: { equipmentID },
            set: { newValue in
                equipmentID = newValue
                if newValue != nil {
                    namedDestination = ""
                }
                guard let newValue,
                      let item = equipment.first(where: { $0.id == newValue }) else {
                    port = nil
                    return
                }
                let names = portNames(for: item)
                if let port, names.indices.contains(port),
                   !isPortInUse(equipmentID: newValue, port: port) {
                    return
                }
                port = names.indices.first { !isPortInUse(equipmentID: newValue, port: $0) }
            }
        )
    }

    private var portBinding: Binding<Int?> {
        Binding(get: { port }, set: { port = $0 })
    }

    private var isAssigned: Bool {
        switch direction {
        case .input: home.input(connector) != nil
        case .output: home.output(connector, bank: outputBank) != nil
        }
    }

    private var canSave: Bool {
        if direction == .output,
           !namedDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard let selectedEquipment, let port else { return false }
        return portNames(for: selectedEquipment).indices.contains(port)
            && !isPortInUse(equipmentID: selectedEquipment.id, port: port)
    }

    private var derivedLabel: String {
        let override = labelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return "\(connectorTitle) · \(override)" }
        let destination = namedDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        if direction == .output, !destination.isEmpty {
            return "\(connectorTitle) · \(destination)"
        }
        guard let selectedEquipment, let port,
              portNames(for: selectedEquipment).indices.contains(port) else {
            return connectorTitle
        }
        return "\(connectorTitle) · \(selectedEquipment.name) · \(portNames(for: selectedEquipment)[port])"
    }

    private var connectorTitle: String {
        direction == .input
            ? "\(direction.title) \(connector)"
            : WingOutputConnector(bank: outputBank, index: connector).label
    }

    private var inputScribbleSuggestion: String? {
        guard direction == .input else { return nil }
        let value = appModel.wing.inputName(connector)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func portNames(for equipment: Equipment) -> [String] {
        switch direction {
        case .input: equipment.outputs
        case .output: equipment.inputs
        }
    }

    private func isPortInUse(equipmentID: Equipment.ID, port: Int) -> Bool {
        switch direction {
        case .input:
            home.inputs.contains {
                $0.connector != connector && $0.equipmentID == equipmentID && $0.outputPort == port
            }
        case .output:
            home.outputs.contains {
                $0.outputConnector != WingOutputConnector(bank: outputBank, index: connector)
                    && $0.equipmentID == equipmentID
                    && $0.inputPort == port
            }
        }
    }

    private func loadDraft() {
        guard !hasLoaded else { return }
        hasLoaded = true
        switch direction {
        case .input:
            guard let connection = home.input(connector) else { return }
            equipmentID = connection.equipmentID
            port = validatedPort(connection.outputPort, equipmentID: connection.equipmentID)
            labelOverride = connection.labelOverride ?? ""
        case .output:
            guard let connection = home.output(connector, bank: outputBank) else { return }
            equipmentID = connection.equipmentID
            if let equipmentID = connection.equipmentID, let inputPort = connection.inputPort {
                port = validatedPort(inputPort, equipmentID: equipmentID)
            }
            namedDestination = connection.destinationName ?? ""
            labelOverride = connection.labelOverride ?? ""
        }
    }

    private func validatedPort(_ candidate: Int, equipmentID: Equipment.ID) -> Int? {
        guard let item = equipment.first(where: { $0.id == equipmentID }) else { return nil }
        return portNames(for: item).indices.contains(candidate) ? candidate : nil
    }

    private func save() {
        guard canSave else { return }
        let override = labelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        Task { @MainActor in
            do {
                switch direction {
                case .input:
                    guard let equipmentID, let port else { return }
                    try await appModel.studioConnections.setInput(
                        StudioInputConnection(
                            connector: connector,
                            equipmentID: equipmentID,
                            outputPort: port,
                            labelOverride: override.isEmpty ? nil : override
                        ),
                        connector: connector,
                        equipment: equipment
                    )
                case .output:
                    try await saveOutput(labelOverride: override)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func saveOutput(labelOverride: String) async throws {
        let destination = namedDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        let connection: StudioOutputConnection
        if !destination.isEmpty {
            connection = StudioOutputConnection(
                bank: outputBank,
                connector: connector,
                destinationName: destination,
                labelOverride: labelOverride.isEmpty ? nil : labelOverride
            )
        } else {
            guard let equipmentID, let port else { return }
            connection = StudioOutputConnection(
                bank: outputBank,
                connector: connector,
                equipmentID: equipmentID,
                inputPort: port,
                labelOverride: labelOverride.isEmpty ? nil : labelOverride
            )
        }
        try await appModel.studioConnections.setOutput(
            connection,
            connector: connector,
            bank: outputBank,
            equipment: equipment
        )
    }

    private func clear() {
        isSaving = true
        Task { @MainActor in
            do {
                switch direction {
                case .input:
                    try await appModel.studioConnections.setInput(
                        nil,
                        connector: connector,
                        equipment: equipment
                    )
                case .output:
                    try await appModel.studioConnections.setOutput(
                        nil,
                        connector: connector,
                        bank: outputBank,
                        equipment: equipment
                    )
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
