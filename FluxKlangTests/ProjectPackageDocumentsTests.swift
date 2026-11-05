import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

enum DocumentsTestSupport {
    static let graphID = GraphID(validated: "gph.main")
    static let projectPath = "documents/project.json"
    static let graphPath = "graphs/main.json"

    static func policy(entries: Int = 32, entryBytes: Int = 4096, totalBytes: Int = 16_384) throws
        -> ProjectPackageManifestPolicy {
        try ProjectPackageManifestPolicy(
            packageLimits: ProjectPackageLimits(
                maxEntries: entries, maxDepth: 8, maxPathUTF8Bytes: 256,
                maxEntryBytes: entryBytes, maxTotalBytes: totalBytes
            ),
            maxManifestBytes: 2048
        )
    }

    static func graph(_ id: GraphID = graphID) -> GraphDocument {
        var graph = GraphDocument(id: id, label: "Main", requiresReview: true)
        graph.unknownFields = ["futureGraphField": .object(["kept": .int(7)])]
        return graph
    }

    static func project(graphs: [GraphID] = [graphID], revision: ContractRevision = .initial) -> ProjectDocument {
        var project = ProjectDocument(
            id: ProjectID(validated: "prj.set"), name: "Set",
            graphs: graphs.map { ProjectGraphReference(graph: $0, revision: revision) }
        )
        project.unknownFields = ["futureProjectField": .string("keep")]
        project.extensions = ["vendor": .array([.bool(true), .null])]
        return project
    }

    /// In-memory contents with hand-written member bytes and no declared lengths.
    static func contents(
        project projectBytes: Data, graph graphBytes: Data,
        projectID: ProjectID = ProjectID(validated: "prj.set"), revision: ContractRevision = .initial
    ) throws -> ProjectPackageContents {
        let manifest = ProjectPackageManifest(
            project: ProjectPackageProjectReference(
                id: projectID, revision: .initial,
                member: ProjectPackageMember(path: projectPath)
            ),
            graphs: [ProjectPackageGraphReference(
                graph: graphID, revision: revision, member: ProjectPackageMember(path: graphPath)
            )],
            resources: [], opaqueState: []
        )
        return try ProjectPackageContents(
            manifestBytes: manifest.encoded(policy: policy()), directories: ["documents", "graphs"],
            files: [projectPath: projectBytes, graphPath: graphBytes], policy: policy()
        )
    }

    static func read(project: Data, graph: Data) throws -> ProjectPackageDocuments {
        try ProjectPackageDocuments(contents: contents(project: project, graph: graph))
    }

    static func validProjectBytes() throws -> Data { try project().encoded() }
    static func validGraphBytes() throws -> Data { try graph().encoded() }
}

struct ProjectPackageDocumentsTests {
    private typealias Support = DocumentsTestSupport

    private func make(
        project: ProjectDocument = Support.project(),
        graphs: [(path: String, document: GraphDocument)] = [(Support.graphPath, Support.graph())],
        extraFiles: [ProjectPackageFile] = [],
        policy: ProjectPackageManifestPolicy? = nil
    ) throws -> ProjectPackageContents {
        try ProjectPackageContents.make(
            project: (Support.projectPath, project), graphs: graphs, extraFiles: extraFiles,
            policy: policy ?? Support.policy()
        )
    }

    @Test func makeThenReadRoundTripsDocumentsAndUnknownFields() throws {
        let contents = try make()
        let documents = try ProjectPackageDocuments(contents: contents)
        #expect(documents.project == Support.project())
        #expect(documents.graphs == [Support.graph()])
        #expect(documents.project.unknownFields["futureProjectField"] == .string("keep"))
        #expect(documents.graphs.first?.unknownFields["futureGraphField"] == .object(["kept": .int(7)]))
        #expect(documents.contents == contents)
        #expect(contents.directories == ["documents", "graphs"])
        #expect(contents.manifest.project.member.byteCount == (try Support.validProjectBytes()).count)
        #expect(contents.manifest.graphs.map(\.member.byteCount) == [(try Support.validGraphBytes()).count])
        #expect(contents.files.first { $0.path == Support.graphPath }?.role == .graph(Support.graphID))
    }

    @Test func graphsDecodeInManifestOrderFromTheirOwnMembers() throws {
        let second = GraphID(validated: "gph.aux")
        let contents = try make(
            project: Support.project(graphs: [second, Support.graphID]),
            graphs: [("z/aux.json", Support.graph(second)), ("a/main.json", Support.graph())]
        )
        let documents = try ProjectPackageDocuments(contents: contents)
        #expect(documents.graphs.map(\.id) == [second, Support.graphID])
        #expect(contents.manifest.graphs.map(\.member.path) == ["z/aux.json", "a/main.json"])
    }

