import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Tests of the grounded Explain baseline (#119, slice EX1). Fixtures live here; the topic files extend this suite.
@Suite(.productionAccessAudit)
struct ExplainGroundingTests {
    typealias Snapshot = NeutralSnapshot

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

    static func descriptor(_ id: String, node: String?, status: MeasurementStatus) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: ParameterID(id), node: node.map { try NodeID($0) }, unit: .decibels, lower: -90, upper: 10,
            defaultValue: 0, ceiling: nil, curve: .linear, ramp: .step, controlClass: .live, verification: status
        ))
    }

    /// Route `number` has availability `Snapshot.RouteAvailability.allCases[number % 5]`.
    static func routeInput(_ number: Int, device: String = "dev.interface-b") throws -> Snapshot.RouteInput {
        let configurations: [(RouteBinding, DevicePresence?)] = [
            (.confirmed, .present), (.proposed, .present), (.stale, .present), (.confirmed, .missing),
            (.confirmed, nil)
        ]
        let (binding, presence) = configurations[number % 5]
        let route = try AudioRoute(
            id: RouteID("rte." + pad(number)), role: RoleID("role." + pad(number)), device: DeviceID(device),
            direction: .output, channels: [0, 1], binding: binding
        )
        return Snapshot.RouteInput(route: route, presence: presence)
    }

    static func record(
        _ id: String, _ severity: DiagnosticSeverity, subject: DiagnosticSubject? = nil, summary: String = "Summary"
    ) throws -> NeutralDiagnosticRecord {
        try NeutralDiagnosticRecord(id: DiagnosticID(id), severity: severity, summary: summary, subject: subject)
    }

    static func diagnosticRecords(summary: String = "Summary") throws -> [NeutralDiagnosticRecord] {
        let node = NodeID(validated: "node.000")
        return try [
            record("dgn.000", .error, subject: .node(id: node), summary: summary),
            record("dgn.001", .warning, subject: .route(id: RouteID(validated: "rte.001")), summary: summary),
            record("dgn.002", .info, summary: summary),
            record("dgn.003", .error, subject: .parameter(id: ParameterID(validated: "par.000")), summary: summary),
            record("dgn.004", .warning, subject: .node(id: NodeID(validated: "node.gone")), summary: summary),
            record("dgn.005", .info, subject: .graph, summary: summary),
            record("dgn.006", .error, subject: .port(node: node, port: PortID(validated: "port.out")),
                   summary: summary),
            record("dgn.007", .warning, subject: .edge(id: EdgeID(validated: "edge.000")), summary: summary)
        ]
    }

    /// Three nodes, one edge, four parameters (measured, reported, unverified, reported on a node that is not in
    /// the graph), five routes (one of each availability) and eight diagnostics (two of them with no subject kept).
    static func fixtureInputs(label: String = "Node", summary: String = "Summary") throws -> Snapshot.Inputs {
        let graph = try GraphDocument(
            id: GraphID(validated: "graph.main"), revision: ContractRevision(3), label: label,
            nodes: (0..<3).map { try graphNode("node." + pad($0), label: label) },
            edges: [
                GraphEdge(
                    id: EdgeID("edge.000"),
                    from: PortAddress(node: NodeID("node.000"), port: PortID("port.out")),
                    to: PortAddress(node: NodeID("node.001"), port: PortID("port.in"))
                )
            ]
        )
        return try Snapshot.Inputs(
            graph: graph,
            parameters: [
                descriptor("par.000", node: "node.000", status: .measured),
                descriptor("par.001", node: nil, status: .reported),
                descriptor("par.002", node: "node.001", status: .unverified),
                descriptor("par.003", node: "node.gone", status: .reported)
            ],
            routes: (0..<5).map { try routeInput($0) },
            diagnostics: diagnosticRecords(summary: summary)
        )
    }

    static func fixtureSnapshot(limits: Snapshot.Limits = Snapshot.Limits()) throws -> Snapshot {
        Snapshot.build(from: try fixtureInputs(), limits: limits)
    }

    static func reversed(_ inputs: Snapshot.Inputs) -> Snapshot.Inputs {
        let graph = GraphDocument(
            id: inputs.graph.id, revision: inputs.graph.revision, label: inputs.graph.label,
            nodes: inputs.graph.nodes.reversed(), edges: inputs.graph.edges.reversed()
        )
        return Snapshot.Inputs(
            graph: graph, parameters: inputs.parameters.reversed(), routes: inputs.routes.reversed(),
            diagnostics: inputs.diagnostics.reversed(), project: inputs.project
        )
    }

    static func limits(facts: Int = 256, text: Int = 16_384, citations: Int = 64) throws -> ExplainLimits {
        try ExplainLimits.make(maximumFacts: facts, maximumTextBytes: text, maximumCitations: citations)
    }

    static func report(_ snapshot: Snapshot, limits: ExplainLimits = .standard) -> ExplanationReport {
        DiagnosticExplainer.facts(from: snapshot, limits: limits)
    }

    static func statements(_ report: ExplanationReport) -> [String] {
        report.facts.map(\.statement)
    }

    /// The refusal of a validation, or `nil` when it accepted.
    static func refusal(
        _ text: String, _ ids: [String], _ snapshot: Snapshot, limits: ExplainLimits = .standard
    ) -> ExplanationRefusal? {
        do {
            try ExplanationGrounding.validate(text: text, citedIDs: ids, against: snapshot, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    static func refusal(of build: () throws(ExplanationRefusal) -> ExplainLimits) -> ExplanationRefusal? {
        do {
            _ = try build()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Limits

    @Test func explainLimitsAreBuiltForTheLowestAndHighestValueOfEveryFieldAndStandardIsTheHighest() throws {
        let lowest = try Self.limits(facts: 1, text: 1, citations: 1)
        #expect(lowest.maximumFacts == 1)
        #expect(lowest.maximumTextBytes == 1)
        #expect(lowest.maximumCitations == 1)
        let highest = try Self.limits(facts: 256, text: 16_384, citations: 64)
        #expect(highest.maximumFacts == 256)
        #expect(highest.maximumTextBytes == 16_384)
        #expect(highest.maximumCitations == 64)
        #expect(ExplainLimits.standard == highest)
        #expect(lowest != highest)
    }

    struct LimitCase {
        let facts: Int
        let text: Int
        let citations: Int
        let expected: ExplanationRefusal
    }

    @Test func explainLimitsRefuseOneBelowAndOneAboveEachFieldNamingThatFieldAndValue() {
        let cases = [
            LimitCase(facts: 0, text: 8, citations: 8, expected: .limitOutOfRange(.maximumFacts, 0)),
            LimitCase(facts: 257, text: 8, citations: 8, expected: .limitOutOfRange(.maximumFacts, 257)),
            LimitCase(facts: -3, text: 8, citations: 8, expected: .limitOutOfRange(.maximumFacts, -3)),
            LimitCase(facts: 8, text: 0, citations: 8, expected: .limitOutOfRange(.maximumTextBytes, 0)),
            LimitCase(facts: 8, text: 16_385, citations: 8, expected: .limitOutOfRange(.maximumTextBytes, 16_385)),
            LimitCase(facts: 8, text: 8, citations: 0, expected: .limitOutOfRange(.maximumCitations, 0)),
            LimitCase(facts: 8, text: 8, citations: 65, expected: .limitOutOfRange(.maximumCitations, 65))
        ]
        for item in cases {
            let refused = Self.refusal { () throws(ExplanationRefusal) in
                try ExplainLimits.make(
                    maximumFacts: item.facts, maximumTextBytes: item.text, maximumCitations: item.citations
                )
            }
            #expect(refused == item.expected, "facts \(item.facts), text \(item.text), citations \(item.citations)")
        }
    }

    @Test func explainLimitsReportTheFactsFieldBeforeTheTextFieldBeforeTheCitationFieldWhenSeveralAreBad() {
        let allBad = Self.refusal { () throws(ExplanationRefusal) in
            try ExplainLimits.make(maximumFacts: 0, maximumTextBytes: 0, maximumCitations: 0)
        }
        #expect(allBad == .limitOutOfRange(.maximumFacts, 0))
        let textAndCitationsBad = Self.refusal { () throws(ExplanationRefusal) in
            try ExplainLimits.make(maximumFacts: 1, maximumTextBytes: 16_385, maximumCitations: 65)
        }
        #expect(textAndCitationsBad == .limitOutOfRange(.maximumTextBytes, 16_385))
        let citationsBad = Self.refusal { () throws(ExplanationRefusal) in
            try ExplainLimits.make(maximumFacts: 1, maximumTextBytes: 1, maximumCitations: 65)
        }
        #expect(citationsBad == .limitOutOfRange(.maximumCitations, 65))
    }

    // MARK: - Refusal equality

    @Test func refusalsWithTheSamePayloadShapeAndValueButADifferentCaseAreNotEqual() {
        let all: [ExplanationRefusal] = [
            .limitOutOfRange(.maximumFacts, 5), .limitOutOfRange(.maximumTextBytes, 5),
            .limitOutOfRange(.maximumCitations, 5), .textTooLong(5), .tooManyCitations(5), .emptyText, .noCitations,
            .malformedCitation("node:a"), .unknownCitation("node:a")
        ]
        for (leftIndex, left) in all.enumerated() {
            for (rightIndex, right) in all.enumerated() {
                #expect((left == right) == (leftIndex == rightIndex), "\(left) against \(right)")
            }
        }
        #expect(ExplanationRefusal.textTooLong(5) != .textTooLong(6))
        #expect(ExplanationRefusal.tooManyCitations(5) != .tooManyCitations(6))
        #expect(ExplanationRefusal.limitOutOfRange(.maximumFacts, 5) != .limitOutOfRange(.maximumFacts, 6))
    }

    @Test func refusalTextPayloadsDifferingOnlyByCanonicalEquivalenceAreNotEqual() {
        let composed = "node:\u{e9}"
        let decomposed = "node:e\u{301}"
        #expect(composed == decomposed)
        #expect(ExplanationRefusal.malformedCitation(composed) != .malformedCitation(decomposed))
        #expect(ExplanationRefusal.malformedCitation(composed) == .malformedCitation("node:\u{e9}"))
        #expect(ExplanationRefusal.unknownCitation(composed) != .unknownCitation(decomposed))
        #expect(ExplanationRefusal.unknownCitation(composed) == .unknownCitation("node:\u{e9}"))
        #expect(ExplanationRefusal.unknownCitation("node:a") != .unknownCitation("node:b"))
    }
}
