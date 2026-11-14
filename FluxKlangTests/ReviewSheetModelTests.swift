//
//  ReviewSheetModelTests.swift
//  FluxKlangTests
//
//  The review-sheet model (#99 RV1): a value built from a wiring review diff, provenance, hazards, the stale state and
//  the activation phase, whose default action is the safe one unless every condition holds. This root file holds the
//  shared fixtures, the limits, the revision rules and the source scan; the rows, default-action and stale suites are
//  extensions. Nothing is activated and nothing is emitted: the model is read, never executed.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Review sheet model", .productionAccessAudit)
struct ReviewSheetModelTests {
    enum FixtureError: Error { case notStale }

    static let graphID = GraphID(validated: "gph.review")
    static let draftID = DraftID(validated: "dft.review")

    static func revision(_ value: Int) throws -> ContractRevision { try ContractRevision(value) }

    static func nodeID(_ raw: String) throws -> NodeID { try NodeID(raw) }

    static func stereo(_ raw: String, at column: Double) throws -> GraphNode {
        GraphNode(
            id: try nodeID(raw), kind: .plugin, label: raw,
            ports: [
                GraphPort(id: PortID(validated: "in"), direction: .input, signal: .audio, channels: 2),
                GraphPort(id: PortID(validated: "out"), direction: .output, signal: .audio, channels: 2)
            ],
            position: GraphPoint(x: column, y: 0)
        )
    }

    static func edge(_ raw: String, from: String, to: String) throws -> GraphEdge {
        GraphEdge(
            id: try EdgeID(raw), from: PortAddress(node: try nodeID(from), port: PortID(validated: "out")),
            to: PortAddress(node: try nodeID(to), port: PortID(validated: "in")), conversion: nil, feedback: nil
        )
    }

    /// nod.a, nod.b and nod.c (x 0, 1, 2) and the edge edg.ab from nod.a to nod.b, at `revision`.
    static func graph(revision value: Int = 0) throws -> GraphDocument {
        GraphDocument(
            id: graphID, revision: try revision(value),
            nodes: [try stereo("nod.a", at: 0), try stereo("nod.b", at: 1), try stereo("nod.c", at: 2)],
            edges: [try edge("edg.ab", from: "nod.a", to: "nod.b")]
        )
    }

    static func draft(_ edits: [GraphEdit], on graph: GraphDocument) -> DraftEdits {
        DraftEdits(id: draftID, graph: graph.id, baseRevision: graph.revision, edits: edits)
    }

    static func diff(_ edits: [GraphEdit], on graph: GraphDocument) throws -> WiringReviewDiff {
        try WiringReviewDiff.make(active: graph, draft: draft(edits, on: graph))
    }

    /// One change of each kind: add nod.z, move nod.a, remove nod.c, connect edg.ba, disconnect edg.ab.
    static func everyKindDiff() throws -> WiringReviewDiff {
        try diff(
            [
                .addNode(try stereo("nod.z", at: 9)), .moveNode(try nodeID("nod.a"), to: GraphPoint(x: 5, y: 5)),
                .removeNode(try nodeID("nod.c")), .connect(try edge("edg.ba", from: "nod.b", to: "nod.a")),
                .disconnect(try EdgeID("edg.ab"))
            ],
            on: try graph()
        )
    }

    /// `count` added nodes on an empty graph: `count` rows.
    static func addedNodesDiff(count: Int) throws -> WiringReviewDiff {
        let empty = GraphDocument(id: graphID)
        return try diff(try (0..<count).map { GraphEdit.addNode(try stereo("nod.n\($0)", at: Double($0))) }, on: empty)
    }

    static func emptyDiff() throws -> WiringReviewDiff { try diff([], on: try graph()) }

    static func hazard(_ id: String, _ summary: String = "summary", blocks: Bool = false) -> ReviewHazard {
        ReviewHazard(id: id, summary: summary, blocksActivation: blocks)
    }

    /// A review that activates by default: one change, human, no hazard, fresh, awaiting review, active rev 7.
    static func safeInput() throws -> ReviewSheetInput {
        ReviewSheetInput(
            diff: try addedNodesDiff(count: 1), provenance: .human, hazards: [], staleness: .fresh,
            phase: .awaitingReview, activeRevision: try revision(7)
        )
    }

    /// The stale report of a draft based on `base` against a graph at `active`.
    static func staleness(
        base: Int, active: Int, revalidate: ReviewRevalidation = .available
    ) throws -> ReviewStaleness {
        let draft = draft([], on: try graph(revision: base))
        guard let report = WiringStaleDraft.check(draft, active: try graph(revision: active)) else {
            throw FixtureError.notStale
        }
        return .stale(report, revalidate: revalidate)
    }

    static func model(_ input: ReviewSheetInput, limits: ReviewSheetLimits = .standard) throws -> ReviewSheetModel {
        try ReviewSheetModel.make(input, limits: limits)
    }

