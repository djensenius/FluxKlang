//
//  EnvironmentDuplicationTests.swift
//  FluxKlangTests
//
//  Duplicating a legacy environment must give every environment-local object a
//  fresh identity, rewrite every reference to it, and keep shared equipment and
//  console identities intact.
//

import CoreGraphics
import Foundation
import Testing
@testable import FluxKlang

struct EnvironmentDuplicationTests {
    /// A legacy environment exercising every reference kind duplication touches.
    private struct Fixture {
        let synth = Equipment(name: "Synth")
        let reverbBox = Equipment(name: "Reverb Box")
        let environment: RoutingEnvironment

        init() {
            let reverb = Effect(name: "Hall", equipmentID: reverbBox.id, sourceInstruments: [synth.id])
            let delay = Effect(name: "Echo", sourceInstruments: [synth.id], destinationEffectID: reverb.id)
            let endpoint = StudioEndpoint(
                name: "Desk Speakers",
                destination: .custom,
                outputConnectors: [WingOutputConnector(index: 3)],
                placement: VoicePlacement(width: 0.4)
            )
            let binding = StudioLiveChannelBinding(
                observedSessionID: UUID(),
                members: [.init(channel: 7, label: "Vox", sourceGroup: nil, sourceIndex: nil, equipmentID: nil)]
            )
            let instrumentNode = StudioNode(kind: .instrument(synth.id), title: "Synth")
            let delayNode = StudioNode(kind: .effect(delay.id), title: "Echo")
            let reverbNode = StudioNode(kind: .effect(reverb.id), title: "Hall")
            let endpointNode = StudioNode(kind: .endpoint(endpoint.id), title: "Desk Speakers")
            let liveNode = StudioNode(kind: .liveChannel(binding), title: "Vox")
            var studioGraph = StudioGraph(nodes: [instrumentNode, delayNode, reverbNode, endpointNode, liveNode])
            studioGraph.connect(from: Self.out(instrumentNode.id), to: Self.into(delayNode.id))
            studioGraph.connect(from: Self.out(delayNode.id), to: Self.into(reverbNode.id))
            studioGraph.connect(from: Self.out(reverbNode.id), to: Self.into(endpointNode.id))

            let gearNode = ChainNode(kind: .equipment(synth.id), title: "Synth", position: .zero)
            let busNode = ChainNode(kind: .wingBus(2), title: "Bus 2", position: CGPoint(x: 10, y: 0))
            var graph = ChainGraph(nodes: [gearNode, busNode])
            graph.connect(
                from: ChainPortRef(nodeID: gearNode.id, side: .output, port: 0),
                to: ChainPortRef(nodeID: busNode.id, side: .input, port: 0)
            )

            let reverbDevice = StudioDeviceRef.effect(reverb.id)
            let setup = StudioSetup(devices: [
                StudioDeviceProfile(
                    device: reverbDevice,
                    name: "Legacy Hall Unit",
                    role: .outboardEffect,
                    patches: [StudioPortPatch(
                        device: reverbDevice,
                        side: .output,
                        port: 0,
                        connector: .wingInput(WingSource(group: .local, index: 11))
                    )]
                )
            ] + StudioSetup.inferredFromEquipment([synth]).devices)

            environment = RoutingEnvironment(
                name: "Song",
                effects: [reverb, delay],
                placements: [
                    EnvironmentVoice.sourceID(synth.id): VoicePlacement(width: 0.1),
                    EnvironmentVoice.returnID(reverb.id): VoicePlacement(width: 0.2)
                ],
                graph: graph,
                studioGraph: studioGraph,
                studioEndpoints: [endpoint],
                studioSetup: setup
            )
        }

        static func out(_ node: UUID) -> StudioPortRef { StudioPortRef(nodeID: node, side: .output, port: 0) }
        static func into(_ node: UUID) -> StudioPortRef { StudioPortRef(nodeID: node, side: .input, port: 0) }
    }

