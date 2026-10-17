//
//  GlobalStudioConnectionsTests.swift
//  FluxKlangTests
//

import Foundation
import Testing
@testable import FluxKlang

struct GlobalStudioConnectionsTests {
    @Test func connectionIssueIdentifiersUseExplicitStableComponents() {
        let id = UUID(uuidString: "C024A205-2CB4-4D3C-A66A-A6AB87218D32")!

        #expect(
            StudioConnectionIssue(kind: .duplicateInputConnector(4), message: "Unsafe").id
                == "duplicate-input-connector-4"
        )
        #expect(
            StudioConnectionIssue(kind: .invalidOutputPort(id, 2), message: "Unsafe").id
                == "invalid-output-port-c024a205-2cb4-4d3c-a66a-a6ab87218d32-2"
        )
    }

    private final class MemoryCloudStore: CloudKeyValueStore, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Data] = [:]

        func data(forKey key: String) -> Data? { lock.withLock { storage[key] } }
        func setData(_ data: Data, forKey key: String) { lock.withLock { storage[key] = data } }
        @discardableResult func synchronize() -> Bool { true }
    }

    @Test func legacyEffectDecodesWithoutEquipmentLinkAndCanMigrateUniqueName() throws {
        let id = UUID()
        let json = """
        {
          "id":"\(id.uuidString)",
          "name":"  REVERB ",
          "isStereo":true,
          "sendOutputs":[7,8],
          "returnInputs":[9,10],
          "sourceInstruments":[]
        }
        """
        let decoded = try JSONDecoder().decode(Effect.self, from: Data(json.utf8))
        let equipment = Equipment(name: "Reverb", inputs: ["L", "R"], outputs: ["L", "R"], isStereo: true)

        #expect(decoded.equipmentID == nil)
        #expect(decoded.sendOutputs == [7, 8])
        #expect(decoded.returnInputs == [9, 10])
        #expect(decoded.migratingEquipmentLink(in: [equipment]).equipmentID == equipment.id)
        #expect(decoded.migratingEquipmentLink(in: [equipment, Equipment(name: "Reverb")]).equipmentID == nil)
    }

    @Test func globalConnectionsCodablePreservesHomeAndMigrationIssues() throws {
        let equipment = Equipment(name: "Synth", outputs: ["L", "R"], isStereo: true)
        let environmentID = UUID()
        let connections = GlobalStudioConnections(
            home: StudioHomeConnections(
                inputs: [StudioInputConnection(
                    connector: 4,
                    equipmentID: equipment.id,
                    outputPort: 0,
                    labelOverride: "Desk Left"
                )],
                outputs: []
            ),
            migrationIssues: [StudioConnectionMigrationIssue(
                environmentID: environmentID,
                deviceName: "Unknown",
                message: "Unresolved"
            )]
        )

        let decoded = try JSONDecoder().decode(
            GlobalStudioConnections.self,
            from: JSONEncoder().encode(connections)
        )

        #expect(decoded == connections)
        #expect(decoded.home.inputs[0].label(equipment: [equipment]) == "Desk Left")
    }

    @Test func duplicateConnectorsKeepDistinctStableIdentities() throws {
        let equipment = Equipment(name: "Synth", outputs: ["L", "R"], isStereo: true)
        let connections = [
            StudioInputConnection(connector: 1, equipmentID: equipment.id, outputPort: 0),
            StudioInputConnection(connector: 1, equipmentID: equipment.id, outputPort: 1)
        ]

        #expect(Set(connections.map(\.id)).count == 2)

        let decoded = try JSONDecoder().decode(
            [StudioInputConnection].self,
            from: JSONEncoder().encode(connections)
        )
        #expect(decoded.map(\.id) == connections.map(\.id))
    }

    @Test func assistantProjectionMatchesUniqueLiveLabelsToExistingEquipment() {
        let flux = Equipment(name: "SOMA Flux", outputs: ["Out L", "Out R"], isStereo: true)
        let astrolab = Equipment(name: "AstroLab 88", outputs: ["Out L", "Out R"], isStereo: true)
        let other = Equipment(name: "Other", outputs: ["Out"])
        let original = GlobalStudioConnections(home: StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 21, equipmentID: flux.id, outputPort: 0),
            StudioInputConnection(connector: 22, equipmentID: flux.id, outputPort: 1),
            StudioInputConnection(connector: 23, equipmentID: astrolab.id, outputPort: 0),
            StudioInputConnection(connector: 24, equipmentID: astrolab.id, outputPort: 1),
            StudioInputConnection(connector: 5, equipmentID: other.id, outputPort: 0)
        ]))

        let reconciled = original.reconcilingLiveInputNames(
            [19: "Flux", 20: "Flux", 21: "AstroLab 88", 22: "AstroLab 88"],
            equipment: [flux, astrolab, other]
        )

        #expect(reconciled.home.inputs.filter { $0.equipmentID == flux.id }.map(\.connector) == [19, 20])
        #expect(reconciled.home.inputs.filter { $0.equipmentID == astrolab.id }.map(\.connector) == [21, 22])
        #expect(reconciled.home.inputs.contains { $0.equipmentID == other.id && $0.connector == 5 })
        #expect(original.home.inputs.filter { $0.equipmentID == flux.id }.map(\.connector) == [21, 22])
    }

    @Test func migrationPrefersMeaningfulActiveSetupAndKeepsUnresolvedEntries() {
        let synth = Equipment(name: "Synth", outputs: ["L", "R"], isStereo: true)
        let inactive = RoutingEnvironment(
            name: "Inactive",
            studioSetup: StudioSetup(devices: [
                StudioDeviceProfile(
                    device: .equipment(synth.id),
                    name: synth.name,
                    role: .instrument,
                    patches: [StudioPortPatch(
                        device: .equipment(synth.id),
                        side: .output,
                        port: 0,
                        connector: .wingInput(WingSource(group: .local, index: 3))
                    )]
                )
            ])
        )
        let unknownID = UUID()
        let active = RoutingEnvironment(
            name: "Active",
            studioSetup: StudioSetup(devices: [
                StudioDeviceProfile(
                    device: .equipment(synth.id),
                    name: synth.name,
                    role: .instrument,
                    patches: [StudioPortPatch(
                        device: .equipment(synth.id),
                        side: .output,
                        port: 1,
                        connector: .wingInput(WingSource(group: .local, index: 14))
                    )]
                ),
                StudioDeviceProfile(
                    device: .equipment(unknownID),
                    name: "Missing Box",
                    role: .utility,
                    patches: [StudioPortPatch(
                        device: .equipment(unknownID),
                        side: .output,
                        port: 0,
                        connector: .wingInput(WingSource(group: .aes50A, index: 1))
                    )]
                )
            ])
        )

        let migrated = GlobalStudioConnections.migratingLegacy(
            environments: [inactive, active],
            activeID: active.id,
            equipment: [synth]
        )

        #expect(migrated.home.inputs.map(\.connector) == [14])
        #expect(migrated.migrationIssues.count == 1)
        #expect(migrated.migrationIssues[0].environmentID == active.id)
    }

    @Test func migrationUsesStableOrderWhenActiveSetupIsEmpty() {
        let synth = Equipment(name: "Synth")
        let active = RoutingEnvironment(name: "Active")
        let firstMeaningful = RoutingEnvironment(
            name: "First",
            studioSetup: StudioSetup(devices: [
                StudioDeviceProfile(
                    device: .equipment(synth.id),
                    name: synth.name,
                    role: .instrument,
                    patches: [StudioPortPatch(
                        device: .equipment(synth.id),
                        side: .output,
                        port: 0,
                        connector: .wingInput(WingSource(group: .local, index: 6))
                    )]
                )
            ])
        )
        let later = RoutingEnvironment(
            name: "Later",
            studioSetup: StudioSetup.inferredFromEquipment([synth])
        )

        let migrated = GlobalStudioConnections.migratingLegacy(
            environments: [active, firstMeaningful, later],
            activeID: active.id,
            equipment: [synth]
        )

        #expect(migrated.home.inputs.map(\.connector) == [6])
    }

    @MainActor
    @Test func storeMirrorsCloudAndDoesNotRemigrateInitializedEmptyState() async throws {
        let cloud = MemoryCloudStore()
        let fileStore = JSONFileStore(cloud: cloud)
        let fileName = "studio-connections-\(UUID().uuidString).json"
        let synth = Equipment(name: "Synth")
        let legacy = RoutingEnvironment(
            name: "Legacy",
            studioSetup: StudioSetup.inferredFromEquipment([synth])
        )
        let first = StudioConnectionsStore(fileStore: fileStore, fileName: fileName)
        await first.load(equipment: [synth], environments: [], activeID: nil)
        #expect(first.connections.home.inputs.isEmpty)
        #expect(first.connections.home.outputs.count == 4)
        try await first.setOutput(nil, connector: 1, equipment: [synth])

        let second = StudioConnectionsStore(fileStore: fileStore, fileName: fileName)
        await second.load(equipment: [synth], environments: [legacy], activeID: legacy.id)
        #expect(second.connections.home.inputs.isEmpty)
        #expect(second.connections.home.outputs.count == 3)

        let home = StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 17, equipmentID: synth.id, outputPort: 0)
        ])
        try await second.replaceHome(home, equipment: [synth])
        let cloudKey = "store." + fileName.replacingOccurrences(of: ".", with: "_")
        #expect(cloud.data(forKey: cloudKey) != nil)

        let cloudHome = StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 19, equipmentID: synth.id, outputPort: 0)
        ])
        cloud.setData(
            try JSONEncoder().encode(StudioConnectionsStore.Persisted(
                connections: GlobalStudioConnections(home: cloudHome),
                initialized: true,
                confirmedOutputDefaultsVersion: 1
            )),
            forKey: cloudKey
        )
        let third = StudioConnectionsStore(fileStore: fileStore, fileName: fileName)
        await third.load(equipment: [synth], environments: [], activeID: nil)
        #expect(third.connections.home == cloudHome)
    }

    @Test func validatorDetectsDuplicateConflictRangeAndInvalidPorts() {
        let synth = Equipment(name: "Synth", inputs: ["In"], outputs: ["Out"], isStereo: false)
        let resolver = StudioPhysicalResolver(
            connections: StudioHomeConnections(
                inputs: [
                    StudioInputConnection(connector: 1, equipmentID: synth.id, outputPort: 0),
                    StudioInputConnection(connector: 1, equipmentID: synth.id, outputPort: 0),
                    StudioInputConnection(connector: 25, equipmentID: synth.id, outputPort: 4)
                ],
                outputs: [
                    StudioOutputConnection(connector: 9, equipmentID: synth.id, inputPort: 3)
                ]
            ),
            equipment: [synth]
        )
        let kinds = Set(resolver.structuralIssues().map(\.kind))

        #expect(kinds.contains(.duplicateInputConnector(1)))
        #expect(kinds.contains(.inputConnectorOutOfRange(25)))
        #expect(kinds.contains(.outputConnectorOutOfRange(9)))
        #expect(kinds.contains(.conflictingOutputPort(synth.id, 0)))
        #expect(kinds.contains(.invalidOutputPort(synth.id, 4)))
        #expect(kinds.contains(.invalidInputPort(synth.id, 3)))
    }

    @Test func homeEditingRejectsExclusivePortConflictsAndSupportsClearing() throws {
        let synth = Equipment(name: "Synth", inputs: ["In"], outputs: ["Out"])
        var home = StudioHomeConnections()

        try home.setInput(
            StudioInputConnection(connector: 99, equipmentID: synth.id, outputPort: 0),
            connector: 1,
            equipment: [synth]
        )
        #expect(home.inputs.map(\.connector) == [1])
        #expect(throws: StudioConnectionAssignmentError.equipmentOutputInUse("Synth", "Out", 1)) {
            try home.setInput(
                StudioInputConnection(connector: 2, equipmentID: synth.id, outputPort: 0),
                connector: 2,
                equipment: [synth]
            )
        }
        try home.setOutput(
            StudioOutputConnection(connector: 1, equipmentID: synth.id, inputPort: 0),
            connector: 1,
            equipment: [synth]
        )
        #expect(throws: StudioConnectionAssignmentError.equipmentInputInUse(
            "Synth",
            "In",
            WingOutputConnector(index: 1)
        )) {
            try home.setOutput(
                StudioOutputConnection(connector: 2, equipmentID: synth.id, inputPort: 0),
                connector: 2,
                equipment: [synth]
            )
        }
        try home.setOutput(
            StudioOutputConnection(bank: .aes50A, connector: 3, destinationName: "Vocal Corner"),
            connector: 3,
            bank: .aes50A,
            equipment: [synth]
        )
        #expect(
            home.outputDisplayName(3, bank: .aes50A, equipment: [synth])
                == "AES50-A 3 · Vocal Corner"
        )

        try home.setInput(nil, connector: 1, equipment: [synth])
        try home.setOutput(nil, connector: 1, equipment: [synth])
        try home.setOutput(nil, connector: 3, bank: .aes50A, equipment: [synth])
        #expect(home.isEmpty)
    }

    @Test func connectionDisplayNamesAlwaysIncludeConnectorNumbers() {
        let synth = Equipment(name: "Synth", inputs: ["Return"], outputs: ["Main"])
        let home = StudioHomeConnections(
            inputs: [StudioInputConnection(
                connector: 3,
                equipmentID: synth.id,
                outputPort: 0,
                labelOverride: "  Lead  "
            )],
            outputs: [StudioOutputConnection(connector: 4, equipmentID: synth.id, inputPort: 0)]
        )

        #expect(home.inputDisplayName(3, equipment: [synth]) == "Input 3 · Lead")
        #expect(home.inputDisplayName(7, equipment: [synth], liveScribble: "Mic") == "Input 7 · Mic")
        #expect(home.outputDisplayName(4, equipment: [synth]) == "LCL 4 · Synth · Return")
        #expect(home.outputDisplayName(8, equipment: [synth]) == "LCL 8")
    }

    @Test func outputConnectionsDecodeLegacyLocalBankAndPreserveAES50Bank() throws {
        let equipmentID = UUID()
        let legacy = """
        {
          "id":"\(UUID().uuidString)",
          "connector":3,
          "equipmentID":"\(equipmentID.uuidString)",
          "inputPort":0
        }
        """
        let decodedLegacy = try JSONDecoder().decode(
            StudioOutputConnection.self,
            from: Data(legacy.utf8)
        )
        #expect(decodedLegacy.bank == .local)
        #expect(decodedLegacy.outputConnector == WingOutputConnector(index: 3))

        let aes = StudioOutputConnection(
            bank: .aes50A,
            connector: 7,
            equipmentID: equipmentID,
            inputPort: 1
        )
        let decodedAES = try JSONDecoder().decode(
            StudioOutputConnection.self,
            from: JSONEncoder().encode(aes)
        )
        #expect(decodedAES == aes)
        #expect(WingOutputSource(group: .bus, index: 4).settings(forOutput: aes.outputConnector).map(\.address) == [
            "/io/out/A/7/grp",
            "/io/out/A/7/in"
        ])
    }

    @Test func confirmedOutputDefaultsMatchTheRecordedStudioMap() throws {
        let defaults = try #require(StudioOutputDefaults.bundled())
        var home = StudioHomeConnections()
        home.applyConfirmedOutputDefaults(defaults, equipment: Equipment.seededLibrary)

        #expect(home.outputs.count == 16)
        #expect(home.outputDisplayName(1, equipment: Equipment.seededLibrary) == "LCL 1 · Desk Speakers L")
        #expect(home.outputDisplayName(8, equipment: Equipment.seededLibrary) == "LCL 8 · Main Speakers R")
        #expect(
            home.outputDisplayName(1, bank: .aes50A, equipment: Equipment.seededLibrary)
                == "AES50-A 1 · Torso S-4 · In L"
        )
        #expect(
            home.outputDisplayName(8, bank: .aes50A, equipment: Equipment.seededLibrary)
                == "AES50-A 8 · OP-XY · In R"
        )
    }

    @Test func compilerBlocksSettingsForMissingStereoLegAndUnlinkedEffect() {
        let synth = Equipment(name: "Synth", outputs: ["L", "R"], isStereo: true)
        let effect = Effect(name: "Effect", isStereo: true)
        let instrumentNode = StudioNode(kind: .instrument(synth.id), title: synth.name)
        let effectNode = StudioNode(kind: .effect(effect.id), title: effect.name)
        let endpoint = StudioEndpoint(name: "Wet", destination: .finalMix)
        let endpointNode = StudioNode(kind: .endpoint(endpoint.id), title: endpoint.name)
        var graph = StudioGraph(nodes: [instrumentNode, effectNode, endpointNode])
        graph.connect(
            from: StudioPortRef(nodeID: instrumentNode.id, side: .output, port: 0),
            to: StudioPortRef(nodeID: effectNode.id, side: .input, port: 0)
        )
        graph.connect(
            from: StudioPortRef(nodeID: effectNode.id, side: .output, port: 0),
            to: StudioPortRef(nodeID: endpointNode.id, side: .input, port: 0)
        )

        let compiled = StudioSignalCompiler.compile(StudioCompilationInput(
            graph: graph,
            endpoints: [endpoint],
            effects: [effect],
            connections: GlobalStudioConnections(home: StudioHomeConnections(inputs: [
                StudioInputConnection(connector: 3, equipmentID: synth.id, outputPort: 0)
            ])),
            equipment: [synth],
            speakers: []
        ))

        #expect(compiled.hasErrors)
        #expect(compiled.settings.isEmpty)
        #expect(compiled.issues.contains {
            if case .physicalConnection(.missingStereoInputLeg(synth.id)) = $0.kind { return true }
            return false
        })
        #expect(compiled.issues.contains {
            if case .physicalConnection(.unlinkedEffect(effect.id)) = $0.kind { return true }
            return false
        })
    }
}
