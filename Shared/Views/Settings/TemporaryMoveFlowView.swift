//
//  TemporaryMoveFlowView.swift
//  FluxKlang
//

import SwiftUI

struct TemporaryMoveFlowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let returningMove: TemporaryDeviceMove?

    @State private var equipmentID: Equipment.ID?
    @State private var location = ""
    @State private var note = ""
    @State private var inputConnectors: [Int] = []
    @State private var outputConnectors: [Int] = []
    @State private var cablesConfirmed = false
    @State private var isApplying = false
    @State private var result: TemporaryMoveVerification?
    @State private var errorMessage: String?
    @State private var loaded = false

    init(initialEquipmentID: Equipment.ID? = nil, returning move: TemporaryDeviceMove? = nil) {
        returningMove = move
        _equipmentID = State(initialValue: move?.equipmentID ?? initialEquipmentID)
        _location = State(initialValue: move?.location ?? "")
        _note = State(initialValue: move?.note ?? "")
        _inputConnectors = State(initialValue: move?.connections.inputs.map(\.connector) ?? [])
        _outputConnectors = State(initialValue: move?.connections.outputs.map(\.connector) ?? [])
    }

    private var home: StudioHomeConnections { appModel.studioConnections.connections.home }
    private var equipment: [Equipment] { appModel.equipment.items }
    private var selectedEquipment: Equipment? { equipment.first { $0.id == equipmentID } }
    private var homeInputs: [StudioInputConnection] {
        home.inputs.filter { $0.equipmentID == equipmentID }.sorted { $0.outputPort < $1.outputPort }
    }
    private var homeOutputs: [StudioOutputConnection] {
        home.outputs.filter { $0.equipmentID == equipmentID }.sorted { $0.inputPort < $1.inputPort }
    }

    var body: some View {
        NavigationStack {
            Form {
                equipmentSection
                connectorSection
                cableSection
                routingSection
                resultSection
            }
            .navigationTitle(returningMove == nil ? "Move Temporarily" : "Return Home")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { loadSuggestionIfNeeded() }
            .onChange(of: equipmentID) {
                guard returningMove == nil else { return }
                loadSuggestion()
            }
            .alert("Temporary Move", isPresented: errorPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "The temporary move could not be completed.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 620, idealHeight: 760)
        #endif
    }

    private var equipmentSection: some View {
        Section("1 · Equipment") {
            if returningMove == nil {
                Picker("Equipment", selection: $equipmentID) {
                    Text("Choose equipment").tag(Equipment.ID?.none)
                    if let equipmentID, selectedEquipment == nil {
                        Text("Missing equipment").tag(Equipment.ID?.some(equipmentID))
                    }
                    ForEach(movableEquipment) { item in
                        Text(item.name).tag(Equipment.ID?.some(item.id))
                    }
                }
                .accessibilityIdentifier("temporary-move-equipment")
            } else {
                LabeledContent("Equipment", value: selectedEquipment?.name ?? "Missing equipment")
            }
            TextField("Optional location", text: $location).disabled(returningMove != nil)
                .accessibilityIdentifier("temporary-move-location")
            TextField("Optional note", text: $note, axis: .vertical)
                .disabled(returningMove != nil)
                .accessibilityIdentifier("temporary-move-note")
        }
    }

    @ViewBuilder
    private var connectorSection: some View {
        if selectedEquipment != nil {
            Section("2 · Temporary Connectors") {
                if homeInputs.isEmpty && homeOutputs.isEmpty {
                    Label("This equipment has no Home connections.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                ForEach(Array(homeInputs.enumerated()), id: \.element.id) { index, connection in
                    connectorRow(
                        label: equipmentOutputName(connection.outputPort),
                        homeConnector: connection.connector,
                        direction: "WING input",
                        range: StudioHomeConnections.inputRange,
                        binding: connectorBinding(index, values: $inputConnectors),
                        identifier: "temporary-move-input-\(index)"
                    )
                }
                ForEach(Array(homeOutputs.enumerated()), id: \.element.id) { index, connection in
                    connectorRow(
                        label: equipmentInputName(connection.inputPort),
                        homeConnector: connection.connector,
                        direction: "WING output",
                        range: StudioHomeConnections.outputRange,
                        binding: connectorBinding(index, values: $outputConnectors),
                        identifier: "temporary-move-output-\(index)"
                    )
                }
                if returningMove == nil {
                    Button("Use Compatible Free Ports") { loadSuggestion() }
                        .accessibilityIdentifier("temporary-move-use-suggestion")
                }
                if let conflict = draftError {
                    Label(conflict, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Connector conflict: \(conflict)")
                }
            }
        }
    }

    private var cableSection: some View {
        Section {
            if let move = resolvedMove {
                ForEach(cableChecklist(move), id: \.self) { item in
                    Label(item, systemImage: "cable.connector")
                }
            } else {
                Text("Choose equipment and conflict-free connectors to build the checklist.")
                    .foregroundStyle(.secondary)
            }
            Toggle(returningMove == nil ? "I've moved the cables" : "I've returned the cables Home",
                   isOn: $cablesConfirmed)
                .fontWeight(.semibold)
                .accessibilityIdentifier(
                    returningMove == nil
                        ? "temporary-move-cables-confirmed"
                        : "temporary-move-return-cables-confirmed"
                )
                .accessibilityHint("Required before routing can be applied")
        } header: {
            Text("3 · Cable Checklist")
        } footer: {
            Text("FluxKlang never infers a physical cable move from planning.")
        }
    }

    private var routingSection: some View {
        Section {
            if let preview {
                Label(preview.impact.summary, systemImage: "arrow.triangle.branch")
                if preview.hasErrors {
                    Label("The current Studio patch has errors and cannot be applied.", systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
            } else {
                Text("A routing preview appears after the connector plan is valid.")
                    .foregroundStyle(.secondary)
            }
            Button(actionTitle) { applyRouting() }
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
                .accessibilityIdentifier(
                    returningMove == nil
                        ? "temporary-move-apply-routing"
                        : "temporary-move-return-apply-routing"
                )
                .accessibilityLabel(actionTitle)
                .accessibilityHint("Explicitly writes the previewed routing, then checks confirmed console replies")
        } header: {
            Text("4 · Preview and Apply")
        } footer: {
            Text("""
            Verification re-queries affected output and channel-source nodes. If the current patch does not use this \
            equipment, the move stays tracked but can only be partially verified.
            """)
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let result {
            Section("Verification") {
                Label(result.state.label, systemImage: verificationImage(result.state))
                    .foregroundStyle(result.state == .verified ? .green : .orange)
                    .accessibilityIdentifier("temporary-move-verification-result")
                    .accessibilityLabel("Routing verification").accessibilityValue(result.state.label)
                Text(result.details)
                if returningMove != nil, result.state != .verified {
                    Text("Home routing is effective, but console verification is not yet complete.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var movableEquipment: [Equipment] {
        equipment.filter { item in
            let hasHome = home.inputs.contains { $0.equipmentID == item.id }
                || home.outputs.contains { $0.equipmentID == item.id }
            return hasHome && appModel.studioConnections.connections.move(for: item.id) == nil
        }
    }

    private var resolvedMove: TemporaryDeviceMove? {
        if let returningMove { return returningMove }
        let move = try? draftMove()
        return cablesConfirmed ? move?.preparingApply() : move
    }

    private var draftError: String? {
        if let returningMove {
            return returnPairingError(returningMove)
        }
        guard equipmentID != nil else { return nil }
        do {
            _ = try draftMove()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var preview: (impact: TemporaryMoveRoutingImpact, hasErrors: Bool)? {
        guard let move = resolvedMove else { return nil }
        return appModel.temporaryMoveImpact(applying: move, returningHome: returningMove != nil)
    }

    private var canApply: Bool {
        cablesConfirmed && !isApplying && draftError == nil && preview?.hasErrors == false
    }

    private var actionTitle: String {
        if isApplying { return "Checking Routing…" }
        return returningMove == nil ? "Apply Routing" : "Apply Home Routing"
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    // The row describes both physical sides plus its safety-test identifier.
    // swiftlint:disable:next function_parameter_count
    private func connectorRow(
        label: String,
        homeConnector: Int,
        direction: String,
        range: ClosedRange<Int>,
        binding: Binding<Int>,
        identifier: String
    ) -> some View {
        LabeledContent {
            if returningMove == nil {
                Picker(direction, selection: binding) {
                    ForEach(range, id: \.self) { connector in
                        Text(connector.formatted()).tag(connector)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier(identifier)
                .accessibilityLabel("\(label) temporary \(direction)")
            } else {
                Text("Home \(homeConnector)")
                    .monospacedDigit()
            }
        } label: {
            VStack(alignment: .leading) {
                Text(label)
                Text(returningMove == nil ? "Home \(homeConnector)" : "Home connection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func connectorBinding(_ index: Int, values: Binding<[Int]>) -> Binding<Int> {
        Binding(
            get: { values.wrappedValue.indices.contains(index) ? values.wrappedValue[index] : 1 },
            set: { newValue in
                while values.wrappedValue.count <= index {
                    values.wrappedValue.append(1)
                }
                values.wrappedValue[index] = newValue
                invalidateVerification()
            }
        )
    }

    private func draftMove() throws -> TemporaryDeviceMove {
        guard let equipmentID else { throw TemporaryMoveConflict.missingEquipment }
        return try TemporaryMoveAllocator.makeMove(
            equipmentID: equipmentID,
            inputConnectors: inputConnectors,
            outputConnectors: outputConnectors,
            location: location,
            note: note,
            home: home,
            equipment: equipment,
            existingMoves: appModel.studioConnections.connections.temporaryMoves
        )
    }

    private func loadSuggestionIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if returningMove == nil {
            loadSuggestion()
        }
    }

    private func loadSuggestion() {
        invalidateVerification()
        guard let equipmentID else {
            (inputConnectors, outputConnectors) = ([], [])
            return
        }
        do {
            let suggestion = try TemporaryMoveAllocator.suggestion(
                for: equipmentID,
                home: home,
                equipment: equipment,
                existingMoves: appModel.studioConnections.connections.temporaryMoves
            )
            (inputConnectors, outputConnectors) = (suggestion.inputConnectors, suggestion.outputConnectors)
        } catch {
            (inputConnectors, outputConnectors) = ([], [])
            errorMessage = error.localizedDescription
        }
    }

    private func invalidateVerification() { (cablesConfirmed, result, errorMessage) = (false, nil, nil) }

    private func cableChecklist(_ move: TemporaryDeviceMove) -> [String] {
        if returningMove != nil {
            return homeInputs.compactMap { homeConnection in
                guard let current = move.connections.inputs.first(where: {
                    $0.outputPort == homeConnection.outputPort
                })?.connector else { return nil }
                return """
                \(equipmentOutputName(homeConnection.outputPort)): WING input \(current) → \(homeConnection.connector)
                """
            } + homeOutputs.compactMap { homeConnection in
                guard let current = move.connections.outputs.first(where: {
                    $0.inputPort == homeConnection.inputPort
                })?.connector else { return nil }
                return """
                \(equipmentInputName(homeConnection.inputPort)): WING output \(current) → \(homeConnection.connector)
                """
            }
        }
        return homeInputs.enumerated().map { index, homeConnection in
            "\(equipmentOutputName(homeConnection.outputPort)): WING input \(homeConnection.connector) → "
                + "\(move.connections.inputs[index].connector)"
        } + homeOutputs.enumerated().map { index, homeConnection in
            "\(equipmentInputName(homeConnection.inputPort)): WING output \(homeConnection.connector) → "
                + "\(move.connections.outputs[index].connector)"
        }
    }

    private func returnPairingError(_ move: TemporaryDeviceMove) -> String? {
        let homeInputPorts = Set(homeInputs.map(\.outputPort))
        let moveInputPorts = Set(move.connections.inputs.map(\.outputPort))
        let homeOutputPorts = Set(homeOutputs.map(\.inputPort))
        let moveOutputPorts = Set(move.connections.outputs.map(\.inputPort))
        guard homeInputPorts == moveInputPorts, homeOutputPorts == moveOutputPorts else {
            return """
            Home wiring changed while this equipment was moved. Restore its original Home cable set first.
            """
        }
        return nil
    }

    private func equipmentOutputName(_ port: Int) -> String {
        guard let selectedEquipment, selectedEquipment.outputs.indices.contains(port) else {
            return "Equipment output \(port + 1)"
        }
        return selectedEquipment.outputs[port]
    }

    private func equipmentInputName(_ port: Int) -> String {
        guard let selectedEquipment, selectedEquipment.inputs.indices.contains(port) else {
            return "Equipment input \(port + 1)"
        }
        return selectedEquipment.inputs[port]
    }

    private func applyRouting() {
        guard let move = resolvedMove else { return }
        result = nil
        errorMessage = nil
        isApplying = true
        Task { @MainActor in
            defer { isApplying = false }
            do {
                if let returningMove {
                    result = try await appModel.returnTemporaryMoveHome(returningMove.id)
                } else {
                    result = try await appModel.applyTemporaryMove(move)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func verificationImage(_ state: TemporaryMoveVerificationState) -> String {
        switch state {
        case .verified: "checkmark.seal.fill"
        case .partiallyVerified: "checkmark.circle.badge.questionmark"
        case .failed: "xmark.octagon.fill"
        case .driftDetected: "arrow.trianglehead.2.clockwise.rotate.90"
        case .notVerified: "questionmark.circle"
        }
    }
}