    static func refusal(of input: ReviewSheetInput, limits: ReviewSheetLimits = .standard) -> ReviewSheetRefusal? {
        do {
            _ = try ReviewSheetModel.make(input, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    static func permutations<Element>(_ items: [Element]) -> [[Element]] {
        guard let first = items.first else { return [[]] }
        let rest = permutations(Array(items.dropFirst()))
        return rest.flatMap { tail in
            (0...tail.count).map { index in
                var result = tail
                result.insert(first, at: index)
                return result
            }
        }
    }

    // MARK: Limits

    @Test func standardLimitsAre512RowsAnd64Hazards() {
        #expect(ReviewSheetLimits.standard.maximumRows == 512)
        #expect(ReviewSheetLimits.standard.maximumHazards == 64)
    }

    @Test func limitsAreBuiltAtTheLowestAndHighestBounds() throws {
        let lowest = try ReviewSheetLimits.make(maximumRows: 1, maximumHazards: 0)
        #expect(lowest.maximumRows == 1 && lowest.maximumHazards == 0)
        let highest = try ReviewSheetLimits.make(maximumRows: 512, maximumHazards: 64)
        #expect(highest == ReviewSheetLimits.standard)
    }

    @Test func limitsOutsideTheBoundsAreRefusedWithTheirValues() {
        #expect(throws: ReviewSheetRefusal.invalidLimits(rows: 0, hazards: 3)) {
            try ReviewSheetLimits.make(maximumRows: 0, maximumHazards: 3)
        }
        #expect(throws: ReviewSheetRefusal.invalidLimits(rows: 513, hazards: 5)) {
            try ReviewSheetLimits.make(maximumRows: 513, maximumHazards: 5)
        }
        #expect(throws: ReviewSheetRefusal.invalidLimits(rows: 4, hazards: -1)) {
            try ReviewSheetLimits.make(maximumRows: 4, maximumHazards: -1)
        }
        #expect(throws: ReviewSheetRefusal.invalidLimits(rows: 6, hazards: 65)) {
            try ReviewSheetLimits.make(maximumRows: 6, maximumHazards: 65)
        }
    }

    // MARK: Provenance

    @Test func provenanceBadgesAndTheExtraConfirmationFlagAreExact() {
        #expect(ReviewProvenance.human.badgeText == "Made by you")
        #expect(ReviewProvenance.controller.badgeText == "Made from a controller")
        #expect(ReviewProvenance.assistant.badgeText == "Suggested by the assistant")
        #expect(ReviewProvenance.allCases.filter(\.needsExtraConfirmation) == [.assistant])
    }

    @Test func aModelAnswersWithTheProvenanceAndPhaseItWasGiven() throws {
        var input = try Self.safeInput()
        input.provenance = .controller
        input.phase = .committing
        let built = try Self.model(input)
        #expect(built.provenance == .controller && built.phase == .committing)
        #expect(!built.needsExtraConfirmation)
        input.provenance = .assistant
        #expect(try Self.model(input).needsExtraConfirmation)
    }

    // MARK: Revision

    @Test func aRevisionBelowTheMaximumCreatesTheNextRevision() throws {
        var input = try Self.safeInput()
        #expect(try Self.model(input).creates == Self.revision(8))
        input.activeRevision = try Self.revision(ContractRevision.maximumValue - 1)
        let built = try Self.model(input)
        #expect(built.creates == (try Self.revision(ContractRevision.maximumValue)))
    }

    @Test func theMaximumRevisionIsRefusedForANonEmptyDiff() throws {
        var input = try Self.safeInput()
        input.activeRevision = try Self.revision(ContractRevision.maximumValue)
        #expect(Self.refusal(of: input) == .revisionOverflow)
    }

    @Test func theMaximumRevisionIsRefusedForAnEmptyDiffAndOneBelowIsAccepted() throws {
        var input = try Self.safeInput()
        input.diff = try Self.emptyDiff()
        input.activeRevision = try Self.revision(ContractRevision.maximumValue)
        #expect(Self.refusal(of: input) == .revisionOverflow)
        input.activeRevision = try Self.revision(ContractRevision.maximumValue - 1)
        let built = try Self.model(input)
        #expect(built.rows.isEmpty && built.creates == nil)
    }

    // MARK: Sources

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = ["../Shared/Views/Workspace/Review", "../../Sources/FluxKlang/Shared/Views/Workspace/Review"]
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("ReviewSheetModel.swift").path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    private static let forbiddenWords: Set<String> = [
        "SwiftUI", "AppKit", "UIKit", "Combine", "AppModel", "Published", "ObservableObject", "Observable",
        "ActivationRequest", "Date", "UUID", "ContinuousClock", "SuspendingClock", "DispatchQueue",
        "SystemRandomNumberGenerator", "FoundationModels", "escaping"
    ]

    private static func words(in text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init)
    }

    @Test(.enabled(if: sourcesAreReachable))
    func theReviewSourcesImportNothingAndNameNoUIClockRandomOrActivationRequestSymbol() throws {
        let directory = try #require(Self.sourceDirectory())
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        #expect(names.count == 5)
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
            let found = Set(Self.words(in: code)).intersection(Self.forbiddenWords)
            #expect(found.isEmpty, "\(name) names \(found.sorted())")
            #expect(!code.contains("import "), "\(name) imports a module")
        }
    }
}
