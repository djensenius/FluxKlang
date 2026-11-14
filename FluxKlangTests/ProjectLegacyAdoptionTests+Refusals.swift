import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Legacy project adoption refusals", .productionAccessAudit)
struct ProjectLegacyAdoptionRefusalTests {
    private typealias Fixture = LegacyAdoptionP5Fixture
    private static let empty = #"{"nodes":[],"edges":[]}"#

    @Test func oversizedGraphIsRefusedBeforeDecodingAtNPlusOne() throws {
        let policy = try Fixture.policy(entryBytes: 2048)
        _ = try Fixture.adopt(graph: Fixture.padded(Self.empty, to: 2048), endpoints: nil, policy: policy)
        #expect(try Fixture.refusal(graph: Fixture.padded(Self.empty, to: 2049), endpoints: nil, policy: policy)
            == .oversizedInput(.graph))
        // Undecodable and versioned bytes over the bound still report size: nothing was decoded or assembled.
        let garbage = Data(repeating: 0x7B, count: 2049)
        #expect(try Fixture.refusal(graph: garbage, endpoints: nil, policy: policy) == .oversizedInput(.graph))
        let versioned = Fixture.padded(#"{"version":1}"#, to: 2049)
        #expect(try Fixture.refusal(graph: versioned, endpoints: nil, policy: policy) == .oversizedInput(.graph))
    }

