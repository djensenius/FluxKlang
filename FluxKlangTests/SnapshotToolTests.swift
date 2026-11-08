import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Tests of the read-only snapshot tools (#118, slice AT1). Fixtures live here; the topic files extend this suite.
struct SnapshotToolTests {
    typealias Snapshot = NeutralSnapshot
    typealias Page = SnapshotToolPage

    // MARK: - Fixtures

    static func pad(_ number: Int) -> String {
        let text = String(number)
        return String(repeating: "0", count: max(0, 3 - text.count)) + text
    }

    static func graphNode(_ id: String, label: String) throws -> GraphNode {
        try GraphNode(
            id: NodeID(id), kind: .plugin, label: label,
            ports: ["port.in", "port.out"].map {
                try GraphPort(id: PortID($0), direction: .input, signal: .audio, label: "Port \($0)")
            }
        )
    }

    static func graphEdge(_ number: Int) throws -> GraphEdge {
        try GraphEdge(
            id: EdgeID("edge." + pad(number)),
            from: PortAddress(node: NodeID("node.000"), port: PortID("port.out")),
            to: PortAddress(node: NodeID("node.001"), port: PortID("port.in"))
        )
    }

    static func descriptor(_ id: String, node: NodeID?) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: ParameterID(id), node: node, unit: .decibels, lower: -90, upper: 10, defaultValue: 0, ceiling: nil,
            curve: .linear, ramp: .step, controlClass: .live, verification: .unverified
        ))
    }

    /// Route `number` has availability `Snapshot.RouteAvailability.allCases[number % 5]`.
    static func routeInput(_ number: Int) throws -> Snapshot.RouteInput {
        let configurations: [(RouteBinding, DevicePresence?)] = [
            (.confirmed, .present), (.proposed, .present), (.stale, .present), (.confirmed, .missing),
            (.confirmed, nil)
        ]
        let (binding, presence) = configurations[number % 5]
        let route = try AudioRoute(
            id: RouteID("rte." + pad(number)), role: RoleID("role." + pad(number)), device: DeviceID("dev.interface-b"),
            direction: .output, channels: [0, 1], binding: binding
        )
        return Snapshot.RouteInput(route: route, presence: presence)
    }

    /// Diagnostic `number` has severity `[error, warning, info][number % 3]`.
    static func diagnosticRecord(_ number: Int) throws -> NeutralDiagnosticRecord {
        let severities: [DiagnosticSeverity] = [.error, .warning, .info]
        let subjects: [DiagnosticSubject?] = [
            .node(id: NodeID(validated: "node.000")),
            .port(node: NodeID(validated: "node.000"), port: PortID(validated: "port.out")),
            nil,
            .route(id: RouteID(validated: "rte.000"))
        ]
        return try NeutralDiagnosticRecord(
            id: DiagnosticID("dgn." + pad(number)), severity: severities[number % 3], summary: "Summary " + pad(number),
            subject: subjects[number % 4]
        )
    }

    /// Nodes `node.000...`, edges `edge.000...` from `node.000/port.out` to `node.001/port.in`, parameters
    /// `par.000...` (even numbers attach to `node.000`), routes and diagnostics as above, all in sorted order.
    static func inputs(
        nodes: Int = 3, edges: Int = 2, parameters: Int = 2, routes: Int = 5, diagnostics: Int = 6,
        label: (Int) -> String = { "Node " + String($0) }
    ) throws -> Snapshot.Inputs {
        let graph = try GraphDocument(
            id: GraphID(validated: "graph.main"), revision: ContractRevision(3), label: "Main",
            nodes: (0..<nodes).map { try graphNode("node." + pad($0), label: label($0)) },
            edges: (0..<edges).map { try graphEdge($0) }
        )
        return try Snapshot.Inputs(
            graph: graph,
            parameters: (0..<parameters).map {
                try descriptor("par." + pad($0), node: $0 % 2 == 0 ? NodeID("node.000") : nil)
            },
            routes: (0..<routes).map { try routeInput($0) },
            diagnostics: (0..<diagnostics).map { try diagnosticRecord($0) }
        )
    }

    static func snapshot(
        nodes: Int = 3, edges: Int = 2, parameters: Int = 2, routes: Int = 5, diagnostics: Int = 6,
        limits: Snapshot.Limits = Snapshot.Limits()
    ) throws -> Snapshot {
        Snapshot.build(
            from: try inputs(nodes: nodes, edges: edges, parameters: parameters, routes: routes,
                             diagnostics: diagnostics),
            limits: limits
        )
    }

    static func shuffled(_ inputs: Snapshot.Inputs) -> Snapshot.Inputs {
        let graph = GraphDocument(
            id: inputs.graph.id, revision: inputs.graph.revision, label: inputs.graph.label,
            nodes: inputs.graph.nodes.reversed().map { node in
                var node = node
                node.ports.reverse()
                return node
            },
            edges: inputs.graph.edges.reversed()
        )
        return Snapshot.Inputs(
            graph: graph, parameters: inputs.parameters.reversed(), routes: inputs.routes.reversed(),
            diagnostics: inputs.diagnostics.reversed(), project: inputs.project
        )
    }

    static let firstPage = Page(offset: 0, limit: 64)

    static func run(
        _ request: SnapshotToolRequest, _ snapshot: Snapshot, limits: SnapshotToolLimits = .standard
    ) throws -> SnapshotToolResult {
        try SnapshotToolCatalog.run(request, on: snapshot, limits: limits)
    }

    /// The refusal of a run, or `nil` when it answered.
    static func refusal(
        _ request: SnapshotToolRequest, _ snapshot: Snapshot, limits: SnapshotToolLimits = .standard
    ) -> SnapshotToolRefusal? {
        do {
            _ = try SnapshotToolCatalog.run(request, on: snapshot, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    static func ids(_ result: SnapshotToolResult) -> [String] {
        result.items.map { item in
            switch item {
            case .nodeSummary(let summary): summary.id.rawValue
            case .node(let node): node.id.rawValue
            case .edge(let edge): edge.id.rawValue
            case .parameter(let parameter): parameter.id.rawValue
            case .route(let route): route.id.rawValue
            case .diagnostic(let diagnostic): diagnostic.id.rawValue
            }
        }
    }

    /// One request per tool, each answering on `snapshot(...)` with the default fixture.
    static let everyTool: [SnapshotToolRequest] = [
        .listNodes(firstPage), .node(id: "node.000"), .edges(node: "node.000", port: "port.out", page: firstPage),
        .parameter(id: "par.000"), .routes(availability: nil, page: firstPage),
        .diagnostics(severity: .error, page: firstPage)
    ]

    // MARK: - Determinism and purity

    @Test func runningTheSameRequestTwiceOnTheSameSnapshotGivesEqualResultsForEveryTool() throws {
        let snapshot = try Self.snapshot()
        for request in Self.everyTool {
            #expect(try Self.run(request, snapshot) == Self.run(request, snapshot), "\(request)")
        }
    }

    @Test func snapshotsBuiltFromReversedInputsGiveEqualResultsForEveryTool() throws {
        let inputs = try Self.inputs()
        let straight = Snapshot.build(from: inputs)
        let reversed = Snapshot.build(from: Self.shuffled(inputs))
        #expect(straight == reversed)
        for request in Self.everyTool {
            #expect(try Self.run(request, straight) == Self.run(request, reversed), "\(request)")
        }
    }

    /// Limits outside the bounds cannot be built by any public path, so the refusal for them is reached only by
    /// reinterpreting two `Int`s; the layout is checked first so a reordered or resized type fails loudly.
    static func forgedLimits(bytes: Int, limit: Int) -> SnapshotToolLimits {
        #expect(MemoryLayout<SnapshotToolLimits>.size == 2 * MemoryLayout<Int>.size)
        #expect(MemoryLayout<SnapshotToolLimits>.offset(of: \.maximumBytes) == 0)
        #expect(MemoryLayout<SnapshotToolLimits>.offset(of: \.maximumPageLimit) == MemoryLayout<Int>.size)
        return unsafeBitCast((bytes, limit), to: SnapshotToolLimits.self)
    }

    @Test func aResultKeepsTheSnapshotsOwnLabelValuesWithTheirTruncationAndSanitizingFlags() throws {
        let hostile = "Mixer\u{7}\u{202E} with a long name past eight"
        let snapshot = Snapshot.build(
            from: try Self.inputs(nodes: 2, label: { _ in hostile }),
            limits: Snapshot.Limits(labelBytes: 8)
        )
        let node = try #require(snapshot.nodes.first)
        #expect(node.label.isTruncated)
        let summary = try Self.run(.listNodes(Self.firstPage), snapshot)
        guard case .nodeSummary(let listed)? = summary.items.first else {
            Issue.record("the first item is not a node summary")
            return
        }
        #expect(listed.label == node.label)
        let detail = try Self.run(.node(id: "node.000"), snapshot)
        guard case .node(let whole)? = detail.items.first else {
            Issue.record("the first item is not a node")
            return
        }
        #expect(whole == node)
    }

    // MARK: - Source scan

    /// Words the new sources must not contain. The list lives only here, outside the scanned directory.
    static let forbiddenWords = [
        "Command", "CommandIntent", "DraftEdits", "ActivationRequest", "hardware", "FoundationModels",
        "Shared/Assistant"
    ]

    static func toolSourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = ["../Shared/Diagnostics/Tools", "../../Sources/FluxKlang/Shared/Diagnostics/Tools"]
        let marker = "SnapshotToolCatalog.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    static let sourcesAreReachable = toolSourceDirectory() != nil

    /// The forbidden words found in `text`, plus `import` for any import line other than Foundation.
    static func findings(in text: String) -> [String] {
        var found = forbiddenWords.filter { text.lowercased().contains($0.lowercased()) }
        let imports = text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("import ") }
        if imports.contains(where: { $0 != "import Foundation" }) { found.append("import") }
        return found
    }

    @Test func theScannerFlagsEachForbiddenWordAndAnyNonFoundationImportAndNothingElse() {
        for word in Self.forbiddenWords {
            #expect(Self.findings(in: "let x = \(word)Thing").contains(word), "\(word)")
        }
        #expect(Self.findings(in: "let x = Hardware") == ["hardware"])
        #expect(Self.findings(in: "import Foundation\nlet x = 1") == [])
        #expect(Self.findings(in: "import Foundation\nimport CoreMIDI") == ["import"])
        #expect(Self.findings(in: "import FoundationModels") == ["FoundationModels", "import"])
    }

    @Test(.enabled(if: Self.sourcesAreReachable, "the tool sources are not next to the tests"))
    func theFiveToolSourceFilesNameNoForbiddenWordAndImportOnlyFoundation() throws {
        let directory = try #require(Self.toolSourceDirectory())
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        #expect(files == [
            "AssistantEligibility.swift", "SnapshotToolCatalog.swift", "SnapshotToolRefusal.swift",
            "SnapshotToolRequest.swift", "SnapshotToolResult.swift"
        ])
        for file in files {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            #expect(Self.findings(in: text) == [], "\(file)")
        }
    }
}