    /// Every environment-local identity of `environment`.
    private func localIDs(of environment: RoutingEnvironment) -> Set<UUID> {
        var ids: Set<UUID> = [environment.id]
        ids.formUnion(environment.effects.map(\.id))
        ids.formUnion(environment.studioEndpoints.map(\.id))
        ids.formUnion(environment.graph.nodes.map(\.id))
        ids.formUnion(environment.graph.edges.map(\.id))
        ids.formUnion(environment.studioGraph.nodes.map(\.id))
        ids.formUnion(environment.studioGraph.edges.map(\.id))
        ids.formUnion(environment.studioSetup.devices.map(\.id))
        ids.formUnion(environment.studioSetup.devices.flatMap(\.patches).map(\.id))
        return ids
    }

    /// Every dangling local reference in `environment`, described for diagnostics.
    private func danglingReferences(in environment: RoutingEnvironment) -> [String] {
        let effectIDs = Set(environment.effects.map(\.id))
        var dangling: [String] = []
        for effect in environment.effects {
            if let target = effect.destinationEffectID, !effectIDs.contains(target) { dangling.append("destination") }
        }
        for key in environment.placements.keys where key.hasPrefix(EnvironmentVoice.returnPrefix) {
            let id = UUID(uuidString: String(key.dropFirst(EnvironmentVoice.returnPrefix.count)))
            if id.map(effectIDs.contains) != true { dangling.append("placement \(key)") }
        }
        let devices = environment.studioSetup.devices.flatMap { [$0.device] + $0.patches.map(\.device) }
        for case .effect(let id) in devices where !effectIDs.contains(id) {
            dangling.append("setup effect device")
        }
        return dangling + danglingGraphReferences(in: environment)
    }

    private func danglingGraphReferences(in environment: RoutingEnvironment) -> [String] {
        let effectIDs = Set(environment.effects.map(\.id))
        let endpointIDs = Set(environment.studioEndpoints.map(\.id))
        let chainNodeIDs = Set(environment.graph.nodes.map(\.id))
        let studioNodeIDs = Set(environment.studioGraph.nodes.map(\.id))
        var dangling: [String] = []
        for edge in environment.graph.edges where !chainNodeIDs.isSuperset(of: [edge.from.nodeID, edge.to.nodeID]) {
            dangling.append("chain edge")
        }
        for edge in environment.studioGraph.edges
        where !studioNodeIDs.isSuperset(of: [edge.from.nodeID, edge.to.nodeID]) {
            dangling.append("studio edge")
        }
        for node in environment.studioGraph.nodes {
            switch node.kind {
            case .effect(let id) where !effectIDs.contains(id): dangling.append("studio effect node")
            case .endpoint(let id) where !endpointIDs.contains(id): dangling.append("studio endpoint node")
            default: break
            }
        }
        return dangling
    }

    // MARK: - Round trip

    @Test func duplicateRoundTripsWithoutDanglingOrOriginalReferences() throws {
        let original = Fixture().environment
        #expect(danglingReferences(in: original).isEmpty)

        let copy = original.duplicated(named: "Song Copy")
        let data = try JSONEncoder().encode(copy)
        let decoded = try JSONDecoder().decode(RoutingEnvironment.self, from: data)

        #expect(decoded == copy)
        #expect(decoded.name == "Song Copy")
        #expect(danglingReferences(in: decoded).isEmpty)
        #expect(localIDs(of: decoded).isDisjoint(with: localIDs(of: original)))
        // No serialized field anywhere in the copy mentions an original local ID.
        let json = try #require(String(bytes: data, encoding: .utf8))
        for id in localIDs(of: original) {
            #expect(!json.contains(id.uuidString), "copy still references original \(id)")
        }
    }

