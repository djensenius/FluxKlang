import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SnapshotToolTests {
    static func fixedLabel(_ length: Int) -> (Int) -> String {
        { _ in String(repeating: "x", count: length) }
    }

    /// Node summaries of `nodes` nodes whose labels are `length` bytes: each item is `8 + length` bytes.
    static func labelledSnapshot(nodes: Int, length: Int, labelBytes: Int = 128) throws -> Snapshot {
        Snapshot.build(
            from: try inputs(nodes: nodes, label: fixedLabel(length)), limits: Snapshot.Limits(labelBytes: labelBytes)
        )
    }

    static func limits(bytes: Int, page: Int = 64) throws -> SnapshotToolLimits {
        try SnapshotToolLimits.make(maximumBytes: bytes, maximumPageLimit: page)
    }

    // MARK: - Listing and paging

    @Test func listNodesReturnsSummariesInIdOrderEvenWhenTheInputsWereReversed() throws {
        let snapshot = Snapshot.build(from: Self.shuffled(try Self.inputs()))
        let result = try Self.run(.listNodes(Self.firstPage), snapshot)
        #expect(Self.ids(result) == ["node.000", "node.001", "node.002"])
        guard case .nodeSummary(let first)? = result.items.first else {
            Issue.record("the first item is not a node summary")
            return
        }
        #expect(first.kind == .plugin && first.label.text == "Node 0" && first.role == nil && first.portCount == 2)
        #expect(result.tool == .listNodes && result.matched == 3 && result.returned == 3 && result.omitted == 0)
        #expect(result.offset == 0 && result.limit == 64 && result.trimmedByBytes == 0 && result.nextOffset == nil)
        #expect(result.bytes == 42)
    }

    @Test func pagingTenNodesByFourShowsEachPagesCountsAndWhereToContinue() throws {
        let snapshot = try Self.snapshot(nodes: 10)
        let first = try Self.run(.listNodes(Page(offset: 0, limit: 4)), snapshot)
        #expect(Self.ids(first) == ["node.000", "node.001", "node.002", "node.003"])
        #expect(first.matched == 10 && first.returned == 4 && first.omitted == 6 && first.nextOffset == 4)
        let second = try Self.run(.listNodes(Page(offset: 4, limit: 4)), snapshot)
        #expect(Self.ids(second) == ["node.004", "node.005", "node.006", "node.007"])
        #expect(second.matched == 10 && second.returned == 4 && second.omitted == 6 && second.nextOffset == 8)
        #expect(second.offset == 4 && second.limit == 4)
        let last = try Self.run(.listNodes(Page(offset: 8, limit: 4)), snapshot)
        #expect(Self.ids(last) == ["node.008", "node.009"])
        #expect(last.matched == 10 && last.returned == 2 && last.omitted == 8 && last.nextOffset == nil)
        #expect(last.trimmedByBytes == 0)
    }

    @Test func anOffsetAtOrBeyondTheEndOfTheDataGivesAnEmptyPageNotARefusal() throws {
        let snapshot = try Self.snapshot(nodes: 10)
        for offset in [10, 11, 512] {
            let result = try Self.run(.listNodes(Page(offset: offset, limit: 4)), snapshot)
            #expect(result.items.isEmpty && result.bytes == 0, "\(offset)")
            #expect(result.matched == 10 && result.returned == 0 && result.omitted == 10, "\(offset)")
            #expect(result.trimmedByBytes == 0 && result.nextOffset == nil, "\(offset)")
        }
    }

    @Test func aLimitOfOneAndALimitOfSixtyFourReturnExactlyThatManyOfSeventyNodes() throws {
        let snapshot = try Self.snapshot(nodes: 70)
        let one = try Self.run(.listNodes(Page(offset: 0, limit: 1)), snapshot)
        #expect(Self.ids(one) == ["node.000"] && one.omitted == 69 && one.nextOffset == 1)
        let most = try Self.run(.listNodes(Page(offset: 0, limit: 64)), snapshot)
        #expect(most.returned == 64 && most.omitted == 6 && most.nextOffset == 64 && most.matched == 70)
        #expect(Self.ids(most).last == "node.063")
        let rest = try Self.run(.listNodes(Page(offset: 64, limit: 64)), snapshot)
        #expect(Self.ids(rest) == ["node.064", "node.065", "node.066", "node.067", "node.068", "node.069"])
        #expect(rest.omitted == 64 && rest.nextOffset == nil)
    }

    // MARK: - The other tools

    @Test func nodeReturnsTheNodeWithItsPortsInIdOrderAndNothingForAnotherNode() throws {
        let snapshot = Snapshot.build(from: Self.shuffled(try Self.inputs()))
        let result = try Self.run(.node(id: "node.000"), snapshot)
        guard case .node(let node)? = result.items.first else {
            Issue.record("the first item is not a node")
            return
        }
        #expect(node == snapshot.nodes.first && node.id.rawValue == "node.000")
        #expect(node.ports.map(\.id.rawValue) == ["port.in", "port.out"])
        #expect(node.ports.map { $0.label?.text } == ["Port port.in", "Port port.out"])
        #expect(result.tool == .node && result.items.count == 1 && result.matched == 1 && result.returned == 1)
        #expect(result.omitted == 0 && result.offset == 0 && result.limit == 1 && result.nextOffset == nil)
        #expect(result.bytes == 54)
    }

    @Test func edgesListsEveryEdgeAtAPortFromEitherEndInEdgeIdOrder() throws {
        let snapshot = Snapshot.build(from: Self.shuffled(try Self.inputs(edges: 5)))
        let start = try Self.run(.edges(node: "node.000", port: "port.out", page: Self.firstPage), snapshot)
        let end = try Self.run(.edges(node: "node.001", port: "port.in", page: Self.firstPage), snapshot)
        let expected = ["edge.000", "edge.001", "edge.002", "edge.003", "edge.004"]
        #expect(Self.ids(start) == expected && Self.ids(end) == expected)
        #expect(start.tool == .edges && start.matched == 5 && start.omitted == 0 && start.bytes == 5 * 39)
        guard case .edge(let edge)? = start.items.first else {
            Issue.record("the first item is not an edge")
            return
        }
        let from = Snapshot.Endpoint(node: NodeID(validated: "node.000"), port: PortID(validated: "port.out"))
        #expect(edge.from == from)
        #expect(edge.to == Snapshot.Endpoint(node: NodeID(validated: "node.001"), port: PortID(validated: "port.in")))
        let tail = try Self.run(.edges(node: "node.000", port: "port.out", page: Page(offset: 3, limit: 5)), snapshot)
        #expect(Self.ids(tail) == ["edge.003", "edge.004"] && tail.matched == 5 && tail.omitted == 3)
        #expect(tail.nextOffset == nil)
    }

    @Test func aPortWithNoEdgesGivesAnEmptyResultNotNotFound() throws {
        let snapshot = try Self.snapshot(edges: 3)
        let result = try Self.run(.edges(node: "node.000", port: "port.in", page: Self.firstPage), snapshot)
        #expect(result.items.isEmpty && result.matched == 0 && result.returned == 0 && result.omitted == 0)
        #expect(result.nextOffset == nil)
    }

    @Test func parameterReturnsTheSnapshotsParameterWithItsNodeOrWithoutOne() throws {
        let snapshot = Snapshot.build(from: Self.shuffled(try Self.inputs()))
        let attached = try Self.run(.parameter(id: "par.000"), snapshot)
        let free = try Self.run(.parameter(id: "par.001"), snapshot)
        guard case .parameter(let first)? = attached.items.first, case .parameter(let second)? = free.items.first else {
            Issue.record("a parameter result holds no parameter")
            return
        }
        #expect(first == snapshot.parameter(ParameterID(validated: "par.000")))
        #expect(first.node == NodeID(validated: "node.000") && second.node == nil)
        #expect(first.unit == .decibels && first.lower == -90 && first.upper == 10 && first.defaultValue == 0)
        #expect(attached.tool == .parameter && attached.matched == 1 && attached.bytes == 15 && free.bytes == 7)
    }

    @Test func routesWithoutAFilterListEveryRouteAndEachAvailabilityKeepsOnlyItsOwnRoute() throws {
        let snapshot = Snapshot.build(from: Self.shuffled(try Self.inputs()))
        let all = try Self.run(.routes(availability: nil, page: Self.firstPage), snapshot)
        #expect(Self.ids(all) == ["rte.000", "rte.001", "rte.002", "rte.003", "rte.004"])
        #expect(all.tool == .routes && all.matched == 5 && all.bytes == 5 * 30)
        let owners: [(Snapshot.RouteAvailability, String)] = [
            (.available, "rte.000"), (.unconfirmed, "rte.001"), (.stale, "rte.002"), (.deviceMissing, "rte.003"),
            (.deviceUnobserved, "rte.004")
        ]
        for (availability, owner) in owners {
            let result = try Self.run(.routes(availability: availability, page: Self.firstPage), snapshot)
            #expect(Self.ids(result) == [owner] && result.matched == 1 && result.omitted == 0, "\(availability)")
        }
    }

    @Test func aRouteFilterCountsMatchesOverTheWholeCategoryBeforePaging() throws {
        let snapshot = try Self.snapshot(routes: 10)
        let page = try Self.run(.routes(availability: .stale, page: Page(offset: 1, limit: 1)), snapshot)
        #expect(Self.ids(page) == ["rte.007"] && page.matched == 2 && page.returned == 1 && page.omitted == 1)
        #expect(page.nextOffset == nil && page.offset == 1 && page.limit == 1)
        let first = try Self.run(.routes(availability: .stale, page: Page(offset: 0, limit: 1)), snapshot)
        #expect(Self.ids(first) == ["rte.002"] && first.omitted == 1 && first.nextOffset == 1)
    }

    @Test func diagnosticsKeepOnlyTheAskedSeverityInIdOrderWithTheirSubjects() throws {
        let snapshot = Snapshot.build(from: Self.shuffled(try Self.inputs()))
        let expected: [(DiagnosticSeverity, [String])] = [
            (.error, ["dgn.000", "dgn.003"]), (.warning, ["dgn.001", "dgn.004"]), (.info, ["dgn.002", "dgn.005"])
        ]
        let bytes = [26 + 25, 34 + 26, 18 + 34]
        for ((severity, ids), total) in zip(expected, bytes) {
            let result = try Self.run(.diagnostics(severity: severity, page: Self.firstPage), snapshot)
            #expect(Self.ids(result) == ids && result.matched == 2 && result.bytes == total, "\(severity)")
            #expect(result.tool == .diagnostics, "\(severity)")
        }
        let errors = try Self.run(.diagnostics(severity: .error, page: Self.firstPage), snapshot)
        guard case .diagnostic(let first)? = errors.items.first else {
            Issue.record("the first item is not a diagnostic")
            return
        }
        #expect(first == snapshot.diagnostics(severity: .error).first)
        #expect(first.summary.text == "Summary 000" && first.subject == .node(id: NodeID(validated: "node.000")))
        let page = try Self.run(.diagnostics(severity: .error, page: Page(offset: 1, limit: 1)), snapshot)
        #expect(Self.ids(page) == ["dgn.003"] && page.omitted == 1 && page.nextOffset == nil)
    }

    // MARK: - Empty and truncated snapshots

    @Test func anEmptySnapshotAnswersEveryListEmptyAtOffsetZeroAndEveryLookupNotFound() throws {
        let snapshot = try Self.snapshot(nodes: 0, edges: 0, parameters: 0, routes: 0, diagnostics: 0)
        for request in [Self.everyTool[0], Self.everyTool[4], Self.everyTool[5]] {
            let result = try Self.run(request, snapshot)
            #expect(result.items.isEmpty && result.matched == 0 && result.returned == 0 && result.omitted == 0)
            #expect(result.nextOffset == nil && result.bytes == 0, "\(request)")
        }
        for request in [Self.everyTool[1], Self.everyTool[2], Self.everyTool[3]] {
            #expect(Self.refusal(request, snapshot) == .notFound, "\(request)")
        }
    }

    @Test func aTruncatedSnapshotReportsItsOwnCountsUnchangedAndMatchesOnlyWhatItKept() throws {
        let snapshot = try Self.snapshot(nodes: 5, diagnostics: 6, limits: Snapshot.Limits(nodes: 3, diagnostics: 4))
        #expect(snapshot.truncation.isTruncated && snapshot.truncation.nodes.droppedOverLimit == 2)
        for request in [Self.everyTool[0], Self.everyTool[1], Self.everyTool[5]] {
            #expect(try Self.run(request, snapshot).snapshotTruncation == snapshot.truncation, "\(request)")
        }
        let listed = try Self.run(.listNodes(Self.firstPage), snapshot)
        #expect(listed.matched == 3 && listed.snapshotTruncation.nodes.offered == 5)
        #expect(listed.snapshotTruncation.diagnostics.droppedOverLimit == 2)
        let whole = try Self.snapshot()
        #expect(try Self.run(Self.everyTool[0], whole).snapshotTruncation.isTruncated == false)
    }

    // MARK: - Byte cap

    @Test func itemsSummingToTheCapAreAllReturnedAndOneByteMoreTrimsTheLastItem() throws {
        let snapshot = try Self.labelledSnapshot(nodes: 3, length: 8)
        let exact = try Self.run(.listNodes(Self.firstPage), snapshot, limits: Self.limits(bytes: 48))
        #expect(exact.returned == 3 && exact.bytes == 48 && exact.trimmedByBytes == 0 && exact.omitted == 0)
        let under = try Self.run(.listNodes(Self.firstPage), snapshot, limits: Self.limits(bytes: 47))
        #expect(Self.ids(under) == ["node.000", "node.001"] && under.bytes == 32)
        #expect(under.matched == 3 && under.returned == 2 && under.omitted == 1 && under.trimmedByBytes == 1)
        #expect(under.nextOffset == 2)
    }

    @Test func trimmingKeepsTheLeadingItemsAndDropsEveryTrailingOneThatDoesNotFit() throws {
        let snapshot = try Self.labelledSnapshot(nodes: 10, length: 8)
        let result = try Self.run(.listNodes(Self.firstPage), snapshot, limits: Self.limits(bytes: 100))
        #expect(Self.ids(result) == (0..<6).map { "node." + Self.pad($0) })
        #expect(result.bytes == 96 && result.trimmedByBytes == 4 && result.omitted == 4 && result.nextOffset == 6)
        let paged = try Self.run(.listNodes(Page(offset: 2, limit: 5)), snapshot, limits: Self.limits(bytes: 40))
        #expect(Self.ids(paged) == ["node.002", "node.003"] && paged.bytes == 32)
        #expect(paged.matched == 10 && paged.returned == 2 && paged.trimmedByBytes == 3 && paged.omitted == 8)
        #expect(paged.nextOffset == 4 && paged.offset == 2 && paged.limit == 5)
        let sizes = { (index: Int) in index == 1 ? String(repeating: "x", count: 30) : "yy" }
        let uneven = Snapshot.build(from: try Self.inputs(label: sizes))
        let kept = try Self.run(.listNodes(Self.firstPage), uneven, limits: Self.limits(bytes: 30))
        #expect(Self.ids(kept) == ["node.000"] && kept.bytes == 10 && kept.trimmedByBytes == 2)
        #expect(kept.nextOffset == 1 && kept.omitted == 2)
    }

    @Test func aLabelWithAccentedLettersCountsItsUtf8BytesNotItsCharacters() throws {
        let snapshot = Snapshot.build(from: try Self.inputs(nodes: 1, label: { _ in "Caf\u{E9}" }))
        let node = try #require(snapshot.nodes.first)
        #expect(node.label.text.unicodeScalars.count == 4 && node.label.text.utf8.count == 5)
        let result = try Self.run(.listNodes(Self.firstPage), snapshot)
        #expect(result.bytes == 8 + 5)
    }

    @Test func aSingleItemOverTheCapIsRefusedWithItsByteCountAtNAndNPlusOne() throws {
        let snapshot = try Self.labelledSnapshot(nodes: 3, length: 8)
        let page = Self.firstPage
        #expect(try Self.run(.listNodes(page), snapshot, limits: Self.limits(bytes: 16)).returned == 1)
        #expect(Self.refusal(.listNodes(page), snapshot, limits: try Self.limits(bytes: 15)) == .resultTooLarge(16))
        #expect(Self.refusal(.listNodes(page), snapshot, limits: try Self.limits(bytes: 1)) == .resultTooLarge(16))
    }

    @Test func aLargeFirstItemRefusesThePageEvenWhenLaterItemsWouldFit() throws {
        let snapshot = Snapshot.build(
            from: try Self.inputs(label: { $0 == 0 ? String(repeating: "x", count: 20) : "yy" })
        )
        let limits = try Self.limits(bytes: 20)
        #expect(Self.refusal(.listNodes(Self.firstPage), snapshot, limits: limits) == .resultTooLarge(28))
        let later = try Self.run(.listNodes(Page(offset: 1, limit: 2)), snapshot, limits: limits)
        #expect(Self.ids(later) == ["node.001", "node.002"] && later.bytes == 20)
    }

    @Test func theStandardCapIs16384BytesAndAnItemOf16384BytesFitsWhileOneOf16385DoesNot() throws {
        let fits = try Self.labelledSnapshot(nodes: 1, length: 16_376, labelBytes: 20_000)
        let result = try Self.run(.listNodes(Self.firstPage), fits)
        #expect(result.returned == 1 && result.bytes == 16_384 && result.trimmedByBytes == 0)
        let over = try Self.labelledSnapshot(nodes: 1, length: 16_377, labelBytes: 20_000)
        #expect(Self.refusal(.listNodes(Self.firstPage), over) == .resultTooLarge(16_385))
    }

    @Test func aNodeWithALongLabelIsRefusedByNodeWithItsTotalByteCount() throws {
        let snapshot = try Self.labelledSnapshot(nodes: 1, length: 17_000, labelBytes: 20_000)
        #expect(Self.refusal(.node(id: "node.000"), snapshot) == .resultTooLarge(8 + 17_000 + 19 + 21))
    }

    @Test func anItemOutsideTheRequestedPageIsNeverMeasuredAgainstTheCap() throws {
        let snapshot = Snapshot.build(
            from: try Self.inputs(label: { $0 == 0 ? String(repeating: "x", count: 100) : "yy" })
        )
        let limits = try Self.limits(bytes: 20)
        #expect(Self.refusal(.listNodes(Page(offset: 1, limit: 2)), snapshot, limits: limits) == nil)
        let trailing = Snapshot.build(
            from: try Self.inputs(label: { $0 == 2 ? String(repeating: "x", count: 100) : "yy" })
        )
        let first = try Self.run(.listNodes(Page(offset: 0, limit: 2)), trailing, limits: limits)
        #expect(first.returned == 2 && first.trimmedByBytes == 0 && first.matched == 3)
    }

    @Test func everyPageOfEverySizeKeepsTheCountIdentityTheCapAndTheNextOffset() throws {
        let snapshot = try Self.labelledSnapshot(nodes: 7, length: 8)
        let all = (0..<7).map { "node." + Self.pad($0) }
        for cap in [16, 40, 64, 112, 1_000] {
            for offset in 0...7 {
                for limit in 1...8 {
                    let result = try Self.run(.listNodes(Page(offset: offset, limit: limit)), snapshot,
                                              limits: Self.limits(bytes: cap))
                    #expect(result.matched == result.returned + result.omitted, "\(cap) \(offset) \(limit)")
                    #expect(result.bytes <= cap && result.returned <= limit, "\(cap) \(offset) \(limit)")
                    #expect(Self.ids(result) == Array(all.dropFirst(offset).prefix(result.returned)))
                    #expect(result.returned + result.trimmedByBytes <= limit)
                    #expect(cap != 1_000 || result.trimmedByBytes == 0, "\(offset) \(limit)")
                    #expect((result.nextOffset == nil) == (offset + result.returned >= result.matched))
                    #expect(result.nextOffset == nil || result.nextOffset == offset + result.returned)
                }
            }
        }
    }
}