    @Test func opaqueAndUnlistedBytesSurviveUnchanged() throws {
        let extras = [
            ProjectPackageFile(path: "state/z.bin", role: .opaqueState, bytes: Data([0xFF, 0x00, 0xFE])),
            ProjectPackageFile(path: "state/a.bin", role: .opaqueState, bytes: Data()),
            ProjectPackageFile(path: "notes/deep/readme.txt", role: .unlisted, bytes: Data("keep".utf8))
        ]
        let contents = try make(extraFiles: extras)
        #expect(contents.manifest.opaqueState.map(\.path) == ["state/z.bin", "state/a.bin"])
        #expect(contents.manifest.opaqueState.map(\.byteCount) == [3, 0])
        #expect(contents.directories == ["documents", "graphs", "notes", "notes/deep", "state"])
        for extra in extras {
            #expect(contents.files.contains(extra))
        }
        // A reader sees the same original bytes, so rebuilding from them is lossless.
        var files: [String: Data] = [:]
        for file in contents.files { files[file.path] = file.bytes }
        let reread = try ProjectPackageContents(
            manifestBytes: contents.manifestBytes, directories: contents.directories, files: files,
            policy: Support.policy()
        )
        let documents = try ProjectPackageDocuments(contents: reread)
        #expect(documents.contents == contents)
        #expect(documents.project == Support.project())
    }

    @Test func graphsRequiringReviewAndUnvalidatedProjectsStayReadable() throws {
        var project = Support.project()
        let role = ProjectRole(id: RoleID(validated: "role.out"), label: "Out", direction: .output, signal: .audio)
        project.roles = [role, role]
        #expect(throws: ProjectValidationError.self) { try project.validate(graphs: [Support.graph()]) }
        let documents = try ProjectPackageDocuments(contents: make(project: project))
        #expect(documents.project.roles.count == 2)
        #expect(documents.graphs.first?.requiresReview == true)
    }

