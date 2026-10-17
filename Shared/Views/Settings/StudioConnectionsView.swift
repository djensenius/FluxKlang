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

            Section("WING Local Outputs") {
                ForEach(StudioHomeConnections.outputRange, id: \.self) { connector in
                    NavigationLink {
                        StudioConnectorEditor(direction: .output, connector: connector, outputBank: .local)
                    } label: {
                        connectorRow(
                            direction: .output,
                            connector: connector,
                            outputBank: .local,
                            issues: issues
                        )
                    }
                    .accessibilityIdentifier("studio-connection-output-\(connector)")
                    .accessibilityHint("Opens the Home assignment editor for WING output \(connector)")
                }
            }

            ForEach(
                [WingOutputConnectorBank.aes50A, .aes50B],
                id: \.self
            ) { bank in
                Section("\(bank.label) S32 Outputs") {
                    ForEach(bank.connectorRange, id: \.self) { connector in
                        NavigationLink {
                            StudioConnectorEditor(
                                direction: .output,
                                connector: connector,
                                outputBank: bank
                            )
                        } label: {
                            connectorRow(
                                direction: .output,
                                connector: connector,
                                outputBank: bank,
                                issues: issues
                            )
                        }
                        .accessibilityIdentifier(
                            "studio-connection-output-\(bank.rawValue.lowercased())-\(connector)"
                        )
                        .accessibilityHint(
                            "Opens the Home assignment editor for \(bank.label) output \(connector)"
                        )
                    }
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
        outputBank: WingOutputConnectorBank = .local,
        issues: [StudioConnectionIssue]
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(direction: direction, connector: connector, outputBank: outputBank))
                Text(
                    isAssigned(direction: direction, connector: connector, outputBank: outputBank)
                        ? "Home assignment"
                        : "Not assigned"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasIssue(
                direction: direction,
                connector: connector,
                outputBank: outputBank,
                issues: issues
            ) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Connection problem")
            }
        }
    }

    private func displayName(
        direction: StudioConnectorDirection,
        connector: Int,
        outputBank: WingOutputConnectorBank
    ) -> String {
        switch direction {
        case .input:
            return home.inputDisplayName(
                connector,
                equipment: appModel.equipment.items,
                liveScribble: appModel.wing.inputName(connector)
            )
        case .output:
            return home.outputDisplayName(
                connector,
                bank: outputBank,
                equipment: appModel.equipment.items
            )
        }
    }

    private func isAssigned(
        direction: StudioConnectorDirection,
        connector: Int,
        outputBank: WingOutputConnectorBank
    ) -> Bool {
        switch direction {
        case .input: home.input(connector) != nil
        case .output: home.output(connector, bank: outputBank) != nil
        }
    }

    private func hasIssue(
        direction: StudioConnectorDirection,
        connector: Int,
        outputBank: WingOutputConnectorBank,
        issues: [StudioConnectionIssue]
    ) -> Bool {
        switch direction {
        case .input:
            issues.contains { inputIssueMatches($0.kind, connector: connector) }
        case .output:
            issues.contains { outputIssueMatches($0.kind, connector: connector, bank: outputBank) }
        }
    }

    private func inputIssueMatches(_ issue: StudioConnectionIssue.Kind, connector: Int) -> Bool {
        switch issue {
        case .duplicateInputConnector(let value), .inputConnectorOutOfRange(let value):
            value == connector
        case .missingEquipment(let equipmentID):
            home.input(connector)?.equipmentID == equipmentID
        case .invalidOutputPort(let equipmentID, let port),
             .conflictingOutputPort(let equipmentID, let port):
            home.input(connector).map {
                $0.equipmentID == equipmentID && $0.outputPort == port
            } ?? false
        default:
            false
        }
    }

    private func outputIssueMatches(
        _ issue: StudioConnectionIssue.Kind,
        connector: Int,
        bank: WingOutputConnectorBank
    ) -> Bool {
        switch issue {
        case .duplicateOutputConnector(let value), .outputConnectorOutOfRange(let value):
            bank == .local && value == connector
        case .duplicateBankOutputConnector(let issueBank, let value),
             .bankOutputConnectorOutOfRange(let issueBank, let value):
            bank == issueBank && value == connector
        case .missingEquipment(let equipmentID):
            home.output(connector, bank: bank)?.equipmentID == equipmentID
        case .invalidInputPort(let equipmentID, let port),
             .conflictingInputPort(let equipmentID, let port):
            home.output(connector, bank: bank).map {
                $0.equipmentID == equipmentID && $0.inputPort == port
            } ?? false
        case .invalidOutputDestination(let issueBank, let value):
            bank == issueBank && connector == value
        default:
            false
        }
    }
}

#Preview {
    NavigationStack { StudioConnectionsView() }
        .environment(AppModel.preview())
}