    @Test func duplicatePreservesStructureOfEveryReferenceKind() throws {
        let fixture = Fixture()
        let original = fixture.environment
        let copy = original.duplicated(named: "Song Copy")

        let reverb = copy.effects[0]
        let delay = copy.effects[1]
        #expect(delay.destinationEffectID == reverb.id)
        #expect(copy.placements[EnvironmentVoice.returnID(reverb.id)]?.width == 0.2)
        #expect(copy.placements[EnvironmentVoice.sourceID(fixture.synth.id)]?.width == 0.1)

        let studioKinds = copy.studioGraph.nodes.map(\.kind)
        #expect(studioKinds.contains(.effect(reverb.id)))
        #expect(studioKinds.contains(.effect(delay.id)))
        #expect(studioKinds.contains(.endpoint(try #require(copy.studioEndpoints.first).id)))
        #expect(copy.studioGraph.edges.count == original.studioGraph.edges.count)
        let node = { (kind: StudioNodeKind) in copy.studioGraph.nodes.first { $0.kind == kind }?.id }
        let wired = Set(copy.studioGraph.edges.map { [$0.from.nodeID, $0.to.nodeID] })
        #expect(wired.contains([node(.effect(delay.id)), node(.effect(reverb.id))].compactMap { $0 }))

        let plan = StudioRoutingPlanner.plan(for: copy.studioGraph, endpoints: copy.studioEndpoints)
        #expect(!plan.hasErrors)
        #expect(plan.endpointPlans.count == 1)

        #expect(copy.graph.nodes.map(\.kind) == original.graph.nodes.map(\.kind))
        #expect(copy.graph.edges.count == 1)
        #expect(copy.studioSetup.devices[0].device == .effect(reverb.id))
        #expect(copy.studioSetup.devices[0].patches[0].device == .effect(reverb.id))
    }

    // MARK: - Shared identity

    @Test func duplicatePreservesSharedEquipmentAndConsoleIdentity() throws {
        let fixture = Fixture()
        let original = fixture.environment
        let copy = original.duplicated(named: "Song Copy")

        #expect(copy.effects.map(\.equipmentID) == original.effects.map(\.equipmentID))
        #expect(copy.effects.map(\.sourceInstruments) == original.effects.map(\.sourceInstruments))
        #expect(copy.studioGraph.nodes.contains { $0.kind == .instrument(fixture.synth.id) })
        #expect(copy.graph.nodes.contains { $0.kind == .equipment(fixture.synth.id) })
        #expect(copy.studioSetup.devices.contains { $0.device == .equipment(fixture.synth.id) })
        let liveKinds = { (environment: RoutingEnvironment) in
            environment.studioGraph.nodes.filter { if case .liveChannel = $0.kind { true } else { false } }.map(\.kind)
        }
        #expect(liveKinds(copy) == liveKinds(original))
        let endpoint = try #require(copy.studioEndpoints.first)
        #expect(endpoint.outputConnectors == original.studioEndpoints.first?.outputConnectors)
        #expect(endpoint.placement?.width == 0.4)
    }

    @Test func duplicateLegacySetupStillMigratesToTheLinkedEquipment() {
        let fixture = Fixture()
        let copy = fixture.environment.duplicated(named: "Song Copy")
        let migrated = GlobalStudioConnections.migratingLegacy(
            environments: [copy],
            activeID: copy.id,
            equipment: [fixture.synth, fixture.reverbBox]
        )
        // The legacy profile's name matches no Equipment, so only the remapped
        // effect link can resolve it to the shared reverb unit.
        #expect(migrated.migrationIssues.isEmpty)
        #expect(migrated.home.inputs.contains { $0.connector == 11 && $0.equipmentID == fixture.reverbBox.id })
    }

    // MARK: - Already-dangling references

