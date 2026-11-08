import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ExplainGroundingTests {
    static let heldReferences = ["node:node.000", "parameter:par.000", "route:rte.000", "diagnostic:dgn.000"]
    static let euro = "\u{20AC}"

    // MARK: - What is accepted and what is absent

    @Test func aWellFormedCitationOfEachKindTheSnapshotHoldsIsAcceptedAloneAndTogether() throws {
        let snapshot = try Self.fixtureSnapshot()
        for reference in Self.heldReferences {
            #expect(Self.refusal("Explained.", [reference], snapshot) == nil, "\(reference)")
        }
        #expect(Self.refusal("Explained.", Self.heldReferences, snapshot) == nil)
        let others = ["node:node.002", "parameter:par.003", "route:rte.004", "diagnostic:dgn.007"]
        #expect(Self.refusal("Explained.", others, snapshot) == nil)
    }

    @Test func aCitationOfAnotherKindThanTheIdBelongsToIsUnknownEvenThoughTheSnapshotHoldsThatId() throws {
        let snapshot = try Self.fixtureSnapshot()
        let wrongKind = [
            "node:rte.000", "node:par.000", "node:dgn.000", "parameter:node.000", "parameter:rte.000",
            "parameter:dgn.000", "route:node.000", "route:par.000", "route:dgn.000", "diagnostic:node.000",
            "diagnostic:par.000", "diagnostic:rte.000"
        ]
        for reference in wrongKind {
            #expect(Self.refusal("Explained.", [reference], snapshot) == .unknownCitation(reference), "\(reference)")
        }
    }

    @Test func anIdThatIsOnlyAPrefixAnExtensionOrAnotherCaseOfAnExistingOneIsUnknown() throws {
        let snapshot = try Self.fixtureSnapshot()
        let near = ["node:node.00", "node:node.0000", "node:NODE.000", "node:node.000:extra", "route:rte.00",
                    "parameter:PAR.000", "diagnostic:dgn.0000"]
        for reference in near {
            #expect(Self.refusal("Explained.", [reference], snapshot) == .unknownCitation(reference), "\(reference)")
        }
    }

    @Test func aSnapshotWithNothingInItRefusesACitationOfEachKindAsUnknown() throws {
        let graph = try GraphDocument(
            id: GraphID(validated: "graph.main"), revision: ContractRevision(1), label: "Empty", nodes: [], edges: []
        )
        let empty = Snapshot.build(from: Snapshot.Inputs(graph: graph))
        for reference in Self.heldReferences {
            #expect(Self.refusal("Explained.", [reference], empty) == .unknownCitation(reference), "\(reference)")
        }
    }

    @Test func aTruncatedSnapshotRefusesAnIdItDroppedLikeAnyAbsentIdAndAcceptsOneItKept() throws {
        let snapshot = try Self.fixtureSnapshot(limits: Snapshot.Limits(nodes: 2, routes: 3, diagnostics: 4))
        #expect(snapshot.truncation.isTruncated)
        #expect(Self.refusal("Explained.", ["node:node.001"], snapshot) == nil)
        #expect(Self.refusal("Explained.", ["node:node.002"], snapshot) == .unknownCitation("node:node.002"))
        #expect(Self.refusal("Explained.", ["route:rte.004"], snapshot) == .unknownCitation("route:rte.004"))
        #expect(Self.refusal("Explained.", ["diagnostic:dgn.007"], snapshot) == .unknownCitation("diagnostic:dgn.007"))
    }

    @Test func idsWrittenInsideTheTextAreNeverReadAndOnlyTheCitedListDecides() throws {
        let snapshot = try Self.fixtureSnapshot()
        #expect(Self.refusal("See node:ghost and route:ghost.", ["node:node.000"], snapshot) == nil)
        #expect(Self.refusal("Only node:node.000.", ["route:ghost"], snapshot) == .unknownCitation("route:ghost"))
    }

    // MARK: - Malformed citations

    @Test func aCitationWithoutAKnownKindAColonAndAValidIdIsMalformedAndReportedAsGiven() throws {
        let snapshot = try Self.fixtureSnapshot()
        let malformed = [
            "", "node.000", "node", "Node:node.000", "nodes:node.000", ":node.000", "node:", "node:node 000",
            "node:\u{e9}", "node\u{301}:node.000", "node:e\u{301}", "route :rte.000", "edge:edge.000",
            "port:port.out", "nodes:node.000", "parameters:par.000", "routes:rte.000", "diagnostics:dgn.000",
            "node:node.000\n", "parameter:", "route:", "diagnostic:", "diagnostic:dgn/000"
        ]
        for reference in malformed {
            #expect(Self.refusal("Explained.", [reference], snapshot) == .malformedCitation(reference), "\(reference)")
        }
    }

    @Test func anIdOf128BytesIsWellFormedAndOneOf129BytesIsMalformedForEveryKind() throws {
        let snapshot = try Self.fixtureSnapshot()
        for kind in ["node", "parameter", "route", "diagnostic"] {
            let longest = kind + ":" + String(repeating: "a", count: 128)
            let tooLong = kind + ":" + String(repeating: "a", count: 129)
            #expect(Self.refusal("Explained.", [longest], snapshot) == .unknownCitation(longest), "\(kind)")
            #expect(Self.refusal("Explained.", [tooLong], snapshot) == .malformedCitation(tooLong), "\(kind)")
            #expect(Self.refusal("Explained.", [kind + ":a"], snapshot) == .unknownCitation(kind + ":a"), "\(kind)")
        }
    }

    @Test func theSmallestMalformedCitationByBytesIsReportedWhateverTheInputOrder() throws {
        let snapshot = try Self.fixtureSnapshot()
        let entries = ["zzz", "bad", "node:xa", "Bad", "route:ghost"]
        #expect(Self.refusal("Explained.", entries, snapshot) == .malformedCitation("Bad"))
        #expect(Self.refusal("Explained.", entries.reversed(), snapshot) == .malformedCitation("Bad"))
        let composed = "node:\u{e9}"
        let decomposed = "node:e\u{301}"
        #expect(Self.refusal("Explained.", [composed, decomposed], snapshot) == .malformedCitation(decomposed))
        #expect(Self.refusal("Explained.", [decomposed, composed], snapshot) == .malformedCitation(decomposed))
    }

    @Test func theSmallestUnknownIdIsReportedWhateverTheInputOrderAndKnownIdsAreSkipped() throws {
        let snapshot = try Self.fixtureSnapshot()
        let entries = ["node:node.000", "route:zz", "node:xb", "route:rte.000", "parameter:xa", "node:xa"]
        let rotations = (0..<entries.count).map { Array(entries[$0...] + entries[..<$0]) }
        for order in rotations + rotations.map({ Array($0.reversed()) }) {
            #expect(Self.refusal("Explained.", order, snapshot) == .unknownCitation("node:xa"), "\(order)")
        }
    }

    @Test func theSameIdInTwoKindsIsOrderedNodeThenParameterThenRouteThenDiagnostic() throws {
        let snapshot = try Self.fixtureSnapshot()
        let orders = [["diagnostic:q", "route:q", "parameter:q", "node:q"], ["route:q", "node:q", "diagnostic:q"]]
        for order in orders {
            #expect(Self.refusal("Explained.", order, snapshot) == .unknownCitation("node:q"), "\(order)")
        }
        #expect(Self.refusal("Explained.", ["diagnostic:q", "route:q", "parameter:q"], snapshot)
                == .unknownCitation("parameter:q"))
        #expect(Self.refusal("Explained.", ["diagnostic:q", "route:q"], snapshot) == .unknownCitation("route:q"))
        #expect(Self.refusal("Explained.", ["route:q", "diagnostic:q"], snapshot) == .unknownCitation("route:q"))
    }

    // MARK: - Bounds of the text and the list

    @Test func aTextOf16384BytesIsAcceptedAndOneOf16385IsRefusedWithItsByteCountThoughFarFewerCharacters() throws {
        let snapshot = try Self.fixtureSnapshot()
        let fits = String(repeating: Self.euro, count: 5_461) + "a"
        #expect(fits.utf8.count == 16_384)
        #expect(fits.count == 5_462)
        #expect(Self.refusal(fits, ["node:node.000"], snapshot) == nil)
        let over = fits + "a"
        #expect(over.utf8.count == 16_385)
        #expect(Self.refusal(over, ["node:node.000"], snapshot) == .textTooLong(16_385))
        let wide = String(repeating: Self.euro, count: 5_462)
        #expect(wide.count == 5_462)
        #expect(Self.refusal(wide, ["node:node.000"], snapshot) == .textTooLong(16_386))
    }

    @Test func theTextLimitInTheGivenLimitsAppliesAtNAndNPlusOneBytes() throws {
        let snapshot = try Self.fixtureSnapshot()
        let ten = try Self.limits(text: 10)
        #expect(Self.refusal(Self.euro + Self.euro + Self.euro + "a", ["node:node.000"], snapshot, limits: ten) == nil)
        #expect(Self.refusal(Self.euro + Self.euro + Self.euro + "aa", ["node:node.000"], snapshot, limits: ten)
                == .textTooLong(11))
        let one = try Self.limits(text: 1)
        #expect(Self.refusal("a", ["node:node.000"], snapshot, limits: one) == nil)
        #expect(Self.refusal("ab", ["node:node.000"], snapshot, limits: one) == .textTooLong(2))
    }

    @Test func sixtyFourCitationsAreAcceptedAndSixtyFiveAreRefusedWithTheirCount() throws {
        let snapshot = try Self.fixtureSnapshot()
        let sixtyFour = Array(repeating: "node:node.000", count: 64)
        #expect(Self.refusal("Explained.", sixtyFour, snapshot) == nil)
        #expect(Self.refusal("Explained.", sixtyFour + ["node:node.000"], snapshot) == .tooManyCitations(65))
        #expect(Self.refusal("Explained.", Array(repeating: "node:node.000", count: 1_000), snapshot)
                == .tooManyCitations(1_000))
    }

    @Test func theCitationLimitInTheGivenLimitsAppliesAtNAndNPlusOneEntries() throws {
        let snapshot = try Self.fixtureSnapshot()
        let two = try Self.limits(citations: 2)
        #expect(Self.refusal("Explained.", ["node:node.000", "route:rte.000"], snapshot, limits: two) == nil)
        #expect(Self.refusal("Explained.", Array(Self.heldReferences.prefix(3)), snapshot, limits: two)
                == .tooManyCitations(3))
        let one = try Self.limits(citations: 1)
        #expect(Self.refusal("Explained.", ["node:node.000"], snapshot, limits: one) == nil)
        #expect(Self.refusal("Explained.", ["node:node.000", "node:node.000"], snapshot, limits: one)
                == .tooManyCitations(2))
    }

    @Test func emptyTextIsRefusedAndAOneByteTextIsAccepted() throws {
        let snapshot = try Self.fixtureSnapshot()
        #expect(Self.refusal("", ["node:node.000"], snapshot) == .emptyText)
        #expect(Self.refusal("a", ["node:node.000"], snapshot) == nil)
    }

    @Test func noCitationsAreRefusedForNonEmptyTextAndOneCitationIsAccepted() throws {
        let snapshot = try Self.fixtureSnapshot()
        #expect(Self.refusal("Explained.", [], snapshot) == .noCitations)
        #expect(Self.refusal("Explained.", ["node:node.000"], snapshot) == nil)
    }

    // MARK: - Citation values

    @Test func eachCitationKindRoundTripsThroughItsReferenceAndSortsByKindThenIdBytes() throws {
        let citations: [ExplanationCitation] = try [
            .node(NodeID("n")), .parameter(ParameterID("p")), .route(RouteID("r")), .diagnostic(DiagnosticID("d"))
        ]
        #expect(citations.map(\.reference) == ["node:n", "parameter:p", "route:r", "diagnostic:d"])
        #expect(citations.map { ExplanationCitation.parse($0.reference) } == citations.map { Optional($0) })
        #expect(citations.map(\.kindName) == ["node", "parameter", "route", "diagnostic"])
        #expect(citations.map(\.identifier) == ["n", "p", "r", "d"])
        #expect(citations.reversed().sorted() == citations)
        let nodes: [ExplanationCitation] = try ["b", "A", "a", "a-b", "a.b"].map { .node(try NodeID($0)) }
        #expect(nodes.sorted().map(\.identifier) == ["A", "a", "a-b", "a.b", "b"])
        #expect(ExplanationCitation.node(try NodeID("x")) != .route(try RouteID("x")))
        #expect(ExplanationCitation.route(try RouteID("x")) < .diagnostic(try DiagnosticID("a")))
    }
}
