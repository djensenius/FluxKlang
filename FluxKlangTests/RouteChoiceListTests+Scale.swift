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
        #expect(one.operations == 5 + 1 + 2)
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
        #expect(contrast.operations == 1 + 2)
        #expect(contrast.claimants.map(\.count) == [1, 1, 0, 0])
        #expect(contrast.claimants[0].map(\.rawValue) == ["rol.mains"])
        #expect(contrast.claimants[1].map(\.rawValue) == ["rol.mains"])
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