    @Test func alreadyDanglingReferencesFollowTheDocumentedPolicy() {
        let tank = Equipment(name: "Spring Tank")
        let missingEffect = UUID()
        let missingEndpoint = UUID()
        let missingNode = UUID()
        let effectNode = StudioNode(kind: .effect(missingEffect), title: "Gone effect")
        let endpointNode = StudioNode(kind: .endpoint(missingEndpoint), title: "Gone endpoint")
        let chainNode = ChainNode(kind: .wingBus(1), title: "Bus 1", position: .zero)
        let device = StudioDeviceRef.effect(tank.id)
        let original = RoutingEnvironment(
            name: "Dangling",
            effects: [Effect(name: "Orphan", destinationEffectID: missingEffect)],
            graph: ChainGraph(nodes: [chainNode], edges: [ChainEdge(
                from: ChainPortRef(nodeID: chainNode.id, side: .output, port: 0),
                to: ChainPortRef(nodeID: missingNode, side: .input, port: 0)
            )]),
            studioGraph: StudioGraph(
                nodes: [effectNode, endpointNode],
                edges: [StudioEdge(from: Fixture.out(effectNode.id), to: Fixture.into(missingNode))]
            ),
            studioSetup: StudioSetup(devices: [StudioDeviceProfile(
                device: device,
                name: "Unmatched Profile",
                role: .outboardEffect,
                patches: [StudioPortPatch(
                    device: device, side: .output, port: 0,
                    connector: .wingInput(WingSource(group: .local, index: 5))
                )]
            )])
        )

        let copy = original.duplicated(named: "Dangling Copy")

        // A dangling serial-chain destination falls back to the main.
        #expect(copy.effects[0].destinationEffectID == nil)
        // Dangling studio node references are carried over verbatim on fresh nodes.
        #expect(copy.studioGraph.nodes.map(\.kind) == [.effect(missingEffect), .endpoint(missingEndpoint)])
        #expect(copy.studioGraph.nodes[0].id != effectNode.id)
        // Wires keep their remapped local end and the missing end verbatim.
        #expect(copy.studioGraph.edges.map(\.from.nodeID) == [copy.studioGraph.nodes[0].id])
        #expect(copy.studioGraph.edges.map(\.to.nodeID) == [missingNode])
        #expect(copy.graph.edges.map(\.from.nodeID) == [copy.graph.nodes[0].id])
        #expect(copy.graph.edges.map(\.to.nodeID) == [missingNode])
        // A setup `.effect` that is really an equipment ID is copied verbatim and
        // still resolves through the migration's equipment fallback.
        #expect(copy.studioSetup.devices[0].device == device)
        #expect(copy.studioSetup.devices[0].patches[0].device == device)
        let migrated = GlobalStudioConnections.migratingLegacy(
            environments: [copy], activeID: copy.id, equipment: [tank]
        )
        #expect(migrated.migrationIssues.isEmpty)
        #expect(migrated.home.inputs.contains { $0.connector == 5 && $0.equipmentID == tank.id })
    }

    /// Legacy effects may share their ID with an Equipment item while still
    /// unlinked. The real flow is the second half: `AppModel.loadStores` runs
    /// `migrateEffectEquipmentLinks` (→ `migratingEquipmentLink`) right after
    /// loading environments and before any UI can duplicate, so the copy keeps
    /// the explicit link and resolves. The first half pins the accepted
    /// regression for the unreachable order (duplicate before linking): the
    /// copy's fresh effect ID no longer equals the equipment ID, so migration
    /// reports an issue rather than guessing.
    @Test func unlinkedEffectSharingAnEquipmentIDResolvesOnceLinked() {
        let tank = Equipment(name: "Spring Tank")
        let device = StudioDeviceRef.effect(tank.id)
        let legacy = RoutingEnvironment(
            name: "Legacy",
            effects: [Effect(id: tank.id, name: "Wet")],
            studioSetup: StudioSetup(devices: [StudioDeviceProfile(
                device: device,
                name: "Old Profile",
                role: .outboardEffect,
                patches: [StudioPortPatch(
                    device: device, side: .output, port: 0,
                    connector: .wingInput(WingSource(group: .local, index: 9))
                )]
            )])
        )
        func migrate(_ environment: RoutingEnvironment) -> GlobalStudioConnections {
            .migratingLegacy(environments: [environment], activeID: environment.id, equipment: [tank])
        }

        let early = migrate(legacy.duplicated(named: "Early Copy"))
        #expect(early.migrationIssues.count == 1)
        #expect(early.home.inputs.isEmpty)

        var linked = legacy
        linked.effects = linked.effects.map { $0.migratingEquipmentLink(in: [tank]) }
        #expect(linked.effects[0].equipmentID == tank.id)
        let copy = linked.duplicated(named: "Copy")
        #expect(copy.effects[0].id != tank.id)
        let migrated = migrate(copy)
        #expect(migrated.migrationIssues.isEmpty)
        #expect(migrated.home.inputs.contains { $0.connector == 9 && $0.equipmentID == tank.id })
    }

