//
//  StudioConnectionsView.swift
//  FluxKlang
//
//  Edits the global Home wiring map and manages Temporary Moves that overlay it.
//

import SwiftUI
struct StudioConnectionsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isMovingEquipment = false
    @State private var returningMove: TemporaryDeviceMove?
    private var home: StudioHomeConnections { appModel.studioConnections.connections.home }

    var body: some View {
        let issues = StudioPhysicalResolver(connections: home, equipment: appModel.equipment.items).structuralIssues()
        List {
            Section {
                Label(
                    "Home stays immutable. Active Temporary Moves overlay it until Return Home is applied.",
                    systemImage: "house"
                )
                Button {
                    isMovingEquipment = true
                } label: {
                    Label("Move Equipment Temporarily", systemImage: "arrow.right.arrow.left")
                }
                .accessibilityIdentifier("studio-connections-move-temporarily")
            }

            if !appModel.studioConnections.connections.temporaryMoves.isEmpty {
                Section("Temporary Moves") {
                    ForEach(appModel.studioConnections.connections.temporaryMoves) { move in
                        temporaryMoveRow(move)
                    }
                }
            }

            Section("WING Inputs") {
                ForEach(StudioHomeConnections.inputRange, id: \.self) { connector in
                    NavigationLink {
                        StudioConnectorEditor(direction: .input, connector: connector)
                    } label: {
                        connectorRow(direction: .input, connector: connector, issues: issues)
                    }
                    .accessibilityIdentifier("studio-connection-input-\(connector)")
                    .accessibilityHint("Opens the Home assignment editor for WING input \(connector)")
                }
            }

            Section("WING Outputs") {
                ForEach(StudioHomeConnections.outputRange, id: \.self) { connector in
                    NavigationLink {
                        StudioConnectorEditor(direction: .output, connector: connector)
                    } label: {
                        connectorRow(direction: .output, connector: connector, issues: issues)
                    }
                    .accessibilityIdentifier("studio-connection-output-\(connector)")
                    .accessibilityHint("Opens the Home assignment editor for WING output \(connector)")
                }
            }

            if !issues.isEmpty {
                Section("Needs Attention") {
                    ForEach(issues) { issue in
                        Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Studio Connections")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $isMovingEquipment) {
            TemporaryMoveFlowView()
                .environment(appModel)
        }
        .sheet(item: $returningMove) { move in
            TemporaryMoveFlowView(returning: move)
                .environment(appModel)
        }
    }
    private func temporaryMoveRow(_ move: TemporaryDeviceMove) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(equipmentName(move.equipmentID), systemImage: "shippingbox.and.arrow.backward")
                    .font(.headline)
                Text("Moved")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.18), in: Capsule())
                Spacer()
                Text(move.verification.state.label)
                    .font(.caption)
                    .foregroundStyle(move.verification.state == .verified ? .green : .orange)
                    .accessibilityLabel("Routing verification")
                    .accessibilityValue(move.verification.state.label)
            }
            Text(move.connectorSummary(home: home))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Return Home") { returningMove = move }
                .accessibilityIdentifier("temporary-move-return-\(move.id.uuidString)")
                .accessibilityLabel("Return \(equipmentName(move.equipmentID)) Home")
        }
        .padding(.vertical, 3)
    }
    private func equipmentName(_ id: Equipment.ID) -> String {
        appModel.equipment.items.first { $0.id == id }?.name ?? "Missing equipment"
    }
    private func connectorRow(
        direction: StudioConnectorDirection,
        connector: Int,
        issues: [StudioConnectionIssue]
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(direction: direction, connector: connector))
                Text(isAssigned(direction: direction, connector: connector) ? "Home assignment" : "Not assigned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasIssue(direction: direction, connector: connector, issues: issues) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Connection problem")
            }
        }
    }

    private func displayName(direction: StudioConnectorDirection, connector: Int) -> String {
        switch direction {
        case .input:
            return home.inputDisplayName(
                connector,
                equipment: appModel.equipment.items,
                liveScribble: appModel.wing.inputName(connector)
            )
        case .output:
            return home.outputDisplayName(connector, equipment: appModel.equipment.items)
        }
    }

    private func isAssigned(direction: StudioConnectorDirection, connector: Int) -> Bool {
        switch direction {
        case .input: home.input(connector) != nil
        case .output: home.output(connector) != nil
        }
    }

    private func hasIssue(
        direction: StudioConnectorDirection,
        connector: Int,
        issues: [StudioConnectionIssue]
    ) -> Bool {
        issues.contains { issue in
            switch (direction, issue.kind) {
            case (.input, .duplicateInputConnector(let value)),
                 (.input, .inputConnectorOutOfRange(let value)):
                return value == connector
            case (.output, .duplicateOutputConnector(let value)),
                 (.output, .outputConnectorOutOfRange(let value)):
                return value == connector
            case (.input, .missingEquipment(let equipmentID)):
                return home.input(connector)?.equipmentID == equipmentID
            case (.output, .missingEquipment(let equipmentID)):
                return home.output(connector)?.equipmentID == equipmentID
            case (.input, .invalidOutputPort(let equipmentID, let port)):
                return home.input(connector).map {
                    $0.equipmentID == equipmentID && $0.outputPort == port
                } ?? false
            case (.output, .invalidInputPort(let equipmentID, let port)):
                return home.output(connector).map {
                    $0.equipmentID == equipmentID && $0.inputPort == port
                } ?? false
            case (.input, .conflictingOutputPort(let equipmentID, let port)):
                return home.input(connector).map {
                    $0.equipmentID == equipmentID && $0.outputPort == port
                } ?? false
            case (.output, .conflictingInputPort(let equipmentID, let port)):
                return home.output(connector).map {
                    $0.equipmentID == equipmentID && $0.inputPort == port
                } ?? false
            default:
                return false
            }
        }
    }
}