    @Test func malformedDocumentsRefuseTyped() throws {
        let graph = try Support.validGraphBytes()
        let project = try Support.validProjectBytes()
        #expect(throws: ProjectPackageDocumentError.undecodableProject) {
            try Support.read(project: Data("{not json".utf8), graph: graph)
        }
        #expect(throws: ProjectPackageDocumentError.undecodableGraph(Support.graphID)) {
            try Support.read(project: project, graph: Data(#"{"contract":"fluxklang.graph","version":1}"#.utf8))
        }
        // A project document in a graph role names the wrong contract.
        #expect(throws: ProjectPackageDocumentError.undecodableGraph(Support.graphID)) {
            try Support.read(project: project, graph: project)
        }
        #expect(throws: ProjectPackageDocumentError.undecodableProject) {
            try Support.read(project: Data([0xEF, 0xBB, 0xBF]) + project, graph: graph)
        }
    }

    @Test func futureVersionsAndRequiredFeaturesRefuse() throws {
        let graph = try Support.validGraphBytes()
        let project = try Support.validProjectBytes()
        #expect(throws: ProjectPackageDocumentError.unsupportedProject) {
            try Support.read(project: Data(#"{"contract":"fluxklang.project","version":99}"#.utf8), graph: graph)
        }
        #expect(throws: ProjectPackageDocumentError.unsupportedGraph(Support.graphID)) {
            try Support.read(project: project, graph: Data(#"{"contract":"fluxklang.graph","version":2}"#.utf8))
        }
        let featured = Data(#"{"contract":"fluxklang.project","version":1,"requiredFeatures":["x.v9"]}"#.utf8)
        #expect(throws: ProjectPackageDocumentError.unsupportedProject) {
            try Support.read(project: featured, graph: graph)
        }
        let marker = #""contract":"fluxklang.graph""#
        let featuredGraph = try #require(String(bytes: graph, encoding: .utf8))
            .replacingOccurrences(of: marker, with: marker + #","requiredFeatures":["future.v9"]"#)
        #expect(throws: ProjectPackageDocumentError.unsupportedGraph(Support.graphID)) {
            try Support.read(project: project, graph: Data(featuredGraph.utf8))
        }
        var future = Support.graph()
        future.requiredFeatures = ["future.v9"]
        #expect(throws: ProjectPackageDocumentError.unencodableGraph(Support.graphID)) {
            try make(graphs: [(Support.graphPath, future)])
        }
    }

    @Test func legacyDocumentsRefuseWithoutMigration() throws {
        let graph = try Support.validGraphBytes()
        let project = try Support.validProjectBytes()
        #expect(throws: ProjectPackageDocumentError.legacyProject) {
            try Support.read(project: Data(#"{"name":"Old set"}"#.utf8), graph: graph)
        }
        #expect(throws: ProjectPackageDocumentError.legacyGraph(Support.graphID)) {
            try Support.read(project: project, graph: Data(#"{"nodes":[],"edges":[]}"#.utf8))
        }
    }

    @Test func oversizedDocumentRefusesAsBounds() throws {
        let big = try Support.policy(entryBytes: 5 * 1_048_576, totalBytes: 6 * 1_048_576)
        let padded = try Support.validProjectBytes() + Data(repeating: 0x20, count: ProjectGraphLimits.documentBytes)
        let manifest = ProjectPackageManifest(
            project: ProjectPackageProjectReference(
                id: ProjectID(validated: "prj.set"), revision: .initial,
                member: ProjectPackageMember(path: Support.projectPath)
            ),
            graphs: [ProjectPackageGraphReference(
                graph: Support.graphID, revision: .initial, member: ProjectPackageMember(path: Support.graphPath)
            )],
            resources: [], opaqueState: []
        )
        let contents = try ProjectPackageContents(
            manifestBytes: manifest.encoded(policy: big), directories: ["documents", "graphs"],
            files: [Support.projectPath: padded, Support.graphPath: Support.validGraphBytes()], policy: big
        )
        #expect(throws: ProjectPackageDocumentError.projectBounds) { try ProjectPackageDocuments(contents: contents) }
    }

    @Test func identityAndRevisionMismatchesRefuse() throws {
        let graph = try Support.validGraphBytes()
        let project = try Support.validProjectBytes()
        #expect(throws: ProjectPackageDocumentError.manifest(.projectMismatch)) {
            try ProjectPackageDocuments(contents: Support.contents(
                project: project, graph: graph, projectID: ProjectID(validated: "prj.other")
            ))
        }
        let revised = try Support.project(revision: ContractRevision(1)).encoded()
        #expect(throws: ProjectPackageDocumentError.manifest(.graphMismatch)) {
            try ProjectPackageDocuments(
                contents: Support.contents(project: revised, graph: graph, revision: ContractRevision(1))
            )
        }
    }

    @Test func decodedUnknownFieldsSurviveMakeAndRead() throws {
        let projectBytes = Data(#"""
        {"contract":"fluxklang.project","version":1,"id":"prj.set","revision":0,"name":"Set",
         "graphs":[{"graph":"gph.main","revision":0,"futureReference":[1,2]}],"roles":[],
         "futureProject":{"nested":true}}
        """#.utf8)
        let graphBytes = Data(#"""
        {"contract":"fluxklang.graph","version":1,"id":"gph.main","revision":0,"nodes":[],"edges":[],
         "futureGraph":"keep"}
        """#.utf8)
        let decoded = try Support.read(project: projectBytes, graph: graphBytes)
        let contents = try make(
            project: decoded.project, graphs: [(Support.graphPath, try #require(decoded.graphs.first))]
        )
        let reread = try ProjectPackageDocuments(contents: contents)
        #expect(reread.project.unknownFields == ["futureProject": .object(["nested": .bool(true)])])
        #expect(reread.project.graphs.first?.unknownFields == ["futureReference": .array([.int(1), .int(2)])])
        #expect(reread.graphs.first?.unknownFields == ["futureGraph": .string("keep")])
        #expect(reread.project == decoded.project)
        #expect(reread.graphs == decoded.graphs)
    }

    /// A later graph the encoder rejects proves the loop stopped before encoding it.
    @Test func makeRefusesOversizeMembersBeforeEncodingLaterGraphs() throws {
        let later = GraphID(validated: "gph.later")
        var unencodable = Support.graph(later)
        unencodable.requiredFeatures = ["future.v9"]
        var big = Support.graph()
        big.label = String(repeating: "x", count: 3000)
        let project = Support.project(graphs: [Support.graphID, later])
        let graphs = [(path: Support.graphPath, document: big), (path: "graphs/later.json", document: unencodable)]
        #expect(throws: ProjectPackageDocumentError.unencodableGraph(later)) {
            try make(project: project, graphs: graphs)
        }
        #expect(throws: ProjectPackageDocumentError.package(.entryBytesExceeded)) {
            try make(project: project, graphs: graphs, policy: Support.policy(entryBytes: 2500))
        }
        let filler = [ProjectPackageFile(path: "fill.bin", role: .unlisted, bytes: Data(count: 3000))]
        #expect(throws: ProjectPackageDocumentError.package(.totalBytesExceeded)) {
            try make(project: project, graphs: graphs, extraFiles: filler, policy: Support.policy(totalBytes: 6000))
        }
        var bigProject = project
        bigProject.name = String(repeating: "p", count: 3000)
        #expect(throws: ProjectPackageDocumentError.package(.entryBytesExceeded)) {
            try make(project: bigProject, graphs: [graphs[1]], policy: Support.policy(entryBytes: 2500))
        }
    }

    @Test func makePrechecksExtraFileBytesBeforeEncoding() throws {
        var unencodable = Support.graph()
        unencodable.requiredFeatures = ["future.v9"]
        let graphs = [(path: Support.graphPath, document: unencodable)]
        let oversize = [ProjectPackageFile(path: "big.bin", role: .opaqueState, bytes: Data(count: 4097))]
        #expect(throws: ProjectPackageDocumentError.package(.entryBytesExceeded)) {
            try make(graphs: graphs, extraFiles: oversize)
        }
        let pair = ["a.bin", "b.bin"].map { ProjectPackageFile(path: $0, role: .unlisted, bytes: Data(count: 3500)) }
        #expect(throws: ProjectPackageDocumentError.package(.totalBytesExceeded)) {
            try make(graphs: graphs, extraFiles: pair, policy: Support.policy(totalBytes: 6000))
        }
    }

    @Test func swappedGraphMembersRefuse() throws {
        let second = GraphID(validated: "gph.aux")
        let contents = try make(
            project: Support.project(graphs: [Support.graphID, second]),
            graphs: [("graphs/main.json", Support.graph()), ("graphs/aux.json", Support.graph(second))]
        )
        var files: [String: Data] = [:]
        for file in contents.files { files[file.path] = file.bytes }
        let swappedBytes = try Support.graph(second).encoded()
        files["graphs/main.json"] = swappedBytes
        files["graphs/aux.json"] = try Support.graph().encoded()
        var manifest = contents.manifest
        manifest.graphs[0].member.byteCount = swappedBytes.count
        manifest.graphs[1].member.byteCount = files["graphs/aux.json"]?.count
        let swapped = try ProjectPackageContents(
            manifestBytes: manifest.encoded(policy: Support.policy()), directories: contents.directories,
            files: files, policy: Support.policy()
        )
        #expect(throws: ProjectPackageDocumentError.manifest(.graphMismatch)) {
            try ProjectPackageDocuments(contents: swapped)
        }
    }

    @Test func makeRefusesCollisionsRolesAndLimits() throws {
        func extra(_ path: String, _ role: ProjectPackageMemberRole = .unlisted) -> [ProjectPackageFile] {
            [ProjectPackageFile(path: path, role: role, bytes: Data([1]))]
        }
        for path in [Support.graphPath, "manifest.json", "graphs"] {
            #expect(throws: ProjectPackageDocumentError.package(.duplicatePath)) { try make(extraFiles: extra(path)) }
        }
        #expect(throws: ProjectPackageDocumentError.package(.parentNotDirectory)) {
            try make(extraFiles: extra("graphs", .opaqueState))
        }
        #expect(throws: ProjectPackageDocumentError.package(.invalidPath)) { try make(extraFiles: extra("../escape")) }
        #expect(throws: ProjectPackageDocumentError.unsupportedExtraRole) {
            let digest = "sha256:" + String(repeating: "0", count: 64)
            return try make(extraFiles: extra("media/a.wav", .media(contentDigest: digest)))
        }
        #expect(throws: ProjectPackageDocumentError.unsupportedExtraRole) {
            try make(extraFiles: extra("graphs/b.json", .graph(Support.graphID)))
        }
        #expect(throws: ProjectPackageDocumentError.package(.entryLimitExceeded)) {
            try make(extraFiles: extra("x.bin"), policy: Support.policy(entries: 3))
        }
        #expect(throws: ProjectPackageDocumentError.package(.totalBytesExceeded)) {
            try make(extraFiles: [ProjectPackageFile(
                path: "big.bin", role: .opaqueState, bytes: Data(count: 4000)
            )], policy: Support.policy(totalBytes: 4500))
        }
        #expect(throws: ProjectPackageDocumentError.manifest(.graphMismatch)) { try make(graphs: []) }
    }

    /// The dropped `missingMember`/`duplicateGraph` P4 cases stay refused by P2 and P3.
    @Test func redundantRefusalsStillHoldInP2AndP3() throws {
        #expect(throws: ProjectPackageDocumentError.manifest(.duplicateGraph)) {
            try make(graphs: [("graphs/a.json", Support.graph()), ("graphs/b.json", Support.graph())])
        }
        let contents = try make()
        let files = [Support.projectPath: try Support.validProjectBytes()]
        #expect(throws: ProjectPackageIOError.missingMember) {
            try ProjectPackageContents(
                manifestBytes: contents.manifestBytes, directories: contents.directories, files: files,
                policy: Support.policy()
            )
        }
    }
}