    // MARK: - Independence

    @MainActor
    @Test func storeEditsToCopyAndOriginalStayIndependent() throws {
        // Test hosts give EnvironmentStore an isolated temporary JSONFileStore.
        let store = EnvironmentStore()
        let originalID = store.addEnvironment(named: "Song")
        let reverb = Effect(name: "Hall")
        store.add(reverb)
        store.add(Effect(name: "Echo", destinationEffectID: reverb.id))
        let endpoint = StudioEndpoint(name: "Desk", destination: .custom)
        store.addStudioEndpointNode(endpoint, position: .zero)
        let effectNode = StudioNode(kind: .effect(reverb.id), title: "Hall")
        store.addStudioNode(effectNode)
        let endpointNode = try #require(store.activeStudioGraph.nodes.first { $0.kind == .endpoint(endpoint.id) })
        store.connectStudio(from: Fixture.out(effectNode.id), to: Fixture.into(endpointNode.id))
        let original = try #require(store.active)
        #expect(original.studioGraph.edges.count == 1)

        let copyID = try #require(store.duplicateActive())
        #expect(store.activeID == copyID)
        let copy = try #require(store.active)
        let copyEffectNode = try #require(copy.studioGraph.nodes.first { $0.kind == .effect(copy.effects[0].id) })
        let copyEndpointNode = try #require(copy.studioGraph.nodes.first {
            if case .endpoint = $0.kind { true } else { false }
        })

        // ID-addressed edits against the copy never resolve in the original.
        var probe = original.studioGraph
        probe.removeNode(copyEffectNode.id)
        probe.moveNode(copyEffectNode.id, to: CGPoint(x: 99, y: 99))
        #expect(probe == original.studioGraph)

        // Edit the active copy through the store, including an edit addressed
        // by an original effect ID, which must not resolve in the copy.
        var renamed = copy.effects[0]
        renamed.name = "Plate"
        store.update(renamed)
        store.update(Effect(id: reverb.id, name: "Ghost"))
        store.moveStudioNode(copyEffectNode.id, to: CGPoint(x: 50, y: 50))
        store.removeStudioNode(copyEndpointNode.id)
        #expect(store.activeStudioEndpoints.isEmpty)

        store.setActive(originalID)
        #expect(store.active == original)

        // Edit the original; the copy keeps its own state.
        store.removeStudioNode(effectNode.id)
        store.setActive(copyID)
        let editedCopy = try #require(store.active)
        #expect(editedCopy.effects.map(\.name) == ["Plate", "Echo"])
        #expect(editedCopy.effects[1].destinationEffectID == editedCopy.effects[0].id)
        #expect(editedCopy.studioGraph.node(copyEffectNode.id)?.position == CGPoint(x: 50, y: 50))
        #expect(danglingReferences(in: editedCopy).isEmpty)
    }

    @Test func duplicatingTwiceYieldsDistinctLocalIdentities() {
        let original = Fixture().environment
        let first = original.duplicated(named: "A")
        let second = original.duplicated(named: "B")
        #expect(localIDs(of: first).isDisjoint(with: localIDs(of: second)))
    }
}
