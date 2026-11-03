import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct ProjectPreparationContextTests {
    static let digest = "sha256:" + String(repeating: "0123456789abcdef", count: 4)

    /// Shared by these two preparation suites without depending on iOS-only fixtures.
    static func sample() -> (ProjectDocument, [GraphDocument]) {
        let roleID = RoleID(validated: "rol.input")
        let assetID = AssetID(validated: "ast.audio")
        let shared = GraphDocument(id: GraphID(validated: "gph.shared"))
        let output = GraphPort(id: PortID(validated: "out"), direction: .output, signal: .audio, channels: 2)
        let selected = GraphDocument(id: GraphID(validated: "gph.selected"), nodes: [
            GraphNode(id: NodeID(validated: "nod.input"), kind: .roleInput, label: "Input",
                      role: roleID, ports: [output]),
            GraphNode(id: NodeID(validated: "nod.player"), kind: .mediaPlayer, label: "Player",
                      asset: assetID, ports: [output]),
            GraphNode(id: NodeID(validated: "nod.shared"), kind: .sharedGraph, label: "Shared", graph: shared.id)
        ])
        let project = ProjectDocument(
            id: ProjectID(validated: "prj.context"), name: "Preparation context",
            graphs: [ProjectGraphReference(graph: selected.id, revision: selected.revision),
                     ProjectGraphReference(graph: shared.id, revision: shared.revision)],
            roles: [ProjectRole(id: roleID, label: "Input", direction: .input, signal: .audio, channels: 2)],
            patches: [ProjectPatch(id: PatchID(validated: "pat.main"), label: "Main", graph: selected.id)],
            assets: [ProjectAsset(id: assetID, label: "Audio", media: .audio, contentDigest: digest,
                                  timePolicy: .fixedRate, timing: AssetTiming(startTicks: 0))]
        )
        return (project, [selected, shared])
    }

    static func minimal() -> (ProjectDocument, GraphDocument) {
        let graph = GraphDocument(id: GraphID(validated: "gph.selected"))
        let project = ProjectDocument(
            id: ProjectID(validated: "prj.preparation"), name: "",
            graphs: [ProjectGraphReference(graph: graph.id, revision: graph.revision)]
        )
        return (project, graph)
    }

    @Test func canonicalEncodedInclusiveBoundaryUsesMeasuredBaseline() throws {
        var (project, graph) = Self.minimal()
        project.extensions = ["padding": .string("")]
        let baseline = try project.encoded().count
        #expect(baseline < 1_024)
        project.extensions?["padding"] = .string(String(repeating: "a", count: 65_536 - baseline))
        try PreparationProjectBudget.check(project)
        #expect(try project.encoded().count == 65_536)
        let original = project
        let bytes = try project.encoded()
        try project.validatePreparationContext(selectedGraph: graph)
        #expect(project == original)
        #expect(try project.encoded() == bytes)
        project.extensions?["padding"] = .string(String(repeating: "a", count: 65_537 - baseline))
        try PreparationProjectBudget.check(project)
        #expect(try project.encoded().count == 65_537)
        #expect(throws: PreparationProjectRefusal.encodedLimit) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
    }

    @Test(arguments: ["\"", "\\", "\n", "\u{0001}"])
    func encodingExpansionIsCheckedAfterStructuralPass(character: String) throws {
        var (project, graph) = Self.minimal()
        project.name = String(repeating: character, count: 33_000)
        try PreparationProjectBudget.check(project)
        #expect(try project.encoded().count > 65_536)
        #expect(throws: PreparationProjectRefusal.encodedLimit) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
    }

    @Test func slashesAndMultibyteUnicodeUseActualCanonicalBytes() throws {
        var (project, graph) = Self.minimal()
        let baseline = try project.encoded().count
        project.name = String(repeating: "/", count: 32_000) + String(repeating: "🔊é", count: 5_000)
        #expect(try project.encoded().count == baseline + 62_000)
        try project.validatePreparationContext(selectedGraph: graph)
        project.name += String(repeating: "é", count: 2_000)
        try PreparationProjectBudget.check(project)
        #expect(throws: PreparationProjectRefusal.encodedLimit) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
    }

    @Test func structuralAndEncodingGatesDominateSelectedSemantics() throws {
        var (project, graph) = Self.minimal()
        project.graphs = []
        project.unknownFields = ["nonfinite": .double(.infinity)]
        try PreparationProjectBudget.check(project)
        #expect(throws: PreparationProjectRefusal.encoding) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
        project.name = String(repeating: "x", count: 131_073)
        #expect(throws: PreparationProjectRefusal.structuralLimit) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
        project.unknownFields = [:]
        #expect(throws: PreparationProjectRefusal.structuralLimit) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
        project.name = String(repeating: "x", count: 66_000)
        try PreparationProjectBudget.check(project)
        #expect(throws: PreparationProjectRefusal.encodedLimit) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
        project.name = ""
        #expect(throws: PreparationProjectRefusal.selected(.graphNotSupplied(graph.id, revision: graph.revision))) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
    }

    @Test func existingTopLevelFormatBoundsRemainFirst() {
        var (project, graph) = Self.minimal()
        project.graphs = Array(repeating: project.graphs[0], count: ProjectGraphLimits.projectRecords + 1)
        project.name = String(repeating: "x", count: 131_073)
        #expect(throws: PreparationProjectRefusal.formatBounds(
            .exceeded(path: "$.graphs", maximum: ProjectGraphLimits.projectRecords)
        )) { try project.validatePreparationContext(selectedGraph: graph) }
    }

    @Test func boundedElidedMetadataIsNotSanitizedOrRejected() throws {
        var (project, graph) = Self.minimal()
        let bytes = try project.encoded()
        project.unknownFields = [
            "name": .string(String(repeating: "x", count: 100_000)),
            "contract": .array([.bool(true)]), "version": .int(42)
        ]
        let original = project
        try PreparationProjectBudget.check(project)
        try project.validatePreparationContext(selectedGraph: graph)
        #expect(project == original)
        #expect(try project.encoded() == bytes)
    }

    @Test func completeDeclarationsAndSmallUnknownsSurviveWithoutUnrelatedBodies() throws {
        var (project, graphs) = Self.sample()
        project.revision = try ContractRevision(800)
        let selected = graphs[0]
        #expect(project.revision != selected.revision)
        project.roles.append(ProjectRole(
            id: RoleID(validated: "rol.unused"), label: "Unused", direction: .input, signal: .control
        ))
        let unrelated = GraphID(validated: "gph.unrelated")
        project.graphs.append(ProjectGraphReference(graph: unrelated, revision: try ContractRevision(77)))
        project.patches.append(ProjectPatch(id: PatchID(validated: "pat.unrelated"), label: "Other", graph: unrelated))
        project.assets.append(ProjectAsset(
            id: AssetID(validated: "ast.unused"), label: "Notes", media: .document,
            contentDigest: Self.digest
        ))
        project.actions = [ProjectMediaAction(
            id: ActionID(validated: "act.a"), asset: project.assets[0].id,
            policy: try PreparationProjectBudgetTests.privatePolicy(.object(["kept": .bool(true)])),
            extensions: ["action": .null]
        )]
        project.unknownFields = ["future": .array([.int(1)]), "name": .string("retained but elided")]
        project.extensions = ["vendor": .string("音")]
        project.roles[0].unknownFields = ["role": .bool(true)]
        project.graphs[0].unknownFields = ["pin": .int(1)]
        project.patches[0].unknownFields = ["patch": .null]
        project.assets[0].unknownFields = ["asset": .uint(3)]
        project.assets[0].timing?.unknownFields = ["timing": .double(0.5)]
        project.actions[0].unknownFields = ["action": .string("kept")]
        project.actions[0].policy.unknownFields = ["policy": .null]
        project.actions[0].policy.extensions = ["vendor": .bool(true)]
        let original = project
        let encoded = try project.encoded()
        try project.validatePreparationContext(selectedGraph: selected)
        #expect(project == original)
        #expect(try project.encoded() == encoded)
        #expect(project.actions[0].policy.hasUnknownFields)
        // The generic all-bodies API still requires the unrelated declaration.
        #expect(project.validationErrors(graphs: graphs).contains(
            .graphNotSupplied(unrelated, revision: try ContractRevision(77))
        ))
    }

    @Test func selectedReferenceMustBeUniqueAndPinnedToCandidateRevision() throws {
        var (project, graph) = Self.minimal()
        graph.revision = try ContractRevision(7)
        project.revision = try ContractRevision(99)
        #expect(throws: PreparationProjectRefusal.selected(.graphNotSupplied(graph.id, revision: graph.revision))) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
        project.graphs[0].revision = graph.revision
        try project.validatePreparationContext(selectedGraph: graph)
        project.graphs.append(project.graphs[0])
        #expect(throws: PreparationProjectRefusal.selected(.duplicateGraph(graph.id))) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
        project.graphs[1].revision = try graph.revision.next()
        #expect(throws: PreparationProjectRefusal.selected(.duplicateGraph(graph.id))) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
        project.graphs.removeLast()
        project.graphs[0].graph = GraphID(validated: "gph.wrong")
        #expect(throws: PreparationProjectRefusal.selected(.graphNotSupplied(graph.id, revision: graph.revision))) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
    }

    @Test func selectedRolesAssetsAndSharedGraphsUseCompleteDeclarations() throws {
        let (original, graphs) = Self.sample()
        let graph = graphs[0]
        let roleNode = try #require(graph.nodes.first { $0.kind == .roleInput })
        let roleID = try #require(roleNode.role)
        let index = try #require(original.roles.firstIndex { $0.id == roleID })
        var project = original
        project.roles.remove(at: index)
        #expect(throws: PreparationProjectRefusal.selected(.missingRole(graph.id, node: roleNode.id, roleID))) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
        project = original
        project.roles[index].direction = .output
        #expect(throws: PreparationProjectRefusal.selected(.roleMismatch(graph.id, node: roleNode.id, roleID))) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
        project = original
        project.roles[index].channels = 3
        #expect(throws: PreparationProjectRefusal.selected(.roleMismatch(graph.id, node: roleNode.id, roleID))) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
        project = original
        project.roles[index].signal = .midi
        project.roles[index].channels = nil
        #expect(throws: PreparationProjectRefusal.selected(.roleMismatch(graph.id, node: roleNode.id, roleID))) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
        project = original
        let player = try #require(graph.nodes.first { $0.kind == .mediaPlayer })
        let assetID = try #require(player.asset)
        project.assets = []
        #expect(throws: PreparationProjectRefusal.selected(.missingAsset(graph.id, node: player.id, assetID))) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
        project = original
        let shared = try #require(graph.nodes.first { $0.kind == .sharedGraph })
        let sharedID = try #require(shared.graph)
        project.graphs.removeAll { $0.graph == sharedID }
        #expect(throws: PreparationProjectRefusal.selected(.missingSharedGraph(graph.id, node: shared.id, sharedID))) {
            try project.validatePreparationContext(selectedGraph: graph)
        }
    }

    @Test func declarationChecksAndGenericGraphChecksAreStillApplied() throws {
        var (project, graphs) = Self.sample()
        let original = project
        project.roles.append(project.roles[0])
        #expect(throws: PreparationProjectRefusal.selected(.duplicateRole(project.roles[0].id))) {
            try project.validatePreparationContext(selectedGraph: graphs[0])
        }
        project = original
        project.assets[0].contentDigest = "invalid"
        #expect(throws: PreparationProjectRefusal.selected(.invalidContentDigest(project.assets[0].id))) {
            try project.validatePreparationContext(selectedGraph: graphs[0])
        }
        project = original
        let missing = GraphID(validated: "gph.absent")
        project.patches[0].graph = missing
        #expect(throws: PreparationProjectRefusal.selected(.missingPatchGraph(project.patches[0].id, missing))) {
            try project.validatePreparationContext(selectedGraph: graphs[0])
        }
        project = original
        project.actions = [ProjectMediaAction(
            id: ActionID(validated: "act.missing"), asset: AssetID(validated: "ast.missing"),
            policy: try ActionPolicy(media: .audio, timePolicy: .fixedRate, latePolicy: .drop)
        )]
        #expect(throws: PreparationProjectRefusal.selected(
            .missingActionAsset(project.actions[0].id, project.actions[0].asset)
        )) { try project.validatePreparationContext(selectedGraph: graphs[0]) }
        project = original
        graphs[0].requiresReview = true
        #expect(throws: PreparationProjectRefusal.selected(.graph(graphs[0].id, .reviewRequired))) {
            try project.validatePreparationContext(selectedGraph: graphs[0])
        }
    }
}
