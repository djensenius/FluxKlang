import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Hand-written legacy StudioGraph/StudioEndpoint wire bytes and package policies for adoption tests.
enum LegacyAdoptionP5Fixture {
    static let projectID = ProjectID(validated: "prj.adopted")
    static let graphID = GraphID(validated: "gph.legacy")
    static let synth = "11111111-1111-1111-1111-111111111111"
    static let instrument = "22222222-2222-2222-2222-222222222222"
    static let mains = "33333333-3333-3333-3333-333333333333"
    /// Sorts before `room`'s endpoint so document order differs from `RoleID` order.
    static let mainsEndpoint = "BBBBBBBB-0000-0000-0000-000000000001"
    static let room = "44444444-4444-4444-4444-444444444444"
    static let roomEndpoint = "AAAAAAAA-0000-0000-0000-000000000002"
    static let console = "55555555-5555-5555-5555-555555555555"

    static func policy(entries: Int = 32, entryBytes: Int = 65_536, totalBytes: Int = 262_144) throws
        -> ProjectPackageManifestPolicy {
        try ProjectPackageManifestPolicy(
            packageLimits: ProjectPackageLimits(
                maxEntries: entries, maxDepth: 8, maxPathUTF8Bytes: 256,
                maxEntryBytes: entryBytes, maxTotalBytes: totalBytes
            ),
            maxManifestBytes: min(4096, entryBytes)
        )
    }

    static func node(_ id: String, _ kind: String, _ title: String) -> String {
        #"{"id":"\#(id)","kind":\#(kind),"title":"\#(title)","position":[1.5,-2]}"#
    }

