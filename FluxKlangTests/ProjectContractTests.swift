//
//  ProjectContractTests.swift
//  FluxKlangTests
//
//  The versioned project contract: unknown-data round trips, portable roles,
//  G-MEDIA asset references, and rejection of dangling references across the
//  project and the graphs it pins.
//

import Foundation
import Testing
@testable import FluxKlang

struct ProjectContractTests {
    static let digest = "sha256:" + String(repeating: "0123456789abcdef", count: 4)
    static let canonicalProject = #"{"assets":[{"contentDigest":"\#(digest)","extensions":{"loudnessLufs":-14},"#
        + #""id":"ast.click","label":"Click","media":"audio","timePolicy":"fixedRate","#
        + #""timing":{"startTicks":15360,"x-anchor":"take"}}],"contract":"fluxklang.project","#
        + #""drafts":[{"id":"dft.later"}],"graphs":[{"graph":"gph.main","revision":43}],"id":"prj.set","#
        + #""name":"Set","patches":[{"graph":"gph.main","id":"pat.verse","label":"Verse","#
        + #""variations":[{"deltas":[]}]}],"revision":12,"roles":[{"channels":2,"direction":"output","#
        + #""id":"rol.mains","label":"Mains","signal":"audio"}],"version":1}"#

    @Test func roundTripsVersionAndUnknownOptionalDataByteEqual() throws {
        let project = try ProjectDocument.decode(from: Data(Self.canonicalProject.utf8))
        #expect(project.unknownFields == ["drafts": .array([.object(["id": .string("dft.later")])])])
        #expect(project.patches.first?.unknownFields == ["variations": .array([.object(["deltas": .array([])])])])
        #expect(project.assets.first?.extensions == ["loudnessLufs": .int(-14)])
        #expect(project.assets.first?.timing?.startTicks == 15360)
        #expect(try project.encoded() == Data(Self.canonicalProject.utf8))
        #expect(project.validationErrors(graphs: [], strict: true) == [
            .unknownFields(path: "$"), .unknownFields(path: "$.patches[pat.verse]"),
            .unknownFields(path: "$.assets[ast.click].timing"),
            .graphNotSupplied(GraphID(validated: "gph.main"), revision: try ContractRevision(43))
        ])
    }

    @Test func versionPolicyRejectsOtherContractsAndNewerVersions() {
        let graphNamed = Self.canonicalProject.replacingOccurrences(of: "fluxklang.project", with: "fluxklang.graph")
        #expect(throws: ContractVersionError.wrongContract(expected: "fluxklang.project", found: "fluxklang.graph")) {
            try ProjectDocument.decode(from: Data(graphNamed.utf8))
        }
        let newer = Self.canonicalProject.replacingOccurrences(of: #""version":1"#, with: #""version":3"#)
        #expect(throws: ContractVersionError.unsupportedVersion(found: 3, supported: 1)) {
            try ProjectDocument.decode(from: Data(newer.utf8))
        }
    }

    @Test func sampleProjectAndGraphsValidate() throws {
        let (project, graphs) = Self.sample()
        try project.validate(graphs: graphs, strict: true)
        #expect(try ProjectDocument.decode(from: project.encoded()) == project)
    }

    @Test func rejectsRecursiveSharedGraphsAndAmbiguousSuppliedRevisions() {
        let first = GraphID(validated: "gph.first")
        let second = GraphID(validated: "gph.second")
        let graphs = [
            GraphDocument(id: first, nodes: [
                GraphNode(id: NodeID(validated: "nod.second"), kind: .sharedGraph, label: "Second", graph: second)
            ]),
            GraphDocument(id: second, nodes: [
                GraphNode(id: NodeID(validated: "nod.first"), kind: .sharedGraph, label: "First", graph: first)
            ])
        ]
        let project = ProjectDocument(
            id: ProjectID(validated: "prj.recursive"), name: "Recursive",
            graphs: graphs.map { ProjectGraphReference(graph: $0.id, revision: $0.revision) }
        )
        #expect(!project.validationErrors(graphs: graphs).isEmpty)

        var (ordinary, supplied) = Self.sample()
        var conflicting = supplied[0]
        conflicting.nodes = []
        supplied.append(conflicting)
        let duplicate = ProjectValidationError.duplicateSuppliedGraph(conflicting.id, revision: conflicting.revision)
        #expect(ordinary.validationErrors(graphs: supplied) == [duplicate])
        ordinary.graphs = []
        ordinary.patches = []
        #expect(ordinary.validationErrors(graphs: supplied) == [duplicate])
    }

    @Test func duplicateGraphReferencesValidateEachRevisionOnce() {
        var (project, graphs) = Self.sample()
        let main = graphs[0].id
        let missingRole = RoleID(validated: "rol.missing")
        graphs[0].requiresReview = true
        graphs[0].nodes[0].role = missingRole
        project.graphs.insert(project.graphs[0], at: 1)
        project.graphs[1].extensions = ["note": .string("same revision")]
        project.graphs[1].unknownFields = ["futureReference": .bool(true)]
        #expect(project.validationErrors(graphs: graphs) == [
            .duplicateGraph(main), .graph(main, .reviewRequired),
            .missingRole(main, node: graphs[0].nodes[0].id, missingRole)
        ])
    }

    @Test func duplicateGraphReferencesKeepDistinctRevisionFailures() throws {
        var (project, graphs) = Self.sample()
        let main = graphs[0].id
        let next = try ContractRevision(44)
        let later = try ContractRevision(45)
        let nextReference = ProjectGraphReference(graph: main, revision: next)
        project.graphs = [
            project.graphs[0], nextReference, nextReference,
            ProjectGraphReference(graph: main, revision: later), project.graphs[1]
        ]
        let duplicates = Array(repeating: ProjectValidationError.duplicateGraph(main), count: 3)
        #expect(project.validationErrors(graphs: graphs) == duplicates + [
            .graphNotSupplied(main, revision: next), .graphNotSupplied(main, revision: later)
        ])

        var suppliedNext = graphs[0]
        suppliedNext.revision = next
        suppliedNext.requiresReview = true
        graphs.append(suppliedNext)
        #expect(project.validationErrors(graphs: graphs) == duplicates + [
            .graph(main, .reviewRequired), .graphNotSupplied(main, revision: later)
        ])
    }

    @Test func suppliedGraphIndexKeepsFirstRevisionMatchAndDiagnosticOrder() {
        let (project, original) = Self.sample()
        var graphs = original
        var duplicate = graphs[0]
        duplicate.requiresReview = true
        graphs.append(duplicate)
        let error = ProjectValidationError.duplicateSuppliedGraph(duplicate.id, revision: duplicate.revision)
        #expect(project.validationErrors(graphs: graphs) == [error])
        graphs.swapAt(0, graphs.count - 1)
        #expect(project.validationErrors(graphs: graphs) == [error, .graph(duplicate.id, .reviewRequired)])
    }

    @Test func referenceIndexesKeepFirstRoleAndAssetAndDuplicateDiagnostics() throws {
        var (project, graphs) = Self.sample()
        var conflictingRole = project.roles[0]
        conflictingRole.channels = 1
        project.roles.append(conflictingRole)
        var conflictingAsset = project.assets[0]
        conflictingAsset.media = .midi
        project.assets.append(conflictingAsset)
        project.actions = [ProjectMediaAction(
            id: ActionID(validated: "act.first"), asset: conflictingAsset.id,
            policy: try ActionPolicy(media: .audio, timePolicy: .fixedRate, latePolicy: .drop)
        )]
        let duplicates: [ProjectValidationError] = [
            .duplicateRole(conflictingRole.id), .duplicateAsset(conflictingAsset.id)
        ]
        #expect(project.validationErrors(graphs: graphs) == duplicates)
        project.roles.swapAt(0, project.roles.count - 1)
        #expect(project.validationErrors(graphs: graphs) == duplicates + [
            .roleMismatch(graphs[0].id, node: graphs[0].nodes[0].id, conflictingRole.id)
        ])
        project.assets.swapAt(0, project.assets.count - 1)
        let player = try #require(graphs[0].nodes.first { $0.kind == .mediaPlayer })
        #expect(project.validationErrors(graphs: graphs) == duplicates + [
            .actionMediaMismatch(project.actions[0].id),
            .roleMismatch(graphs[0].id, node: graphs[0].nodes[0].id, conflictingRole.id),
            .assetMediaMismatch(graphs[0].id, node: player.id, conflictingAsset.id)
        ])
    }

    @Test(arguments: [
        (AssetMedia.document, PortSignal.audio), (.document, .midi), (.audio, .midi), (.midi, .audio)
    ])
    func mediaPlayersRejectUnplayableOrIncompatibleAssets(media: AssetMedia, signal: PortSignal) throws {
        var (project, graphs) = Self.sample()
        project.assets[0].media = media
        project.assets[0].timePolicy = media == .document ? nil : .fixedRate
        project.assets[0].timing = media == .document ? nil : AssetTiming(startFrame: 0)
        let player = try #require(graphs[0].nodes.firstIndex { $0.kind == .mediaPlayer })
        graphs[0].nodes[player].ports = [
            GraphContractTests.port("out", .output, signal, channels: signal == .audio ? 2 : nil)
        ]
        try graphs[0].validate(strict: true)
        var recordsOnly = project
        recordsOnly.graphs = []
        recordsOnly.patches = []
        try recordsOnly.validate(graphs: [], strict: true)
        #expect(throws: ProjectValidationError.self) { try project.validate(graphs: graphs) }
        let mismatch = ProjectValidationError.assetMediaMismatch(
            graphs[0].id, node: graphs[0].nodes[player].id, project.assets[0].id
        )
        #expect(project.validationErrors(graphs: graphs) == [mismatch])
        if media == .document {
            graphs[0].nodes[player].ports = []
            #expect(project.validationErrors(graphs: graphs) == [mismatch])
        }
    }

    @Test(arguments: [AssetMedia.audio, .midi])
    func mediaPlayersMatchEveryMediaOutputWithoutRestrictingAuxiliaryPorts(media: AssetMedia) throws {
        var (project, graphs) = Self.sample()
        project.assets[0].media = media
        let player = try #require(graphs[0].nodes.firstIndex { $0.kind == .mediaPlayer })
        let signal: PortSignal = media == .audio ? .audio : .midi
        let ports = [
            GraphContractTests.port("out", .output, signal, channels: signal == .audio ? 2 : nil),
            GraphContractTests.port("trigger", .input, .control),
            GraphContractTests.port("clock-in", .input, .clock),
            GraphContractTests.port("status", .output, .control),
            GraphContractTests.port("clock-out", .output, .clock)
        ]
        graphs[0].nodes[player].ports = ports
        try project.validate(graphs: graphs, strict: true)
        graphs[0].nodes[player].ports = []
        try project.validate(graphs: graphs, strict: true)
        let incompatible: PortSignal = signal == .audio ? .midi : .audio
        graphs[0].nodes[player].ports = ports + [
            GraphContractTests.port("other", .output, incompatible, channels: incompatible == .audio ? 2 : nil)
        ]
        #expect(throws: ProjectValidationError.self) { try project.validate(graphs: graphs) }
        #expect(project.validationErrors(graphs: graphs) == [
            .assetMediaMismatch(graphs[0].id, node: graphs[0].nodes[player].id, project.assets[0].id)
        ])
    }

    @Test func projectCollectionsAreBoundedBeforeReferenceValidation() {
        var (project, graphs) = Self.sample()
        project.graphs = Array(repeating: project.graphs[0], count: ProjectGraphLimits.projectRecords + 1)
        #expect(project.validationErrors(graphs: graphs) == [
            .bounds(.exceeded(path: "$.graphs", maximum: ProjectGraphLimits.projectRecords))
        ])
        #expect(throws: ProjectGraphLimitError.self) { try project.encoded() }
    }

    @Test func rejectsDanglingReferences() throws {
        var (project, graphs) = Self.sample()
        let main = GraphID(validated: "gph.main")
        project.roles.removeAll { $0.id.rawValue == "rol.cue" }
        project.assets = []
        project.patches.append(ProjectPatch(id: PatchID(validated: "pat.ghost"), label: "Ghost",
                                            graph: GraphID(validated: "gph.ghost")))
        graphs.removeAll { $0.id.rawValue == "gph.fx" }
        #expect(project.validationErrors(graphs: graphs) == [
            .missingPatchGraph(PatchID(validated: "pat.ghost"), GraphID(validated: "gph.ghost")),
            .missingRole(main, node: NodeID(validated: "nod.cue"), RoleID(validated: "rol.cue")),
            .missingAsset(main, node: NodeID(validated: "nod.click"), AssetID(validated: "ast.click")),
            .graphNotSupplied(GraphID(validated: "gph.fx"), revision: .initial)
        ])
        project.graphs.removeAll { $0.graph.rawValue == "gph.fx" }
        #expect(project.validationErrors(graphs: graphs).contains(
            .missingSharedGraph(main, node: NodeID(validated: "nod.fx"), GraphID(validated: "gph.fx"))
        ))
        project.graphs[0].revision = try ContractRevision(44)
        let pinned = try ContractRevision(44)
        #expect(project.validationErrors(graphs: graphs).contains(.graphNotSupplied(main, revision: pinned)))
    }

    @Test func rolesMustMatchTheirNodesAndGraphErrorsSurface() {
        var (project, graphs) = Self.sample()
        let index = project.roles.firstIndex { $0.id.rawValue == "rol.mic" } ?? 0
        project.roles[index].channels = 2
        graphs[0].edges.append(GraphContractTests.edge(
            "edg.bad", GraphContractTests.address("nod.mic", "out"), GraphContractTests.address("nod.verb", "mod")
        ))
        let main = GraphID(validated: "gph.main")
        #expect(project.validationErrors(graphs: graphs) == [
            .graph(main, .signalMismatch(edge: EdgeID(validated: "edg.bad"), from: .audio, to: .control)),
            .roleMismatch(main, node: NodeID(validated: "nod.mic"), RoleID(validated: "rol.mic"))
        ])
    }

    @Test func assetsFollowGMediaRules() {
        var (project, graphs) = Self.sample()
        let click = AssetID(validated: "ast.click")
        project.assets[0].contentDigest = "sha256:ABC"
        project.assets[0].timePolicy = .tempoFollowing
        project.assets.append(ProjectAsset(
            id: AssetID(validated: "ast.chart"), label: "Chart", media: .document, contentDigest: Self.digest,
            timePolicy: .fixedRate, timing: AssetTiming(startFrame: 0)
        ))
        project.assets.append(ProjectAsset(
            id: AssetID(validated: "ast.loop"), label: "Loop", media: .midi, contentDigest: Self.digest
        ))
        #expect(project.validationErrors(graphs: graphs) == [
            .invalidContentDigest(click), .invalidTimePolicy(click),
            .invalidTimePolicy(AssetID(validated: "ast.chart")), .invalidTiming(AssetID(validated: "ast.chart")),
            .invalidTimePolicy(AssetID(validated: "ast.loop"))
        ])
    }

    @Test func persistsPerActionMediaPolicyAndRejectsUnresolvedOrMismatchedAssets() throws {
        var (project, graphs) = Self.sample()
        var policy = try ActionPolicy(
            media: .audio, timePolicy: .fixedRate, latePolicy: .joinInProgress(maxLatenessMs: 120),
            retroactiveMs: 80
        )
        policy.unknownFields = ["futurePolicy": .object(["mode": .string("preserve")])]
        let actionID = ActionID(validated: "act.backing")
        var action = ProjectMediaAction(id: actionID, asset: project.assets[0].id, policy: policy,
                                        extensions: ["annotation": .string("portable")])
        action.unknownFields = ["futureAction": .array([.null, .int(1)])]
        project.actions = [action]
        let decoded = try ProjectDocument.decode(from: project.encoded())
        #expect(decoded == project)
        #expect(decoded.actions[0].policy.retroactiveMs == 80)
        #expect(decoded.validationErrors(graphs: graphs).isEmpty)

        project.actions[0].asset = AssetID(validated: "ast.missing")
        #expect(project.validationErrors(graphs: graphs).contains(
            .missingActionAsset(actionID, AssetID(validated: "ast.missing"))
        ))
        project.actions[0] = action
        project.assets[0].media = .midi
        #expect(project.validationErrors(graphs: graphs).contains(.actionMediaMismatch(actionID)))
        project.actions.append(action)
        #expect(project.validationErrors(graphs: graphs).contains(.duplicateAction(actionID)))
    }

    @Test func requiredUnknownProjectFeaturesNeverBecomeOptionalData() {
        let data = Data(Self.canonicalProject.replacingOccurrences(
            of: #""version":1"#, with: #""version":1,"requiredFeatures":["future-routing"]"#
        ).utf8)
        #expect(throws: ProjectGraphVersionError.unsupportedRequiredFeatures(["future-routing"])) {
            try ProjectDocument.decode(from: data)
        }
    }

    @Test func nestedLatePolicyDataSurvivesProjectActionCoding() throws {
        let data = Data("""
        {"id":"act.future","asset":"ast.click","extensions":{"actionNote":true},"futureAction":1,
         "policy":{"media":"audio","timePolicy":"fixedRate",
          "latePolicy":{"fireLate":{"maxLatenessMs":20,"futureLate":[1,null]},"futureOuter":{"v":2}},
          "retroactiveMs":10,"stoppedPolicy":"wait","extensions":{"vendor":"policy"},"futurePolicy":false}}
        """.utf8)
        let action = try ContractCoding.decode(ProjectMediaAction.self, from: data)
        let encoded = try ContractCoding.makeEncoder().encode(action)
        #expect(try ContractCoding.decode(JSONValue.self, from: encoded)
            == ContractCoding.decode(JSONValue.self, from: data))
        var (project, graphs) = Self.sample()
        project.actions = [action]
        #expect(project.validationErrors(graphs: graphs).isEmpty)
        #expect(project.validationErrors(graphs: graphs, strict: true).contains(
            .unknownFields(path: "$.actions[act.future].policy")
        ))
    }

    /// The graph sample plus a media player and a shared-graph instance, with
    /// the project that owns their roles, assets and graphs.
    static func sample() -> (ProjectDocument, [GraphDocument]) {
        var main = GraphContractTests.sampleGraph()
        let fxID = GraphID(validated: "gph.fx")
        main.nodes += [
            GraphNode(id: NodeID(validated: "nod.click"), kind: .mediaPlayer, label: "Click",
                      asset: AssetID(validated: "ast.click"),
                      ports: [GraphContractTests.port("out", .output, channels: 2)]),
            GraphNode(id: NodeID(validated: "nod.fx"), kind: .sharedGraph, label: "FX rack", graph: fxID)
        ]
        let roles = [
            ProjectRole(id: RoleID(validated: "rol.keys"), label: "Keys", direction: .input, signal: .audio,
                        channels: 2),
            ProjectRole(id: RoleID(validated: "rol.mic"), label: "Mic", direction: .input, signal: .audio, channels: 1),
            ProjectRole(id: RoleID(validated: "rol.pads"), label: "Pads", direction: .input, signal: .midi),
            ProjectRole(id: RoleID(validated: "rol.mains"), label: "Mains", direction: .output, signal: .audio,
                        channels: 2),
            ProjectRole(id: RoleID(validated: "rol.cue"), label: "Cue", direction: .output, signal: .audio, channels: 2)
        ]
        let project = ProjectDocument(
            id: ProjectID(validated: "prj.set"),
            name: "Set",
            graphs: [ProjectGraphReference(graph: main.id, revision: main.revision),
                     ProjectGraphReference(graph: fxID, revision: .initial)],
            roles: roles,
            patches: [ProjectPatch(id: PatchID(validated: "pat.verse"), label: "Verse", graph: main.id)],
            assets: [ProjectAsset(id: AssetID(validated: "ast.click"), label: "Click", media: .audio,
                                  contentDigest: digest, timePolicy: .fixedRate, timing: AssetTiming(startTicks: 0))]
        )
        return (project, [main, GraphDocument(id: fxID)])
    }
}
