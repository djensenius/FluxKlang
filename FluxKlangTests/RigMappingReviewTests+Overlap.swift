import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = RigMappingReviewFixture

@Suite("Rig mapping review: channel overlap policy")
struct RigMappingReviewOverlapTests {
    @Test func aChoiceThatWritesAnotherRoutesOutputIsRefused() throws {
        let review = try Fixture.lostRigReview()
        let base = try Fixture.lostRig()
        #expect(review.overlaps.isEmpty)
        let cue = try Fixture.candidate(review, "rol.cue", first: 1)
        let chosen = try review.choosing(cue, id: RouteID("rte.cue"))
        // The conflict exists only because of the choice.
        let device = try DeviceID("dev.iface-a")
        let routes = try Fixture.ids(["rte.cue", "rte.mains"])
        #expect(chosen.overlaps.map(\.channel) == [1])
        #expect(chosen.overlaps.map(\.routes) == [routes])
        #expect(chosen.overlaps.map(\.kind) == [.outputConflict])
        #expect(chosen.overlaps.map(\.device) == [device] && chosen.overlaps.map(\.direction) == [.output])
        #expect(Fixture.refusal { _ = try chosen.apply(.empty, to: base) }
                == .outputChannelConflict(device: device, channel: 1, routes: routes))
        // The same choice as a decision is refused the same way, and nothing changes.
        let decisions = try RigMappingDecisions.make(roles: [.choose(cue, id: RouteID("rte.cue"))])
        #expect(Fixture.refusal { _ = try review.apply(decisions, to: base) }
                == .outputChannelConflict(device: device, channel: 1, routes: routes))
        #expect(review.overlaps.isEmpty)
        // A free block is accepted.
        let free = try review.choosing(Fixture.candidate(review, "rol.cue", first: 2), id: RouteID("rte.cue"))
        #expect(free.overlaps.isEmpty)
        #expect(try free.apply(.empty, to: base).added.map(\.rawValue) == ["rte.cue"])
    }

    @Test func theFirstConflictIsReportedInDeviceAndChannelOrder() throws {
        let base = try Fixture.document([Fixture.device("dev.a", outputs: 4), Fixture.device("dev.b", outputs: 4)],
                                        routes: [
            Fixture.route("rte.b2", role: "role.b2", device: "dev.b", channels: [2, 3], binding: .proposed),
            Fixture.route("rte.a1", role: "role.a1", device: "dev.a", channels: [3, 2], binding: .confirmed),
            Fixture.route("rte.b1", role: "role.b1", device: "dev.b", channels: [3, 2], binding: .confirmed),
            Fixture.route("rte.a2", role: "role.a2", device: "dev.a", channels: [2, 3], binding: .proposed)
        ])
        let roles = try ["role.a1", "role.a2", "role.b1", "role.b2"].map { try Fixture.role($0) }
        let review = try RigMappingReview.make(roles: roles, document: base)
        #expect(review.overlaps.map(\.device.rawValue) == ["dev.a", "dev.a", "dev.b", "dev.b"])
        #expect(review.overlaps.map(\.channel) == [2, 3, 2, 3])
        let (onA, onB) = try (Fixture.ids(["rte.a1", "rte.a2"]), Fixture.ids(["rte.b1", "rte.b2"]))
        #expect(review.overlaps.map(\.routes) == [onA, onA, onB, onB])
        // Every route fits its role, so the conflicts were already there: reported, in the same order.
        let change = try review.apply(.empty, to: base)
        #expect(change.document == base && change.preexistingOutputConflicts == review.overlaps)
        // Without the roles every route is a kept (orphan) removal candidate, so the first conflict is refused.
        let orphans = try RigMappingReview.make(roles: [], document: base)
        #expect(Fixture.refusal { _ = try orphans.apply(.empty, to: base) }
                == .outputChannelConflict(device: try DeviceID("dev.a"), channel: 2, routes: onA))
    }

    @Test func aPreexistingConflictIsReportedButAnAddedOneIsRefused() throws {
        let base = try Fixture.document([Fixture.device("dev.a", outputs: 4)], routes: [
            Fixture.route("rte.mains", role: "role.mains", device: "dev.a", binding: .confirmed),
            Fixture.route("rte.fx", role: "role.fx", device: "dev.a", channels: [1, 2], binding: .confirmed)
        ])
        let roles = try [Fixture.role("role.mains"), Fixture.role("role.fx"), Fixture.role("role.wide", channels: 8),
                         Fixture.role("role.mono", channels: 1)]
        let review = try RigMappingReview.make(roles: roles, document: base)
        #expect(review.removalCandidates.isEmpty && review.unmapped.map(\.role.rawValue) == ["role.wide"])
        let shared = try Fixture.ids(["rte.fx", "rte.mains"])
        let change = try review.apply(.empty, to: base)
        #expect(change.document == base && change.added.isEmpty && change.sharedInputs.isEmpty)
        #expect(change.preexistingOutputConflicts.map(\.channel) == [1])
        #expect(change.preexistingOutputConflicts.map(\.routes) == [shared])
        #expect(change.stillUnmapped.map(\.rawValue) == ["role.mono", "role.wide"])
        // An added route on a free channel still applies, with the old conflict reported.
        let free = try RigMappingDecisions.make(roles: [.choose(Fixture.candidate(review, "role.mono", first: 3),
                                                                id: RouteID("rte.mono"))])
        let added = try review.apply(free, to: base)
        #expect(added.added.map(\.rawValue) == ["rte.mono"] && added.preexistingOutputConflicts.map(\.channel) == [1])
        // An added route that joins the conflict, or makes a new one, is refused.
        for (first, routes) in [(1, ["rte.fx", "rte.mains", "rte.mono"]), (0, ["rte.mains", "rte.mono"])] {
            let mono = try Fixture.candidate(review, "role.mono", first: first)
            let pick = try RigMappingDecisions.make(roles: [.choose(mono, id: RouteID("rte.mono"))])
            #expect(Fixture.refusal { _ = try review.apply(pick, to: base) }
                    == .outputChannelConflict(device: try DeviceID("dev.a"), channel: first,
                                              routes: try Fixture.ids(routes)))
        }
    }

    @Test func aRepeatedChannelPastTheFirstBitsetWordIsFound() throws {
        let routes = try [("rte.hi1", 70), ("rte.lo", 3), ("rte.hi2", 70)].map { id, channel in
            try Fixture.route(id, role: "role.\(id)", device: "dev.a", channels: [channel], binding: .proposed)
        }
        let overlaps = RigChannelOverlapScan.overlaps(in: routes)
        #expect(overlaps.map(\.channel) == [70])
        #expect(overlaps.map(\.routes) == [try Fixture.ids(["rte.hi1", "rte.hi2"])])
    }

    @Test func sharedInputIsAllowedAndReported() throws {
        let base = try Fixture.document([Fixture.device("dev.a", inputs: 2, outputs: 2)], routes: [
            Fixture.route("rte.vox", role: "role.vox", device: "dev.a", direction: .input, channels: [0],
                          binding: .confirmed),
            Fixture.route("rte.talk", role: "role.talk", device: "dev.a", direction: .input, channels: [0],
                          binding: .proposed)
        ])
        let roles = try [Fixture.role("role.vox", .input, channels: 1), Fixture.role("role.talk", .input, channels: 1)]
        let review = try RigMappingReview.make(roles: roles, document: base)
        #expect(review.overlaps.map(\.kind) == [.sharedInput])
        #expect(review.overlaps.map(\.routes) == [try Fixture.ids(["rte.talk", "rte.vox"])])
        #expect(review.overlaps.map(\.direction) == [.input] && review.overlaps.map(\.channel) == [0])
        let change = try review.apply(.empty, to: base)
        #expect(change.document == base)
        #expect(change.sharedInputs == review.overlaps)
    }

    @Test func overlapsAreSplitByDeviceAndDirection() throws {
        let base = try Fixture.document(
            [Fixture.device("dev.a", inputs: 2, outputs: 2), Fixture.device("dev.b", inputs: 2, outputs: 2)],
            routes: [
                Fixture.route("rte.a-out", role: "role.x", device: "dev.a", binding: .confirmed),
                Fixture.route("rte.a-in", role: "role.y", device: "dev.a", direction: .input, binding: .confirmed),
                Fixture.route("rte.b-out", role: "role.z", device: "dev.b", binding: .confirmed),
                Fixture.route("rte.b-in", role: "role.w", device: "dev.b", direction: .input, binding: .confirmed)
            ]
        )
        let roles = try [Fixture.role("role.x"), Fixture.role("role.y", .input), Fixture.role("role.z"),
                         Fixture.role("role.w", .input)]
        let review = try RigMappingReview.make(roles: roles, document: base)
        #expect(review.overlaps.isEmpty)
        let change = try review.apply(.empty, to: base)
        #expect(change.document == base && change.sharedInputs.isEmpty)
    }

    @Test func inputSharesAreListedBeforeOutputConflictsOnOneDevice() throws {
        let base = try Fixture.document([Fixture.device("dev.a", inputs: 2, outputs: 2)], routes: [
            Fixture.route("rte.out1", role: "role.out1", device: "dev.a", channels: [1], binding: .confirmed),
            Fixture.route("rte.in1", role: "role.in1", device: "dev.a", direction: .input, channels: [1],
                          binding: .confirmed),
            Fixture.route("rte.out2", role: "role.out2", device: "dev.a", channels: [1], binding: .proposed),
            Fixture.route("rte.in2", role: "role.in2", device: "dev.a", direction: .input, channels: [1],
                          binding: .proposed)
        ])
        let review = try RigMappingReview.make(roles: [], document: base)
        #expect(review.overlaps.map(\.kind) == [.sharedInput, .outputConflict])
        #expect(review.overlaps.map(\.routes) == [try Fixture.ids(["rte.in1", "rte.in2"]),
                                                  try Fixture.ids(["rte.out1", "rte.out2"])])
    }

    @Test func mutedRoutesClaimNoChannel() throws {
        let base = try Fixture.document([Fixture.device("dev.a", outputs: 2)], routes: [
            Fixture.route("rte.mains", role: "role.mains", device: "dev.a", binding: .confirmed),
            Fixture.route("rte.old", role: "role.mains", device: "dev.a", binding: .stale),
            Fixture.route("rte.lost", role: "role.mains", device: "dev.a", binding: .deviceMissing)
        ])
        let review = try RigMappingReview.make(roles: [Fixture.role("role.mains")], document: base)
        #expect(review.overlaps.isEmpty)
        #expect(try review.apply(.empty, to: base).document == base)
    }

    @Test func aConflictInTheBaseDocumentIsRefusedUntilACandidateIsRemoved() throws {
        let base = try Fixture.document([Fixture.device("dev.a", outputs: 2)], routes: [
            Fixture.route("rte.mains", role: "role.mains", device: "dev.a", binding: .confirmed),
            Fixture.route("rte.orphan", role: "role.gone", device: "dev.a", channels: [1], binding: .confirmed)
        ])
        let review = try RigMappingReview.make(roles: [Fixture.role("role.mains")], document: base)
        let routes = try Fixture.ids(["rte.mains", "rte.orphan"])
        #expect(Fixture.refusal { _ = try review.apply(.empty, to: base) }
                == .outputChannelConflict(device: try DeviceID("dev.a"), channel: 1, routes: routes))
        let change = try review.apply(RigMappingDecisions.make(routes: [.remove(RouteID("rte.orphan"))]), to: base)
        #expect(change.document.routes.map(\.id.rawValue) == ["rte.mains"])
    }

    @Test func theOverlapScanIsLinearAt4096Routes() throws {
        let limit = DeviceCapabilityLimits.routes
        func routes(_ count: Int, shared: Bool) throws -> [AudioRoute] {
            try (0..<count).map { index in
                try AudioRoute(id: RouteID("rte.\(index)"), role: RoleID("role.\(index)"), device: DeviceID("dev.a"),
                               direction: shared ? .input : .output, channels: [shared ? 0 : index],
                               binding: .proposed)
            }
        }
        // Distinct channels: one visit per route plus one per channel, and no second pass.
        let distinct = RigChannelOverlapScan.scanForTesting(try routes(limit, shared: false))
        #expect(distinct.overlaps.isEmpty && distinct.operations == 2 * limit)
        // Every route on one input channel: a second pass over the channels, one overlap listing all routes.
        let half = RigChannelOverlapScan.scanForTesting(try routes(limit / 2, shared: true))
        let full = RigChannelOverlapScan.scanForTesting(try routes(limit, shared: true))
        #expect(full.operations == 3 * limit && half.operations == 3 * (limit / 2))
        #expect(full.overlaps.count == 1 && full.overlaps.first?.routes.count == limit)
        #expect(full.overlaps.first?.kind == .sharedInput)
        // A full document reviews and applies with every route kept.
        let document = try Fixture.document([Fixture.device("dev.a", inputs: limit)],
                                            routes: routes(limit, shared: true))
        let review = try RigMappingReview.make(roles: [], document: document)
        #expect(review.removalCandidates.count == limit && review.overlaps == full.overlaps)
        let change = try review.apply(.empty, to: document)
        #expect(change.kept.count == limit && change.sharedInputs == full.overlaps)
    }
}