    static func instrumentKind(_ reference: String) -> String { #"{"instrument":{"_0":"\#(reference)"}}"# }
    static func endpointKind(_ reference: String) -> String { #"{"endpoint":{"_0":"\#(reference)"}}"# }

    static func edge(_ id: String, from: String, _ fromPort: Int, to: String, _ toPort: Int) -> String {
        #"{"id":"\#(id)","from":{"nodeID":"\#(from)","side":"output","port":\#(fromPort)},"#
            + #""to":{"nodeID":"\#(to)","side":"input","port":\#(toPort)}}"#
    }

    static func graph(nodes: [String], edges: [String] = []) -> Data {
        Data(#"{"nodes":[\#(nodes.joined(separator: ","))],"edges":[\#(edges.joined(separator: ","))]}"#.utf8)
    }

    /// Synth (instrument) feeds Mains (endpoint) and Room (space endpoint); a console shortcut is inert.
    /// Odd spacing, key order, escapes and number spellings must survive byte-for-byte.
    static let standardGraph = Data(("{ \"edges\" : [" + [
        edge("66666666-6666-6666-6666-666666666661", from: synth, 0, to: mains, 0),
        edge("66666666-6666-6666-6666-666666666662", from: synth, 1, to: room, 1)
    ].joined(separator: ",\n ") + "],\n \"nodes\":[" + [
        node(synth, instrumentKind(instrument), "Synth \\u00e9"),
        node(mains, endpointKind(mainsEndpoint), "Mains"),
        node(room, endpointKind(roomEndpoint), "Room"),
        node(console, #"{"liveChannel":{"_0":{"members":[{"channel":7}]}}}"#, "Console")
    ].joined(separator: ",") + "], \"futureLegacy\": 1.50e0 }\n").utf8)

    static let standardEndpoints = Data((
        #"[{"id":"\#(mainsEndpoint)","name":"Mains","destination":"mains","colorName":"red"},"#
            + #" {"destination":"space","id":"\#(roomEndpoint)","name":"Room","extra":[1,null]}]"#
    ).utf8)

    static func role(_ name: String, _ uuid: String) -> RoleID {
        RoleID(rawValue: "legacy.\(name).\(uuid)")!
    }

    static func adopt(
        graph: Data = standardGraph, endpoints: Data? = standardEndpoints, policy: ProjectPackageManifestPolicy? = nil
    ) throws -> LegacyAdoptionResult {
        try LegacyAdoption.adopt(
            graphData: graph, endpointsData: endpoints, projectID: projectID, graphID: graphID,
            name: "Adopted", policy: policy ?? self.policy()
        )
    }

    static func refusal(
        graph: Data = standardGraph, endpoints: Data? = standardEndpoints, policy: ProjectPackageManifestPolicy? = nil
    ) throws -> LegacyAdoptionRefusal? {
        let policy = try policy ?? self.policy()
        do {
            _ = try LegacyAdoption.adopt(
                graphData: graph, endpointsData: endpoints, projectID: projectID, graphID: graphID,
                name: "Adopted", policy: policy
            )
            return nil
        } catch {
            return error
        }
    }

    /// `body` padded with trailing JSON whitespace to exactly `count` bytes.
    static func padded(_ body: String, to count: Int) -> Data {
        var data = Data(body.utf8)
        data.append(contentsOf: [UInt8](repeating: 0x20, count: count - data.count))
        return data
    }

    static func bytes(at path: String, in contents: ProjectPackageContents) -> Data? {
        contents.files.first { $0.path == path }?.bytes
    }
}

@Suite("Legacy project adoption")
struct ProjectLegacyAdoptionTests {
    private typealias Fixture = LegacyAdoptionP5Fixture

    @Test func adoptedPackageDecodesAndOnlyReviewGatesValidation() throws {
        let result = try Fixture.adopt()
        // Re-decode from the package's own bytes, independently of the result's documents.
        let documents = try ProjectPackageDocuments(contents: result.contents)
        #expect(documents == result.documents)
        #expect(documents.graphs.map(\.id) == [Fixture.graphID])
        #expect(documents.project.graphs == [ProjectGraphReference(graph: Fixture.graphID, revision: .initial)])
        let errors = documents.project.validationErrors(graphs: documents.graphs)
        #expect(errors.contains(.graph(Fixture.graphID, .reviewRequired)))
        // Only the review gate and the unconfirmed channel counts remain: no missing role, role mismatch
        // or unsupplied graph.
        for error in errors {
            switch error {
            case .invalidRoleChannels(let role): #expect(result.unconfirmedChannelRoles.contains(role))
            case .graph(Fixture.graphID, .reviewRequired), .graph(Fixture.graphID, .invalidChannelCount): break
            default: Issue.record("unexpected validation error \(error)")
            }
        }
        // A reviewer confirming counts and clearing review is all that stands between this and validity.
        var project = documents.project, graph = try #require(documents.graphs.first)
        for index in project.roles.indices { project.roles[index].channels = 2 }
        for node in graph.nodes.indices {
            for port in graph.nodes[node].ports.indices { graph.nodes[node].ports[port].channels = 2 }
        }
        graph.requiresReview = false
        try project.validate(graphs: [graph])
    }

    @Test func emptyLegacyGraphFailsOnlyTheReviewGate() throws {
        let result = try Fixture.adopt(graph: Fixture.graph(nodes: []), endpoints: nil)
        let documents = try ProjectPackageDocuments(contents: result.contents)
        #expect(documents.project.roles.isEmpty)
        #expect(documents.project.validationErrors(graphs: documents.graphs)
            == [.graph(Fixture.graphID, .reviewRequired)])
    }

    @Test func originalBytesAreKeptExactlyAsOpaqueState() throws {
        let contents = try Fixture.adopt().contents
        #expect(Fixture.bytes(at: LegacyAdoption.originalGraphPath, in: contents) == Fixture.standardGraph)
        #expect(Fixture.bytes(at: LegacyAdoption.originalEndpointsPath, in: contents) == Fixture.standardEndpoints)
        #expect(contents.files.first { $0.path == LegacyAdoption.originalGraphPath }?.role == .opaqueState)
        #expect(contents.files.first { $0.path == LegacyAdoption.originalEndpointsPath }?.role == .opaqueState)
        #expect(contents.manifest.opaqueState == [
            ProjectPackageMember(path: "legacy/StudioGraph.json", byteCount: Fixture.standardGraph.count),
            ProjectPackageMember(path: "legacy/StudioEndpoints.json", byteCount: Fixture.standardEndpoints.count)
        ])
        #expect(contents.files.map(\.path) == [
            "graphs/legacy-studio.json", "legacy/StudioEndpoints.json", "legacy/StudioGraph.json", "project.json"
        ])
        #expect(contents.directories == ["graphs", "legacy"])
    }

    @Test func absentEndpointsAddNoEndpointsMember() throws {
        let mains = Fixture.node(Fixture.mains, Fixture.endpointKind(Fixture.mainsEndpoint), "M")
        let graph = Fixture.graph(nodes: [mains])
        let contents = try Fixture.adopt(graph: graph, endpoints: nil).contents
        #expect(contents.manifest.opaqueState == [
            ProjectPackageMember(path: LegacyAdoption.originalGraphPath, byteCount: graph.count)
        ])
        #expect(Fixture.bytes(at: LegacyAdoption.originalGraphPath, in: contents) == graph)
        #expect(Fixture.bytes(at: LegacyAdoption.originalEndpointsPath, in: contents) == nil)
    }

    @Test func versionedInputIsRefused() throws {
        let graph = try GraphDocument(id: Fixture.graphID).encoded()
        #expect(try Fixture.refusal(graph: graph, endpoints: nil) == .versionedInput)
        let project = try ProjectDocument(id: Fixture.projectID, name: "P").encoded()
        #expect(try Fixture.refusal(graph: project, endpoints: nil) == .versionedInput)
        let tagged = Data(#"{"nodes":[],"edges":[],"version":1}"#.utf8)
        #expect(try Fixture.refusal(graph: tagged, endpoints: nil) == .versionedInput)
        let contract = Data(#"{"nodes":[],"edges":[],"contract":"fluxklang.graph"}"#.utf8)
        #expect(try Fixture.refusal(graph: contract, endpoints: nil) == .versionedInput)
        let endpoints = Data(#"{"contract":"fluxklang.endpoints","version":1}"#.utf8)
        #expect(try Fixture.refusal(endpoints: endpoints) == .versionedInput)
        // Either member alone marks a versioned document.
        #expect(try Fixture.refusal(endpoints: Data(#"{"version":2}"#.utf8)) == .versionedInput)
        #expect(try Fixture.refusal(endpoints: Data(#"{"contract":"x"}"#.utf8)) == .versionedInput)
    }

    @Test func twoRunsGiveIdenticalBytes() throws {
        let first = try Fixture.adopt().contents
        let second = try Fixture.adopt().contents
        #expect(first.manifestBytes == second.manifestBytes)
        #expect(first.files == second.files)
        #expect(first.directories == second.directories)
        #expect(first == second)
    }

    @Test func provenanceBlockIsExactAndGrantsNothing() throws {
        let result = try Fixture.adopt()
        let project = result.documents.project
        #expect(project.extensions == ["provenance": .object([
            "source": .string("StudioGraph"), "authority": .string("invalidated"), "reviewRequired": .bool(true)
        ])])
        let bytes = try #require(Fixture.bytes(at: LegacyAdoption.projectPath, in: result.contents))
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text.contains(
            #""extensions":{"provenance":{"authority":"invalidated","reviewRequired":true,"source":"StudioGraph"}}"#
        ))
        #expect(result.documents.graphs.map(\.requiresReview) == [true])
        #expect(project.revision == .initial && project.name == "Adopted" && project.id == Fixture.projectID)
    }

    @Test func rolesFollowNodeDirectionsAndStayUnconfirmed() throws {
        let result = try Fixture.adopt()
        let input = Fixture.role("instrument", Fixture.instrument)
        let output = Fixture.role("endpoint", Fixture.mainsEndpoint)
        let spatial = Fixture.role("endpoint", Fixture.roomEndpoint)
        #expect(result.documents.project.roles == [
            ProjectRole(id: spatial, label: "Room", direction: .output, signal: .audio),
            ProjectRole(id: output, label: "Mains", direction: .output, signal: .audio),
            ProjectRole(id: input, label: "Synth \u{e9}", direction: .input, signal: .audio)
        ])
        #expect(result.unconfirmedChannelRoles == [spatial, output, input])
        let kinds = Dictionary(uniqueKeysWithValues: result.documents.graphs[0].nodes.compactMap { node in
            node.role.map { ($0, node.kind) }
        })
        #expect(kinds == [input: .roleInput, output: .roleOutput, spatial: .spatialBus])
    }

    @Test func rolesAreSortedByRoleID() throws {
        let endpoints = (0..<8).map { "\(7 - $0)AAAAAAA-0000-0000-0000-00000000000\($0)" }
        let nodes = endpoints.enumerated().map { index, endpoint in
            Fixture.node("CCCCCCCC-0000-0000-0000-00000000000\(index)", Fixture.endpointKind(endpoint), "E\(index)")
        }
        let result = try Fixture.adopt(graph: Fixture.graph(nodes: nodes), endpoints: nil)
        let ids = result.documents.project.roles.map(\.id)
        #expect(ids == endpoints.reversed().map { Fixture.role("endpoint", $0) })
        #expect(result.documents.project.roles.map(\.label) == (0..<8).reversed().map { "E\($0)" })
    }

    @Test func sharedEndpointYieldsOneRoleLabelledByFirstNode() throws {
        let nodes = [
            Fixture.node(Fixture.mains, Fixture.endpointKind(Fixture.mainsEndpoint), "First"),
            Fixture.node(Fixture.room, Fixture.endpointKind(Fixture.mainsEndpoint), "Second")
        ]
        let result = try Fixture.adopt(graph: Fixture.graph(nodes: nodes), endpoints: nil)
        #expect(result.documents.project.roles == [ProjectRole(
            id: Fixture.role("endpoint", Fixture.mainsEndpoint), label: "First", direction: .output, signal: .audio
        )])
        let documents = result.documents
        #expect(!documents.project.validationErrors(graphs: documents.graphs).contains {
            if case .duplicateRole = $0 { true } else { false }
        })
    }
}
