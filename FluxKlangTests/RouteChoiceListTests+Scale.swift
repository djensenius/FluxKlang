//
//  RouteChoiceListTests+Scale.swift
//  FluxKlangTests
//
//  The route picker's claimant scan is one pass (linear in routes plus route channels), pinned by an operations
//  count rather than a clock, and the truncation line counts choices (blocks), not channels.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RouteChoiceListTests {
    @Test func theClaimantScanIsOnePassOverTheRoutes() throws {
        let device = try Fixture.device("dev.p", outputs: 64)
        let source = try Fixture.source(width: 1, on: [device])
        try #require(source.candidates.count == 64)
        let crowd = try (0..<512).map { index in
            try Fixture.route("rte.c\(index)", "rol.c\(index)", "dev.p", Array(64..<164))
        }
        try #require(crowd.count == 512)

        let target = try Fixture.role("rol.cue")
        let scan = RouteChoiceList.claimantsForTesting(of: source.candidates, role: target, in: crowd)
        #expect(scan.claimants.count == 64)
        #expect(scan.claimants.allSatisfy { $0.isEmpty })
        #expect(scan.operations == 512 + 512 * 100)

        let list = try Fixture.make(width: 1, on: [device], routes: crowd)
        #expect(list.rows.count == 64)
        #expect(list.rows.map(\.state) == Array(repeating: .available, count: 64))
    }

    @Test func routesThatCannotClaimCostOneOperationEach() throws {
        let device = try Fixture.device("dev.p", outputs: 4)
        let source = try Fixture.source(width: 1, on: [device])
        let routes = try [
            Fixture.route("rte.a", "rol.mains", "dev.p", [0, 1], .stale),
            Fixture.route("rte.b", "rol.mains", "dev.p", [0, 1], .deviceMissing),
            Fixture.route("rte.c", "rol.mains", "dev.q", [0, 1]),
            Fixture.route("rte.d", "rol.mains", "dev.p", .input, [0, 1]),
            Fixture.route("rte.e", "rol.cue", "dev.p", [0, 1])
        ]
        let target = try Fixture.role("rol.cue")
        let none = RouteChoiceList.claimantsForTesting(of: source.candidates, role: target, in: routes)
        #expect(none.operations == 5)
        #expect(none.claimants.allSatisfy { $0.isEmpty })

        let live = try Fixture.route("rte.f", "rol.verb", "dev.p", [1, 9])
        let one = RouteChoiceList.claimantsForTesting(of: source.candidates, role: target, in: routes + [live])
        #expect(one.operations == 5 + 1 + 2 + 1)
        try #require(one.claimants.count == 4)
        #expect(one.claimants.map(\.count) == [0, 1, 0, 0])
        #expect(one.claimants[1].map(\.rawValue) == ["rol.verb"])
    }

    @Test func aProposedRouteOfTheTargetRoleItselfNeverClaims() throws {
        let device = try Fixture.device("dev.p", outputs: 4)
        let source = try Fixture.source(width: 1, on: [device])
        let target = try Fixture.role("rol.cue")
        let own = try Fixture.route("rte.own", "rol.cue", "dev.p", [0, 1], .proposed)

        let alone = RouteChoiceList.claimantsForTesting(of: source.candidates, role: target, in: [own])
        try #require(alone.claimants.count == 4)
        #expect(alone.claimants.allSatisfy { $0.isEmpty })
        #expect(alone.operations == 1)

        let list = try Fixture.make(width: 1, on: [device], routes: [own])
        try #require(list.rows.count == 4)
        #expect(list.rows.map(\.state) == Array(repeating: .available, count: 4))
        #expect(list.rows.map(\.isEnabled) == [true, true, true, true])

        let other = try Fixture.route("rte.other", "rol.mains", "dev.p", [0, 1], .proposed)
        let contrast = RouteChoiceList.claimantsForTesting(of: source.candidates, role: target, in: [other])
        try #require(contrast.claimants.count == 4)
        #expect(contrast.operations == 1 + 2 + 2)
        #expect(contrast.claimants.map(\.count) == [1, 1, 0, 0])
        #expect(contrast.claimants[0].map(\.rawValue) == ["rol.mains"])
        #expect(contrast.claimants[1].map(\.rawValue) == ["rol.mains"])
    }

    @Test func wideOverlappingBlocksAreUpdatedOncePerRoute() throws {
        let device = try Fixture.device("dev.p", outputs: 127)
        let source = try Fixture.source(width: 64, on: [device])
        try #require(source.candidates.count == 64)
        let names = (0..<512).map { "w" + String(format: "%03d", $0) }
        let routes = try names.map { try Fixture.route("rte.\($0)", "rol.\($0)", "dev.p", Array(32..<96)) }
        try #require(routes.count == 512)

        let target = try Fixture.role("rol.cue")
        let scan = RouteChoiceList.claimantsForTesting(of: source.candidates, role: target, in: routes)
        try #require(scan.claimants.count == 64)
        #expect(scan.operations == 512 * (1 + 64 + 64))
        #expect(scan.claimants.allSatisfy { $0.count == 512 })
        #expect(scan.claimants.allSatisfy { $0.first?.rawValue == "rol.w000" && $0.last?.rawValue == "rol.w511" })

        var labels = try Fixture.labels()
        for name in names { labels[try Fixture.role("rol.\(name)")] = name }
        let list = try Fixture.make(width: 64, on: [device], routes: routes, labels: labels)
        try #require(list.rows.count == 64)
        let everyone = try names.map { try Fixture.role("rol.\($0)") }
        #expect(list.rows.map(\.state) == Array(repeating: .outputInUse(by: everyone), count: 64))
        #expect(list.rows.allSatisfy { !$0.isEnabled })
    }

    @Test func aRouteUpdatesEachBlockItReachesOnce() throws {
        let device = try Fixture.device("dev.p", outputs: 8)
        let source = try Fixture.source(width: 4, on: [device])
        try #require(source.candidates.count == 5)
        let route = try Fixture.route("rte.a", "rol.mains", "dev.p", [3, 2, 1, 0])
        let scan = RouteChoiceList.claimantsForTesting(
            of: source.candidates, role: try Fixture.role("rol.cue"), in: [route]
        )
        #expect(scan.operations == 1 + 4 + 4)
        try #require(scan.claimants.count == 5)
        #expect(scan.claimants.map(\.count) == [1, 1, 1, 1, 0])
    }

    @Test func theSixtyFourthBlockIsTheHighBit() throws {
        let device = try Fixture.device("dev.p", outputs: 127)
        let source = try Fixture.source(width: 64, on: [device])
        try #require(source.candidates.count == 64)
        let target = try Fixture.role("rol.cue")

        let last = try Fixture.route("rte.a", "rol.mains", "dev.p", [126])
        let high = RouteChoiceList.claimantsForTesting(of: source.candidates, role: target, in: [last])
        try #require(high.claimants.count == 64)
        #expect(high.operations == 3)
        #expect(high.claimants.map(\.count) == Array(repeating: 0, count: 63) + [1])

        let first = try Fixture.route("rte.b", "rol.mains", "dev.p", [0])
        let low = RouteChoiceList.claimantsForTesting(of: source.candidates, role: target, in: [first])
        try #require(low.claimants.count == 64)
        #expect(low.operations == 3)
        #expect(low.claimants.map(\.count) == [1] + Array(repeating: 0, count: 63))

        let middle = try Fixture.route("rte.c", "rol.mains", "dev.p", [63])
        let all = RouteChoiceList.claimantsForTesting(of: source.candidates, role: target, in: [middle])
        try #require(all.claimants.count == 64)
        #expect(all.operations == 1 + 1 + 64)
        #expect(all.claimants.allSatisfy { $0.count == 1 })
    }

    @Test func moreThanSixtyFourBlocksAreScannedInGroups() throws {
        var blocks: [RigRouteCandidate] = []
        for (name, outputs) in [("dev.a", 40), ("dev.b", 60), ("dev.c", 50)] {
            blocks += try Fixture.source(width: 1, on: [Fixture.device(name, outputs: outputs)]).candidates
        }
        try #require(blocks.count == 150)
        let route = try Fixture.route("rte.a", "rol.mains", "dev.c", [10, 40])
        let second = try Fixture.route("rte.b", "rol.verb", "dev.b", [24])
        let scan = RouteChoiceList.claimantsForTesting(
            of: blocks, role: try Fixture.role("rol.cue"), in: [route, second]
        )
        // rte.a: group 0 holds no dev.c block (1 visit); groups 1 and 2 cost 1 visit, 2 lookups, 1 update each (9).
        // rte.b: group 0 1 visit + 1 lookup (no hit, dev.b ch 24 starts group 1), group 1 1 + 1 + 1, group 2 1 (6).
        #expect(scan.operations == 15)
        try #require(scan.claimants.count == 150)
        let claimed = scan.claimants.indices.filter { !scan.claimants[$0].isEmpty }
        #expect(claimed == [64, 110, 140])
        #expect(scan.claimants[64].map(\.rawValue) == ["rol.verb"])
        #expect(scan.claimants[110].map(\.rawValue) == ["rol.mains"])
        #expect(scan.claimants[140].map(\.rawValue) == ["rol.mains"])
    }

    @Test func theTruncationLineCountsChoicesNotChannels() throws {
        let full = try Fixture.device("dev.a", outputs: 65)
        let pair = try Fixture.device("dev.b", outputs: 2)
        let source = try Fixture.source(on: [full, pair])
        let truncation = try #require(source.truncation)
        try #require(truncation.omitted == 1)
        let one = try Fixture.make(on: [full, pair])
        #expect(one.rows.count == 64)
        #expect(one.isTruncated)
        #expect(one.truncationText == "1 more compatible choice is not listed")

        let trio = try Fixture.device("dev.b", outputs: 3)
        let twoSource = try Fixture.source(on: [full, trio])
        try #require(twoSource.truncation?.omitted == 2)
        let two = try Fixture.make(on: [full, trio])
        #expect(two.rows.count == 64)
        #expect(two.isTruncated)
        #expect(two.truncationText == "2 more compatible choices are not listed")
    }
}