    @Test func oversizedEndpointsAreRefusedAtNPlusOne() throws {
        let policy = try Fixture.policy(entryBytes: 2048)
        let graph = Data(Self.empty.utf8)
        _ = try Fixture.adopt(graph: graph, endpoints: Fixture.padded("[]", to: 2048), policy: policy)
        #expect(try Fixture.refusal(graph: graph, endpoints: Fixture.padded("[]", to: 2049), policy: policy)
            == .oversizedInput(.endpoints))
        #expect(try Fixture.refusal(graph: graph, endpoints: Data(repeating: 0x5B, count: 2049), policy: policy)
            == .oversizedInput(.endpoints))
    }

    @Test func combinedInputOverTheTotalIsRefusedAtNPlusOne() throws {
        let policy = try Fixture.policy(entryBytes: 4096, totalBytes: 6000)
        let graph = Fixture.padded(Self.empty, to: 3000)
        // Exactly the total passes the input bound and only then fails in assembly (documents also count).
        #expect(try Fixture.refusal(graph: graph, endpoints: Fixture.padded("[]", to: 3000), policy: policy)
            == .assembly(.package(.totalBytesExceeded)))
        #expect(try Fixture.refusal(graph: graph, endpoints: Fixture.padded("[]", to: 3001), policy: policy)
            == .oversizedInput(.combined))
    }

    @Test func documentCeilingBoundsInputAboveLargerPackageLimits() throws {
        let ceiling = ProjectGraphLimits.documentBytes
        let policy = try Fixture.policy(entryBytes: ceiling + 64, totalBytes: 4 * ceiling)
        let result = try Fixture.adopt(graph: Fixture.padded(Self.empty, to: ceiling), endpoints: nil, policy: policy)
        #expect(Fixture.bytes(at: LegacyAdoption.originalGraphPath, in: result.contents)?.count == ceiling)
        #expect(try Fixture.refusal(graph: Fixture.padded(Self.empty, to: ceiling + 1), endpoints: nil, policy: policy)
            == .oversizedInput(.graph))
        #expect(try Fixture.refusal(endpoints: Fixture.padded("[]", to: ceiling + 1), policy: policy)
            == .oversizedInput(.endpoints))
    }

    @Test func malformedLegacyInputIsUndecodable() throws {
        #expect(try Fixture.refusal(graph: Data("not json".utf8)) == .undecodableInput)
        #expect(try Fixture.refusal(graph: Data([0xEF, 0xBB, 0xBF]) + Data(Self.empty.utf8)) == .undecodableInput)
        #expect(try Fixture.refusal(graph: Data(#"{"nodes":[]}"#.utf8), endpoints: nil) == .undecodableInput)
        #expect(try Fixture.refusal(endpoints: Data("[".utf8)) == .undecodableInput)
        #expect(try Fixture.refusal(endpoints: Data(#"[{"id":"x"}]"#.utf8)) == .undecodableInput)
    }

    @Test func adapterRefusalsAreTyped() throws {
        let duplicate = Data(#"[{"id":"\#(Fixture.mainsEndpoint)","destination":"a"},"#.utf8)
            + Data(#"{"id":"\#(Fixture.mainsEndpoint)","destination":"b"}]"#.utf8)
        #expect(try Fixture.refusal(endpoints: duplicate) == .duplicateEndpoint)
        let unknown = Fixture.graph(nodes: [Fixture.node(Fixture.synth, #"{"mixer":{"_0":"x"}}"#, "M")])
        #expect(try Fixture.refusal(graph: unknown, endpoints: nil) == .unsupportedLegacyKind)
        let count = ProjectGraphLimits.projectRecords + 1
        let many = (0..<count).map {
            #"{"id":"\#(String(format: "00000000-0000-0000-0000-%012d", $0))","destination":"x"}"#
        }
        let endpoints = Data("[\(many.joined(separator: ","))]".utf8)
        let policy = try Fixture.policy(entryBytes: 1 << 20, totalBytes: 1 << 22)
        #expect(try Fixture.refusal(endpoints: endpoints, policy: policy)
            == .legacyBounds(.exceeded(path: "legacy.endpoints", maximum: ProjectGraphLimits.projectRecords)))
    }

    @Test func assemblyRefusalsProduceNothing() throws {
        #expect(try Fixture.refusal(policy: Fixture.policy(entries: 3)) == .assembly(.package(.entryLimitExceeded)))
        // The original graph fits, but the adapter's graph document (which embeds it) does not.
        let policy = try Fixture.policy(entryBytes: Fixture.standardGraph.count)
        #expect(try Fixture.refusal(policy: policy) == .assembly(.package(.entryBytesExceeded)))
    }

    @Test func wronglyWiredRoleNodeIsRefused() throws {
        // A legacy edge into an instrument gives its role-input node an input port (checked first in
        // document order; the endpoint's output port is wrong too).
        let graph = Fixture.graph(
            nodes: [Fixture.node(Fixture.synth, Fixture.instrumentKind(Fixture.instrument), "Synth"),
                    Fixture.node(Fixture.mains, Fixture.endpointKind(Fixture.mainsEndpoint), "Mains")],
            edges: [Fixture.edge("66666666-6666-6666-6666-666666666661", from: Fixture.mains, 0, to: Fixture.synth, 0)]
        )
        #expect(try Fixture.refusal(graph: graph, endpoints: nil)
            == .roleShapeMismatch(Fixture.role("instrument", Fixture.instrument)))
        let outputs = Fixture.graph(
            nodes: [Fixture.node(Fixture.mains, Fixture.endpointKind(Fixture.mainsEndpoint), "Mains"),
                    Fixture.node(Fixture.room, Fixture.endpointKind(Fixture.roomEndpoint), "Room")],
            edges: [Fixture.edge("66666666-6666-6666-6666-666666666661", from: Fixture.mains, 0, to: Fixture.room, 0)]
        )
        #expect(try Fixture.refusal(graph: outputs, endpoints: nil)
            == .roleShapeMismatch(Fixture.role("endpoint", Fixture.mainsEndpoint)))
    }
    @Test func connectMenuWireIntoAnInstrumentIsRefused() throws {
        // `StudioConnectNodesMenu` wires the source's output port 0 to the destination's input port 0.
        // Contract v1 gives role inputs no input ports, so a legacy wire into an instrument is refused
        // (known limitation; needs a contract revision or user-guided repair).
        let effect = "77777777-7777-7777-7777-777777777777"
        let graph = Fixture.graph(
            nodes: [Fixture.node(effect, #"{"effect":{"_0":"88888888-8888-8888-8888-888888888888"}}"#, "Delay"),
                    Fixture.node(Fixture.synth, Fixture.instrumentKind(Fixture.instrument), "Synth")],
            edges: [Fixture.edge("66666666-6666-6666-6666-666666666663", from: effect, 0, to: Fixture.synth, 0)]
        )
        #expect(try Fixture.refusal(graph: graph, endpoints: nil)
            == .roleShapeMismatch(Fixture.role("instrument", Fixture.instrument)))
    }
}

@Suite("Legacy adoption role derivation", .productionAccessAudit)
struct ProjectLegacyAdoptionRoleTests {
    private typealias Fixture = LegacyAdoptionP5Fixture
    private let role = RoleID(validated: "rol.shared")

    private func node(
        _ id: String, _ kind: NodeKind, role: RoleID?, label: String = "L", ports: [GraphPort] = []
    ) -> GraphNode {
        GraphNode(id: NodeID(rawValue: id)!, kind: kind, label: label, role: role, ports: ports)
    }

    private func port(_ id: String, _ direction: PortDirection, _ signal: PortSignal = .audio, _ channels: Int? = nil)
        -> GraphPort {
        GraphPort(id: PortID(rawValue: id)!, direction: direction, signal: signal, channels: channels)
    }

    private func derive(_ nodes: [GraphNode]) throws(LegacyAdoptionRefusal) -> [ProjectRole] {
        try LegacyAdoptionRoles.derive(from: GraphDocument(id: LegacyAdoptionP5Fixture.graphID, nodes: nodes))
    }

    @Test func directionsFollowNodeKinds() {
        #expect(LegacyAdoptionRoles.direction(of: .roleInput) == .input)
        #expect(LegacyAdoptionRoles.direction(of: .roleOutput) == .output)
        #expect(LegacyAdoptionRoles.direction(of: .spatialBus) == .output)
        for kind in NodeKind.allCases where !kind.requiresRole {
            #expect(LegacyAdoptionRoles.direction(of: kind) == nil)
        }
    }

    @Test func confirmedCountsAndSignalsAreCarriedAsIs() throws {
        let roles = try derive([
            node("n1", .roleInput, role: role, label: "In", ports: [port("out.0", .output, .audio, 2)]),
            node("n2", .roleInput, role: role, label: "Again", ports: [port("out.1", .output, .audio, 2)]),
            node("n3", .roleOutput, role: RoleID(validated: "rol.midi"), ports: [port("in.0", .input, .midi)]),
            node("n4", .plugin, role: RoleID(validated: "rol.ignored"), ports: [port("in.0", .input)]),
            node("n5", .spatialBus, role: nil)
        ])
        #expect(roles == [
            ProjectRole(id: RoleID(validated: "rol.midi"), label: "L", direction: .output, signal: .midi),
            ProjectRole(id: role, label: "In", direction: .input, signal: .audio, channels: 2)
        ])
    }

    @Test func portlessRoleIsAudioWithNoCount() throws {
        #expect(try derive([node("n1", .spatialBus, role: role)])
            == [ProjectRole(id: role, label: "L", direction: .output, signal: .audio)])
    }

    @Test func severalDisagreementsRefuseTheFirstInDocumentOrder() throws {
        // `first` is the first role to disagree in document order and is neither the lowest nor the
        // highest RoleID. Extra consistent roles change the dictionary's capacity (and order) each run.
        let first = RoleID(validated: "rol.c3"), low = RoleID(validated: "rol.a1")
        let high = RoleID(validated: "rol.e5")
        for run in 0..<20 {
            let extras = (0..<(run * 5)).map { node("x\($0)", .roleOutput, role: RoleID(rawValue: "rol.x\($0)")!) }
            let nodes = [
                node("n1", .roleInput, role: first, ports: [port("out.0", .output, .audio, 2)]),
                node("n2", .roleOutput, role: low, ports: [port("in.0", .input, .audio)]),
                node("n3", .roleInput, role: high, ports: [port("out.0", .output, .audio, 1)])
            ] + extras + [
                node("n4", .roleInput, role: first, ports: [port("out.0", .output, .audio, 1)]),
                node("n5", .roleOutput, role: low, ports: [port("in.0", .input, .midi)]),
                node("n6", .roleInput, role: high, ports: [port("out.0", .output, .audio, 2)])
            ]
            #expect(throws: LegacyAdoptionRefusal.conflictingRole(first)) { try derive(nodes) }
        }
    }

    @Test func unwiredRoleNodesAdoptAsUnconfirmedAudio() throws {
        // No edges: the adapter gives both role nodes no ports. They become audio with no count and are
        // reported for review; nothing else is invented.
        let graph = Fixture.graph(nodes: [
            Fixture.node(Fixture.synth, Fixture.instrumentKind(Fixture.instrument), "Synth"),
            Fixture.node(Fixture.mains, Fixture.endpointKind(Fixture.mainsEndpoint), "Mains")
        ])
        let result = try Fixture.adopt(graph: graph, endpoints: nil)
        let mains = Fixture.role("endpoint", Fixture.mainsEndpoint)
        let synth = Fixture.role("instrument", Fixture.instrument)
        #expect(result.documents.project.roles == [
            ProjectRole(id: mains, label: "Mains", direction: .output, signal: .audio),
            ProjectRole(id: synth, label: "Synth", direction: .input, signal: .audio)
        ])
        #expect(result.unconfirmedChannelRoles == [mains, synth])
        #expect(result.documents.graphs.map(\.requiresReview) == [true])
    }

    @Test func disagreementRefusesAndNothingIsMerged() throws {
        let cases: [[GraphNode]] = [
            [node("n1", .roleInput, role: role), node("n2", .roleOutput, role: role)],
            [node("n1", .roleOutput, role: role), node("n2", .roleInput, role: role)],
            [node("n1", .roleInput, role: role, ports: [port("out.0", .output, .audio, 2)]),
             node("n2", .roleInput, role: role, ports: [port("out.0", .output, .audio, 1)])],
            [node("n1", .roleInput, role: role, ports: [port("out.0", .output, .audio, 2)]),
             node("n2", .roleInput, role: role, ports: [port("out.0", .output, .audio)])],
            [node("n1", .roleOutput, role: role, ports: [port("in.0", .input, .audio), port("in.1", .input, .midi)])]
        ]
        for nodes in cases {
            #expect(throws: LegacyAdoptionRefusal.conflictingRole(role)) { try derive(nodes) }
        }
    }

    @Test func portFacingTheRoleDirectionRefuses() {
        #expect(throws: LegacyAdoptionRefusal.roleShapeMismatch(role)) {
            try derive([node("n1", .roleInput, role: role, ports: [port("in.0", .input)])])
        }
        #expect(throws: LegacyAdoptionRefusal.roleShapeMismatch(role)) {
            try derive([node("n1", .spatialBus, role: role, ports: [port("in.0", .input), port("out.0", .output)])])
        }
    }
}
