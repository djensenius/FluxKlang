import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ExplainGroundingTests {
    static let declaredTail = "): it has not been confirmed on a device."

    static func fact(_ report: ExplanationReport, citing first: ExplanationCitation) throws -> ExplanationFact {
        try #require(report.facts.first { $0.citations.first == first })
    }

    static func references(_ fact: ExplanationFact) -> [String] {
        fact.citations.map(\.reference)
    }

    // MARK: - Each fact kind

    @Test func theFixtureGivesTheSixteenStatementsInReportOrderWithNothingOmitted() throws {
        let snapshot = try Self.fixtureSnapshot()
        let report = Self.report(snapshot)
        let expected = [
            "Diagnostic dgn.000 (severity error): concerns node node.000.",
            "Diagnostic dgn.003 (severity error): concerns parameter par.000.",
            "Diagnostic dgn.006 (severity error): concerns a port of node node.000.",
            "Diagnostic dgn.001 (severity warning): concerns route rte.001.",
            "Diagnostic dgn.004 (severity warning): subject not in snapshot.",
            "Diagnostic dgn.007 (severity warning): concerns an edge.",
            "Route rte.001 is unavailable: availability unconfirmed, binding proposed, device presence present.",
            "Route rte.002 is unavailable: availability stale, binding stale, device presence present.",
            "Route rte.003 is unavailable: availability deviceMissing, binding confirmed, device presence missing.",
            "Route rte.004 is unavailable: availability deviceUnobserved, binding confirmed, "
                + "device presence unobserved.",
            "Diagnostic dgn.002 (severity info): no subject.",
            "Diagnostic dgn.005 (severity info): concerns the graph.",
            "Parameter par.001 is declared only (status reported" + Self.declaredTail,
            "Parameter par.002 on node node.001 is declared only (status unverified" + Self.declaredTail,
            "Parameter par.003 is declared only (status reported" + Self.declaredTail,
            "Parameter par.000 on node node.000 is measured."
        ]
        #expect(Self.statements(report) == expected)
        #expect(report.omitted == 0)
        #expect(report.snapshotTruncation == snapshot.truncation)
        let kinds = report.facts.map(\.kind)
        let diagnostic = ExplanationFact.Kind.diagnosticOpen
        let route = ExplanationFact.Kind.routeUnavailable
        let declared = ExplanationFact.Kind.declaredNotMeasured
        #expect(kinds == [diagnostic, diagnostic, diagnostic, diagnostic, diagnostic, diagnostic,
                          route, route, route, route, diagnostic, diagnostic,
                          declared, declared, declared, .measured])
    }

    @Test func aMeasuredParameterGivesAMeasuredFactCitingTheParameterThenItsNode() throws {
        let report = Self.report(try Self.fixtureSnapshot())
        let fact = try Self.fact(report, citing: .parameter(ParameterID(validated: "par.000")))
        #expect(fact.kind == .measured)
        #expect(fact.severity == nil)
        #expect(Self.references(fact) == ["parameter:par.000", "node:node.000"])
        #expect(fact.statement == "Parameter par.000 on node node.000 is measured.")
    }

    @Test func reportedAndUnverifiedParametersGiveDeclaredFactsWhoseStatementsNeverSayMeasured() throws {
        let report = Self.report(try Self.fixtureSnapshot())
        let declared = report.facts.filter { $0.kind == .declaredNotMeasured }
        #expect(declared.map { Self.references($0) } == [["parameter:par.001"], ["parameter:par.002", "node:node.001"],
                                                         ["parameter:par.003"]])
        for fact in declared {
            #expect(!fact.statement.lowercased().contains("measured"), "\(fact.statement)")
        }
        #expect(declared.filter { $0.statement.contains("status reported") }.count == 2)
        #expect(declared.filter { $0.statement.contains("status unverified") }.count == 1)
        #expect(report.facts.filter { $0.kind == .measured }.count == 1)
    }

    @Test func aParameterWithNoNodeOrWithANodeOutsideTheSnapshotCitesOnlyItself() throws {
        let report = Self.report(try Self.fixtureSnapshot())
        let noNode = try Self.fact(report, citing: .parameter(ParameterID(validated: "par.001")))
        #expect(Self.references(noNode) == ["parameter:par.001"])
        let goneNode = try Self.fact(report, citing: .parameter(ParameterID(validated: "par.003")))
        #expect(Self.references(goneNode) == ["parameter:par.003"])
        #expect(!goneNode.statement.contains("node.gone"))
        let capped = Self.report(try Self.fixtureSnapshot(limits: Snapshot.Limits(nodes: 1)))
        let dropped = try Self.fact(capped, citing: .parameter(ParameterID(validated: "par.002")))
        #expect(Self.references(dropped) == ["parameter:par.002"])
        #expect(!dropped.statement.contains("node.001"))
        let kept = try Self.fact(capped, citing: .parameter(ParameterID(validated: "par.000")))
        #expect(Self.references(kept) == ["parameter:par.000", "node:node.000"])
    }

    @Test func anAvailableRouteGivesNoFactAndEveryOtherAvailabilityGivesOneRouteFactCitingOnlyTheRoute() throws {
        let report = Self.report(try Self.fixtureSnapshot())
        let routes = report.facts.filter { $0.kind == .routeUnavailable }
        #expect(routes.map { Self.references($0) } == [["route:rte.001"], ["route:rte.002"], ["route:rte.003"],
                                                       ["route:rte.004"]])
        #expect(!report.facts.contains { $0.citations.contains(.route(RouteID(validated: "rte.000"))) })
        #expect(routes.allSatisfy { $0.severity == nil })
    }

    @Test func aRouteWithAWithheldDeviceSaysSoAndOneWithAnExposedDeviceDoesNot() throws {
        let graph = try Self.fixtureInputs().graph
        let inputs = try Snapshot.Inputs(
            graph: graph, routes: [Self.routeInput(1, device: "dev.9f3a00000"), Self.routeInput(2)]
        )
        let snapshot = Snapshot.build(from: inputs)
        #expect(snapshot.routes.map(\.isDeviceWithheld) == [true, false])
        let report = Self.report(snapshot)
        #expect(Self.statements(report) == [
            "Route rte.001 is unavailable: availability unconfirmed, binding proposed, device presence present. "
                + "Its device identity is withheld.",
            "Route rte.002 is unavailable: availability stale, binding stale, device presence present."
        ])
    }

    @Test func diagnosticsCiteTheirSubjectWhenTheSnapshotKeptItAndAPortCitesItsNode() throws {
        let report = Self.report(try Self.fixtureSnapshot())
        let byFirst = { (id: String) throws -> [String] in
            try Self.references(Self.fact(report, citing: .diagnostic(DiagnosticID(id))))
        }
        #expect(try byFirst("dgn.000") == ["diagnostic:dgn.000", "node:node.000"])
        #expect(try byFirst("dgn.001") == ["diagnostic:dgn.001", "route:rte.001"])
        #expect(try byFirst("dgn.003") == ["diagnostic:dgn.003", "parameter:par.000"])
        #expect(try byFirst("dgn.006") == ["diagnostic:dgn.006", "node:node.000"])
    }

    @Test func graphEdgeAndAbsentSubjectsAndNoSubjectCiteOnlyTheDiagnostic() throws {
        let report = Self.report(try Self.fixtureSnapshot())
        for id in ["dgn.002", "dgn.004", "dgn.005", "dgn.007"] {
            let fact = try Self.fact(report, citing: .diagnostic(DiagnosticID(id)))
            #expect(Self.references(fact) == ["diagnostic:" + id], "\(id)")
            #expect(fact.kind == .diagnosticOpen)
        }
        let absent = try Self.fact(report, citing: .diagnostic(DiagnosticID(validated: "dgn.004")))
        #expect(absent.statement == "Diagnostic dgn.004 (severity warning): subject not in snapshot.")
        #expect(!absent.statement.contains("node.gone"))
    }

    @Test func aDiagnosticWhoseSubjectWasCutByTheSnapshotLimitsCitesOnlyItselfAndSaysSo() throws {
        var inputs = try Self.fixtureInputs()
        inputs.diagnostics.append(try Self.record("dgn.008", .error, subject: .node(id: NodeID("node.002"))))
        let whole = Self.report(Snapshot.build(from: inputs))
        let id = ExplanationCitation.diagnostic(try DiagnosticID("dgn.008"))
        #expect(Self.references(try Self.fact(whole, citing: id)) == ["diagnostic:dgn.008", "node:node.002"])
        let cut = Snapshot.build(from: inputs, limits: Snapshot.Limits(nodes: 2))
        #expect(cut.node(try NodeID("node.002")) == nil)
        let fact = try Self.fact(Self.report(cut), citing: id)
        #expect(Self.references(fact) == ["diagnostic:dgn.008"])
        #expect(fact.statement == "Diagnostic dgn.008 (severity error): subject not in snapshot.")
    }

    @Test func diagnosticFactsCarryTheirSeverityAndTheStatementNamesIt() throws {
        let report = Self.report(try Self.fixtureSnapshot())
        let diagnostics = report.facts.filter { $0.kind == .diagnosticOpen }
        #expect(diagnostics.compactMap(\.severity) == [.error, .error, .error, .warning, .warning, .warning,
                                                       .info, .info])
        for fact in diagnostics {
            let name = try #require(fact.severity?.rawValue)
            #expect(fact.statement.contains("(severity " + name + ")"), "\(fact.statement)")
        }
    }

    // MARK: - Truncation and the cap

    @Test func anEmptySnapshotGivesNoFactsNothingOmittedAndNoTruncationFact() throws {
        let graph = try GraphDocument(
            id: GraphID(validated: "graph.main"), revision: ContractRevision(1), label: "Empty", nodes: [], edges: []
        )
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: graph))
        let report = Self.report(snapshot, limits: try Self.limits(facts: 1))
        #expect(report.facts.isEmpty)
        #expect(report.omitted == 0)
        #expect(report.snapshotTruncation == snapshot.truncation)
    }

    @Test func aSnapshotCutByItsLimitsGivesAFirstTruncationFactCitingNothingWithTheDroppedCounts() throws {
        let snapshot = try Self.fixtureSnapshot(limits: Snapshot.Limits(nodes: 2, routes: 3, diagnostics: 4))
        #expect(snapshot.truncation.isTruncated)
        let report = Self.report(snapshot)
        let first = try #require(report.facts.first)
        #expect(first.kind == .snapshotTruncated)
        #expect(first.citations.isEmpty)
        #expect(first.statement == "The snapshot is incomplete: dropped nodes 1, ports 2, edges 0, parameters 0, "
            + "routes 2, diagnostics 4; labels shortened 0, labels sanitized 0, withheld overflow 0. "
            + "An id missing from the snapshot may still exist in the setup.")
        #expect(report.facts.filter { $0.kind == .snapshotTruncated }.count == 1)
        #expect(report.snapshotTruncation == snapshot.truncation)
    }

    @Test func aSnapshotThatOnlyDroppedDuplicateDiagnosticsStillGetsATruncationFact() throws {
        var inputs = try Self.fixtureInputs()
        inputs.diagnostics = try [Self.record("dgn.000", .error), Self.record("dgn.000", .warning)]
        let snapshot = Snapshot.build(from: inputs)
        #expect(!snapshot.truncation.isTruncated)
        #expect(snapshot.truncation.diagnostics.dropped == 2)
        let first = try #require(Self.report(snapshot).facts.first)
        #expect(first.kind == .snapshotTruncated)
        #expect(first.statement.contains("diagnostics 2;"))
    }

    @Test func aSnapshotWithOnlyAShortenedLabelGetsATruncationFactAlthoughNothingWasDropped() throws {
        let snapshot = try Self.fixtureSnapshot(limits: Snapshot.Limits(labelBytes: 2))
        let truncation = snapshot.truncation
        #expect(truncation.isTruncated)
        #expect(truncation.truncatedLabels > 0)
        #expect([truncation.nodes, truncation.ports, truncation.edges, truncation.parameters, truncation.routes,
                 truncation.diagnostics].allSatisfy { $0.dropped == 0 })
        let first = try #require(Self.report(snapshot).facts.first)
        #expect(first.kind == .snapshotTruncated)
        #expect(first.statement.contains("labels shortened \(truncation.truncatedLabels),"))
        #expect(truncation.sanitizedLabels != truncation.truncatedLabels)
        #expect(first.statement.contains("labels sanitized \(truncation.sanitizedLabels),"))
    }

    @Test func aCompleteSnapshotGetsNoTruncationFactAndEveryReportCarriesTheSnapshotsOwnTruncationValue() throws {
        let complete = try Self.fixtureSnapshot()
        #expect(!Self.report(complete).facts.contains { $0.kind == .snapshotTruncated })
        let cut = try Self.fixtureSnapshot(limits: Snapshot.Limits(nodes: 1, parameters: 2))
        #expect(cut.truncation != complete.truncation)
        #expect(Self.report(complete).snapshotTruncation == complete.truncation)
        #expect(Self.report(cut).snapshotTruncation == cut.truncation)
    }

    @Test func twoHundredFiftySixFactsAreAllKeptAndTheTwoHundredFiftySeventhIsCountedAsOmitted() throws {
        let graph = try Self.fixtureInputs().graph
        func report(parameters: Int) throws -> ExplanationReport {
            let inputs = try Snapshot.Inputs(
                graph: graph,
                parameters: (0..<parameters).map {
                    try Self.descriptor("par." + Self.pad($0), node: nil, status: .measured)
                }
            )
            return Self.report(Snapshot.build(from: inputs))
        }
        let exact = try report(parameters: 256)
        #expect(exact.facts.count == 256)
        #expect(exact.omitted == 0)
        let over = try report(parameters: 257)
        #expect(over.facts.count == 256)
        #expect(over.omitted == 1)
        #expect(over.facts.last?.statement == "Parameter par.255 is measured.")
        #expect(Self.statements(over) == Self.statements(exact))
    }

    @Test func aSmallerCapKeepsTheMostUrgentFactsFirstAndCountsEveryOtherFactAsOmitted() throws {
        let snapshot = try Self.fixtureSnapshot()
        let all = Self.statements(Self.report(snapshot))
        #expect(all.count == 16)
        for cap in [1, 3, 8, 15, 16] {
            let report = Self.report(snapshot, limits: try Self.limits(facts: cap))
            #expect(Self.statements(report) == Array(all.prefix(cap)), "cap \(cap)")
            #expect(report.omitted == 16 - cap, "cap \(cap)")
        }
    }

    @Test func theTruncationFactSurvivesACapOfOneAndEveryOtherFactIsCountedAsOmitted() throws {
        let snapshot = try Self.fixtureSnapshot(limits: Snapshot.Limits(routes: 3))
        let all = Self.report(snapshot)
        let total = all.facts.count
        #expect(total > 1)
        let capped = Self.report(snapshot, limits: try Self.limits(facts: 1))
        #expect(capped.facts.map(\.kind) == [.snapshotTruncated])
        #expect(capped.omitted == total - 1)
        #expect(capped.facts == Array(all.facts.prefix(1)))
    }
}