private enum StudioConnectorDirection: Equatable {
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

private struct StudioConnectorEditor: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let direction: StudioConnectorDirection
    let connector: Int

    @State private var equipmentID: Equipment.ID?
    @State private var port: Int?
    @State private var labelOverride = ""
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var isSaving = false

    private var equipment: [Equipment] { appModel.equipment.items }
    private var home: StudioHomeConnections { appModel.studioConnections.connections.home }
    private var selectedEquipment: Equipment? { equipment.first { $0.id == equipmentID } }
    var body: some View {
        Form {
            Section("Assignment") {
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
                Text("Connector \(connector) is always shown with this friendly name.")
            }

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
        .navigationTitle("\(direction.title) \(connector)")
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

    private var equipmentBinding: Binding<Equipment.ID?> {
        Binding(
            get: { equipmentID },
            set: { newValue in
                equipmentID = newValue
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
        case .output: home.output(connector) != nil
        }
    }

    private var canSave: Bool {
        guard let selectedEquipment, let port else { return false }
        return portNames(for: selectedEquipment).indices.contains(port)
            && !isPortInUse(equipmentID: selectedEquipment.id, port: port)
    }

    private var derivedLabel: String {
        let override = labelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return "\(direction.title) \(connector) · \(override)" }
        guard let selectedEquipment, let port,
              portNames(for: selectedEquipment).indices.contains(port) else {
            return "\(direction.title) \(connector)"
        }
        let portName = portNames(for: selectedEquipment)[port]
        return "\(direction.title) \(connector) · \(selectedEquipment.name) · \(portName)"
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
            return home.inputs.contains {
                $0.connector != connector && $0.equipmentID == equipmentID && $0.outputPort == port
            }
        case .output:
            return home.outputs.contains {
                $0.connector != connector && $0.equipmentID == equipmentID && $0.inputPort == port
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
            guard let connection = home.output(connector) else { return }
            equipmentID = connection.equipmentID
            port = validatedPort(connection.inputPort, equipmentID: connection.equipmentID)
            labelOverride = connection.labelOverride ?? ""
        }
    }

    private func validatedPort(_ candidate: Int, equipmentID: Equipment.ID) -> Int? {
        guard let item = equipment.first(where: { $0.id == equipmentID }) else { return nil }
        return portNames(for: item).indices.contains(candidate) ? candidate : nil
    }

    private func save() {
        guard canSave, let equipmentID, let port else { return }
        let override = labelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        Task { @MainActor in
            do {
                switch direction {
                case .input:
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
                    try await appModel.studioConnections.setOutput(
                        StudioOutputConnection(
                            connector: connector,
                            equipmentID: equipmentID,
                            inputPort: port,
                            labelOverride: override.isEmpty ? nil : override
                        ),
                        connector: connector,
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

#Preview {
    NavigationStack { StudioConnectionsView() }
        .environment(AppModel.preview())
}
