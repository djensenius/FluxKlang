import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SnapshotToolTests {
    static let aByte = "a"

    /// A well formed id of exactly `bytes` ASCII bytes.
    static func asciiID(bytes: Int) -> String {
        "n" + String(repeating: aByte, count: bytes - 1)
    }

    /// One request per identifier argument: the request and the field its failure names.
    static func identifierRequests(_ text: String) -> [(SnapshotToolRequest, SnapshotToolRefusal.Field)] {
        [
            (.node(id: text), .nodeID),
            (.parameter(id: text), .parameterID),
            (.edges(node: text, port: "port.out", page: firstPage), .nodeID),
            (.edges(node: "node.000", port: text, page: firstPage), .portID)
        ]
    }

    // MARK: - Identifiers

    @Test func anIdentifierOf128AsciiBytesIsWellFormedAndOneOf129BytesIsInvalidForEveryArgument() throws {
        let snapshot = try Self.snapshot()
        for (request, _) in Self.identifierRequests(Self.asciiID(bytes: 128)) {
            #expect(Self.refusal(request, snapshot) == .notFound, "\(request)")
        }
        for (request, field) in Self.identifierRequests(Self.asciiID(bytes: 129)) {
            #expect(Self.refusal(request, snapshot) == .invalidIdentifier(field), "\(request)")
        }
    }

    @Test func anEmptyIdentifierIsInvalidForEveryArgumentAndOneByteIsWellFormed() throws {
        let snapshot = try Self.snapshot()
        for (request, field) in Self.identifierRequests("") {
            #expect(Self.refusal(request, snapshot) == .invalidIdentifier(field), "\(request)")
        }
        for (request, _) in Self.identifierRequests("n") {
            #expect(Self.refusal(request, snapshot) == .notFound, "\(request)")
        }
    }

    @Test func identifiersWithMultiByteCharactersAreInvalidWhetherShortOrOverlongInBytes() throws {
        let snapshot = try Self.snapshot()
        let samples = [
            "caf\u{E9}", String(repeating: "\u{20AC}", count: 43), String(repeating: "\u{E9}", count: 64),
            String(repeating: "\u{E9}", count: 65), String(repeating: "\u{1F3B9}", count: 33), "node.000\u{1F3B9}"
        ]
        for sample in samples {
            for (request, field) in Self.identifierRequests(sample) {
                #expect(Self.refusal(request, snapshot) == .invalidIdentifier(field), "\(sample.utf8.count) bytes")
            }
        }
        #expect(String(repeating: "\u{20AC}", count: 43).utf8.count == 129)
        #expect(String(repeating: "\u{E9}", count: 64).utf8.count == 128)
    }

    @Test func identifiersWithIllegalOrCombiningCharactersAreInvalidForEveryArgument() throws {
        let snapshot = try Self.snapshot()
        let samples = [
            "node 000", "node/000", "node.000\n", "\nnode.000", "node.000\r\n", "node\u{0}000", "node,000",
            "node.000\u{301}", "n\u{301}ode.000", "node\u{FF0E}000", "node.000 "
        ]
        for sample in samples {
            for (request, field) in Self.identifierRequests(sample) {
                #expect(Self.refusal(request, snapshot) == .invalidIdentifier(field), "\(sample.unicodeScalars.count)")
            }
        }
    }

    @Test func everyLegalIdentifierCharacterIsAcceptedAsWellFormed() throws {
        let snapshot = try Self.snapshot()
        let sample = "Az09._:-"
        for (request, _) in Self.identifierRequests(sample) {
            #expect(Self.refusal(request, snapshot) == .notFound, "\(request)")
        }
    }

    @Test func anIdentifierThatIsOnlyAPrefixOrAnExtensionOrAnotherCaseOfAnExistingOneIsNotFound() throws {
        let snapshot = try Self.snapshot()
        for text in ["node", "node.", "node.00", "node.0000", "node.000.", "NODE.000", "Node.000"] {
            #expect(Self.refusal(.node(id: text), snapshot) == .notFound, "\(text)")
        }
        for text in ["par", "par.00", "par.0000", "PAR.000"] {
            #expect(Self.refusal(.parameter(id: text), snapshot) == .notFound, "\(text)")
        }
        #expect(Self.refusal(.edges(node: "node.00", port: "port.out", page: Self.firstPage), snapshot) == .notFound)
        #expect(Self.refusal(.edges(node: "node.000", port: "port.o", page: Self.firstPage), snapshot) == .notFound)
    }

    @Test func aPortOfAnotherNodeOrAnUnknownNodeIsNotFoundForEdges() throws {
        let snapshot = try Self.snapshot()
        let unknownNode = SnapshotToolRequest.edges(node: "node.009", port: "port.out", page: Self.firstPage)
        let unknownPort = SnapshotToolRequest.edges(node: "node.000", port: "port.side", page: Self.firstPage)
        #expect(Self.refusal(unknownNode, snapshot) == .notFound)
        #expect(Self.refusal(unknownPort, snapshot) == .notFound)
        #expect(Self.refusal(.edges(node: "node.000", port: "port.out", page: Self.firstPage), snapshot) == nil)
    }

    // MARK: - Page limit

    static func pagedRequests(_ page: Page, severity: DiagnosticSeverity = .error) -> [SnapshotToolRequest] {
        [
            .listNodes(page), .edges(node: "node.000", port: "port.out", page: page),
            .routes(availability: nil, page: page), .diagnostics(severity: severity, page: page)
        ]
    }

    @Test func aPageLimitFromOneToSixtyFourIsAcceptedAndZeroOrSixtyFiveIsRefusedForEveryPagedTool() throws {
        let snapshot = try Self.snapshot()
        for limit in [1, 2, 63, 64] {
            for request in Self.pagedRequests(Page(offset: 0, limit: limit)) {
                #expect(Self.refusal(request, snapshot) == nil, "\(request)")
            }
        }
        for limit in [0, 65, -1, 1_000, Int.max, Int.min] {
            for request in Self.pagedRequests(Page(offset: 0, limit: limit)) {
                #expect(Self.refusal(request, snapshot) == .limitOutOfRange(limit), "\(request)")
            }
        }
    }

    @Test func theLargestPageLimitFollowsTheToolLimitsAtNAndNPlusOne() throws {
        let snapshot = try Self.snapshot()
        let limits = try SnapshotToolLimits.make(maximumBytes: 16_384, maximumPageLimit: 5)
        for request in Self.pagedRequests(Page(offset: 0, limit: 5)) {
            #expect(Self.refusal(request, snapshot, limits: limits) == nil, "\(request)")
        }
        for request in Self.pagedRequests(Page(offset: 0, limit: 6)) {
            #expect(Self.refusal(request, snapshot, limits: limits) == .limitOutOfRange(6), "\(request)")
        }
    }

    // MARK: - Page offset per category

    /// The snapshot caps each category at `cap`; the tool's offset bound is that cap.
    static func cappedSnapshot(cap: Int) throws -> Snapshot {
        try snapshot(
            nodes: cap + 2, edges: cap + 2, parameters: 1, routes: cap + 2, diagnostics: cap + 2,
            limits: Snapshot.Limits(nodes: cap, edges: cap, routes: cap, diagnostics: cap)
        )
    }

    @Test func anOffsetUpToTheSnapshotCapOfTheCategoryIsAcceptedAndOneMoreIsRefusedForEveryPagedTool() throws {
        let snapshot = try Self.cappedSnapshot(cap: 4)
        for request in Self.pagedRequests(Page(offset: 4, limit: 1), severity: .error) {
            #expect(Self.refusal(request, snapshot) == nil, "\(request)")
        }
        for request in Self.pagedRequests(Page(offset: 5, limit: 1)) {
            #expect(Self.refusal(request, snapshot) == .pageOutOfRange(5), "\(request)")
        }
    }

    @Test func eachPagedToolUsesTheCapOfItsOwnCategoryForTheOffsetBound() throws {
        let snapshot = try Snapshot.build(
            from: Self.inputs(nodes: 3, edges: 3, routes: 3, diagnostics: 3),
            limits: Snapshot.Limits(nodes: 1, edges: 2, routes: 3, diagnostics: 4)
        )
        let caps: [(SnapshotToolRequest, Int)] = [
            (.listNodes(Page(offset: 1, limit: 1)), 1),
            (.edges(node: "node.000", port: "port.out", page: Page(offset: 2, limit: 1)), 2),
            (.routes(availability: nil, page: Page(offset: 3, limit: 1)), 3),
            (.diagnostics(severity: .error, page: Page(offset: 4, limit: 1)), 4)
        ]
        for (request, _) in caps {
            #expect(Self.refusal(request, snapshot) == nil, "\(request)")
        }
        let beyond: [SnapshotToolRequest] = [
            .listNodes(Page(offset: 2, limit: 1)),
            .edges(node: "node.000", port: "port.out", page: Page(offset: 3, limit: 1)),
            .routes(availability: nil, page: Page(offset: 4, limit: 1)),
            .diagnostics(severity: .error, page: Page(offset: 5, limit: 1))
        ]
        let offsets = [2, 3, 4, 5]
        for (request, offset) in zip(beyond, offsets) {
            #expect(Self.refusal(request, snapshot) == .pageOutOfRange(offset), "\(request)")
        }
    }

    @Test func aNegativeOrHugeOffsetIsRefusedWithTheValueGivenForEveryPagedTool() throws {
        let snapshot = try Self.snapshot()
        for offset in [-1, Int.min, Int.max, 1_000_000] {
            for request in Self.pagedRequests(Page(offset: offset, limit: 1)) {
                #expect(Self.refusal(request, snapshot) == .pageOutOfRange(offset), "\(request)")
            }
        }
    }

    @Test func aSnapshotCappedAtZeroOrBelowAcceptsOnlyOffsetZeroAndAnswersAnEmptyPage() throws {
        for cap in [0, -3] {
            let snapshot = try Self.snapshot(
                limits: Snapshot.Limits(nodes: cap, edges: cap, routes: cap, diagnostics: cap)
            )
            let empty = try Self.run(.listNodes(Page(offset: 0, limit: 1)), snapshot)
            #expect(empty.matched == 0 && empty.returned == 0 && empty.items.isEmpty)
            #expect(Self.refusal(.listNodes(Page(offset: 1, limit: 1)), snapshot) == .pageOutOfRange(1))
            #expect(Self.refusal(.routes(availability: nil, page: Page(offset: 1, limit: 1)), snapshot)
                == .pageOutOfRange(1))
        }
    }

    // MARK: - Tool limits

    @Test func toolLimitsAreBuiltForTheLowestAndHighestValuesAndRefuseOneBelowAndOneAbove() throws {
        _ = try SnapshotToolLimits.make(maximumBytes: 1, maximumPageLimit: 1)
        let highest = try SnapshotToolLimits.make(maximumBytes: 16_384, maximumPageLimit: 64)
        #expect(highest == .standard)
        let cases = [(0, 64), (16_385, 64), (16_384, 0), (16_384, 65), (-1, -1)]
        for (bytes, limit) in cases {
            do {
                _ = try SnapshotToolLimits.make(maximumBytes: bytes, maximumPageLimit: limit)
                Issue.record("limits \(bytes)/\(limit) were accepted")
            } catch {
                #expect(error == .invalidToolLimits(maximumBytes: bytes, maximumPageLimit: limit))
            }
        }
    }

    @Test func limitsForgedOutsideTheirBoundsAreRefusedAtThePointOfUseForEveryTool() throws {
        let snapshot = try Self.snapshot()
        let forged = [(0, 64), (16_385, 64), (16_384, 0), (16_384, 65)]
        for (bytes, limit) in forged {
            let limits = Self.forgedLimits(bytes: bytes, limit: limit)
            for request in Self.everyTool {
                #expect(
                    Self.refusal(request, snapshot, limits: limits)
                        == .invalidToolLimits(maximumBytes: bytes, maximumPageLimit: limit),
                    "\(request)"
                )
            }
        }
    }

    // MARK: - Order of refusals (each fixture holds both defects)

    @Test func invalidToolLimitsAreReportedBeforeAnInvalidIdentifierAndBeforeAnOutOfRangePage() throws {
        let snapshot = try Self.snapshot()
        let forged = Self.forgedLimits(bytes: 0, limit: 64)
        let request = SnapshotToolRequest.edges(node: "", port: "", page: Page(offset: -1, limit: 0))
        #expect(Self.refusal(request, snapshot, limits: forged)
            == .invalidToolLimits(maximumBytes: 0, maximumPageLimit: 64))
    }

    @Test func anInvalidNodeIdentifierIsReportedBeforeAnInvalidPortIdentifier() throws {
        let snapshot = try Self.snapshot()
        let request = SnapshotToolRequest.edges(node: "bad node", port: "bad port", page: Self.firstPage)
        #expect(Self.refusal(request, snapshot) == .invalidIdentifier(.nodeID))
    }

    @Test func anInvalidIdentifierIsReportedBeforeAnOutOfRangePageLimitAndOffset() throws {
        let snapshot = try Self.snapshot()
        let badPage = Page(offset: -1, limit: 0)
        #expect(Self.refusal(.edges(node: "node.000", port: "bad port", page: badPage), snapshot)
            == .invalidIdentifier(.portID))
        #expect(Self.refusal(.edges(node: "bad node", port: "port.out", page: badPage), snapshot)
            == .invalidIdentifier(.nodeID))
    }

    @Test func anOutOfRangePageLimitIsReportedBeforeAnOutOfRangePageOffset() throws {
        let snapshot = try Self.snapshot()
        let badPage = Page(offset: -1, limit: 65)
        for request in Self.pagedRequests(badPage) {
            #expect(Self.refusal(request, snapshot) == .limitOutOfRange(65), "\(request)")
        }
    }

    @Test func anOutOfRangePageOffsetIsReportedBeforeAnUnknownIdentifier() throws {
        let snapshot = try Self.snapshot()
        let request = SnapshotToolRequest.edges(
            node: "node.999", port: "port.out", page: Page(offset: 99_999, limit: 1)
        )
        #expect(Self.refusal(request, snapshot) == .pageOutOfRange(99_999))
    }

    // MARK: - Request equality

    private static let composed = "n\u{e9}"
    private static let decomposed = "ne\u{301}"

    @Test func requestsWhoseTextDiffersOnlyByCanonicalEquivalenceAreNotEqualInEveryTextArgument() {
        #expect(Self.composed == Self.decomposed, "the fixture must be a canonically equivalent pair")
        #expect(Self.composed.utf8.elementsEqual(Self.decomposed.utf8) == false)
        let page = Self.firstPage
        #expect(SnapshotToolRequest.node(id: Self.composed) != .node(id: Self.decomposed))
        #expect(SnapshotToolRequest.parameter(id: Self.composed) != .parameter(id: Self.decomposed))
        #expect(SnapshotToolRequest.edges(node: Self.composed, port: "p", page: page)
            != .edges(node: Self.decomposed, port: "p", page: page))
        #expect(SnapshotToolRequest.edges(node: "n", port: Self.composed, page: page)
            != .edges(node: "n", port: Self.decomposed, page: page))
    }

    @Test func requestsWithEqualBytesAndPagesAreEqualAndAnyOtherDifferenceMakesThemUnequal() {
        let page = Page(offset: 2, limit: 3)
        let otherPage = Page(offset: 2, limit: 4)
        #expect(SnapshotToolRequest.node(id: "node.000") == .node(id: "node.000"))
        #expect(SnapshotToolRequest.parameter(id: "par.000") == .parameter(id: "par.000"))
        #expect(SnapshotToolRequest.edges(node: "a", port: "b", page: page) == .edges(node: "a", port: "b", page: page))
        #expect(SnapshotToolRequest.edges(node: "a", port: "b", page: page)
            != .edges(node: "a", port: "b", page: otherPage))
        #expect(SnapshotToolRequest.edges(node: "a", port: "b", page: page)
            != .edges(node: "b", port: "a", page: page))
        #expect(SnapshotToolRequest.node(id: "x") != .parameter(id: "x"))
        #expect(SnapshotToolRequest.listNodes(page) == .listNodes(Page(offset: 2, limit: 3)))
        #expect(SnapshotToolRequest.listNodes(page) != .listNodes(otherPage))
        #expect(SnapshotToolRequest.routes(availability: nil, page: page) == .routes(availability: nil, page: page))
        #expect(SnapshotToolRequest.routes(availability: nil, page: page)
            != .routes(availability: nil, page: otherPage))
        #expect(SnapshotToolRequest.diagnostics(severity: .error, page: page)
            == .diagnostics(severity: .error, page: page))
        #expect(SnapshotToolRequest.diagnostics(severity: .error, page: page)
            != .diagnostics(severity: .warning, page: page))
        let otherOffset = Page(offset: 3, limit: 3)
        #expect(SnapshotToolRequest.listNodes(page) != .listNodes(otherOffset))
        #expect(SnapshotToolRequest.edges(node: "a", port: "b", page: page)
            != .edges(node: "a", port: "b", page: otherOffset))
        #expect(SnapshotToolRequest.routes(availability: .stale, page: page)
            != .routes(availability: .stale, page: otherOffset))
        #expect(SnapshotToolRequest.routes(availability: .stale, page: page)
            != .routes(availability: .stale, page: otherPage))
        #expect(SnapshotToolRequest.diagnostics(severity: .error, page: page)
            != .diagnostics(severity: .error, page: otherOffset))
        #expect(SnapshotToolRequest.diagnostics(severity: .error, page: page)
            != .diagnostics(severity: .error, page: otherPage))
        #expect(SnapshotToolRequest.routes(availability: .available, page: page)
            == .routes(availability: .available, page: Page(offset: 2, limit: 3)))
        #expect(SnapshotToolRequest.routes(availability: .available, page: page)
            != .routes(availability: .stale, page: page))
        #expect(SnapshotToolRequest.routes(availability: .available, page: page)
            != .routes(availability: .unconfirmed, page: page))
        #expect(SnapshotToolRequest.routes(availability: nil, page: page)
            != .routes(availability: .available, page: page))
        #expect(SnapshotToolRequest.node(id: "node.000") != .node(id: "node.001"))
        #expect(SnapshotToolRequest.parameter(id: "par.000") != .parameter(id: "par.001"))
        #expect(SnapshotToolRequest.edges(node: "node.000", port: "p", page: page)
            != .edges(node: "node.001", port: "p", page: page))
        #expect(SnapshotToolRequest.edges(node: "n", port: "port.0", page: page)
            != .edges(node: "n", port: "port.1", page: page))
    }
}
