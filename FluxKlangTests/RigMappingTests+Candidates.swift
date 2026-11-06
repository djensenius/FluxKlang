import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = RigMappingFixture

@Suite("Rig mapping candidates")
struct RigMappingCandidateTests {
    @Test func candidatesAreContiguousBlocksInDeviceThenChannelOrder() throws {
        let devices = try [Fixture.device("dev.b", outputs: 4), Fixture.device("dev.a", outputs: 3)]
        let proposal = try Fixture.proposal([Fixture.role("role.mains")], devices)
        let found = try #require(Fixture.candidates(proposal, "role.mains"))
        #expect(found.truncation == nil)
        #expect(found.candidates.map(\.device.rawValue) == ["dev.a", "dev.a", "dev.b", "dev.b", "dev.b"])
        #expect(found.candidates.map(\.channels) == [[0, 1], [1, 2], [0, 1], [1, 2], [2, 3]])
        #expect(found.candidates.map(\.firstChannel) == [0, 1, 0, 1, 2])
        #expect(found.candidates.allSatisfy { $0.channelCount == 2 && $0.role.rawValue == "role.mains" })
    }

    @Test func candidateCapReportsTruncationExplicitly() throws {
        let mono = try [Fixture.role("role.mono", channels: 1)]
        let wide = try #require(Fixture.candidates(Fixture.proposal(mono, [Fixture.device("dev.a", outputs: 100)]),
                                                   "role.mono"))
        #expect(wide.candidates.count == RigMappingLimits.candidatesPerRole)
        #expect(wide.candidates.last?.firstChannel == 63)
        #expect(Fixture.counts(wide.truncation) == [64, 100])
        #expect(wide.truncation?.omitted == 36)

        let split = try #require(Fixture.candidates(Fixture.proposal(mono, [
            Fixture.device("dev.a", outputs: 40), Fixture.device("dev.b", outputs: 40)
        ]), "role.mono"))
        #expect(split.candidates.filter { $0.device.rawValue == "dev.b" }.count == 24)
        #expect(Fixture.counts(split.truncation) == [64, 80])

        let exact = try #require(Fixture.candidates(Fixture.proposal(mono, [Fixture.device("dev.a", outputs: 64)]),
                                                    "role.mono"))
        #expect(exact.candidates.count == 64 && exact.truncation == nil)
        let over = try #require(Fixture.candidates(Fixture.proposal(mono, [Fixture.device("dev.a", outputs: 65)]),
                                                   "role.mono"))
        #expect(over.candidates.count == 64 && Fixture.counts(over.truncation) == [64, 65])
    }

    @Test func blocksPastTheCapCannotBeChosen() throws {
        let mono = try [Fixture.role("role.mono", channels: 1)]
        let devices = try [Fixture.device("dev.a", outputs: 100), Fixture.device("dev.b", outputs: 1)]
        let capped = try Fixture.proposal(mono, devices)
        #expect(Fixture.counts(Fixture.candidates(capped, "role.mono")?.truncation) == [64, 101])
        // The same dev.b block, offered by a proposal without dev.a, is past the cap in `capped`.
        let alone = try Fixture.proposal(mono + [Fixture.role("role.pad", channels: 1)],
                                         [Fixture.device("dev.b", outputs: 2)])
        let pastCap = try #require(Fixture.candidates(alone, "role.mono")?.candidates.first)
        #expect(pastCap.device.rawValue == "dev.b" && pastCap.firstChannel == 0)
        #expect(throws: RigMappingRefusal.candidateNotOffered(pastCap)) {
            try capped.choosing(pastCap, id: RouteID("route.user"))
        }
    }

    @Test func proposalsDoNotDependOnInputOrder() throws {
        let roles = try [Fixture.role("role.b", channels: 1), Fixture.role("role.a"), Fixture.role("role.c", .input),
                         Fixture.role("role.m", channels: 1, signal: .audio), Fixture.role("role.x", signal: .midi)]
        let devices = try [Fixture.device("dev.c", inputs: 2, outputs: 2), Fixture.device("dev.a", outputs: 3),
                           Fixture.device("dev.b", outputs: 1, presence: .missing)]
        let routes = try [Fixture.route("route.b", role: "role.a", device: "dev.a", binding: .stale),
                          Fixture.route("route.a", role: "role.b", device: "dev.b", channels: [0],
                                        binding: .deviceMissing)]
        let first = try Fixture.proposal(roles, devices, routes: routes)
        let second = try Fixture.proposal(roles.reversed(), devices.reversed(), routes: routes.reversed())
        let rotated = try Fixture.proposal(Array(roles[2...] + roles[..<2]), Array(devices[1...] + devices[..<1]),
                                           routes: routes)
        #expect(first == second && first == rotated)
        #expect(first.mappings.map(\.role.rawValue) == ["role.a", "role.b", "role.c", "role.m", "role.x"])
        #expect(first.existingRoutes.map(\.route.rawValue) == ["route.a", "route.b"])
        try Fixture.expectValid(first, over: Fixture.document(devices, routes: routes))
    }

    @Test func derivedRouteIDsAvoidExistingIDsAndFitTheIDLength() throws {
        let devices = try [Fixture.device("dev.a", outputs: 2)]
        let existing = try [Fixture.route("route.proposed.role.mains", role: "role.mains", device: "dev.a",
                                          binding: .stale)]
        let document = try Fixture.document(devices, routes: existing)
        let proposal = try RigMappingProposal.make(roles: [Fixture.role("role.mains")], devices: document)
        #expect(proposal.proposedRoutes.map(\.id.rawValue) == ["route.proposed.role.mains.2"])
        try Fixture.expectValid(proposal, over: document)
        // A derived `.2` ID is also another role's stem: that role moves on to `.2.2`.
        let crossed = try RigMappingProposal.make(
            roles: [Fixture.role("role.mains.2"), Fixture.role("role.mains")], devices: document
        )
        #expect(crossed.proposedRoutes.map(\.id.rawValue)
            == ["route.proposed.role.mains.2", "route.proposed.role.mains.2.2"])
        // Existing `.m`, `.m.2` and `.m.3`: role.m resumes at `.4`, which role.m.4's stem then avoids.
        let taken = try ["route.proposed.role.m", "route.proposed.role.m.2", "route.proposed.role.m.3"].map {
            try Fixture.route($0, role: "role.m", device: "dev.a", binding: .stale)
        }
        let pinned = try Fixture.proposal(["role.x", "role.m.4", "role.m.3", "role.m"].map { try Fixture.role($0) },
                                          devices, routes: taken)
        let pinnedIDs = ["route.proposed.role.m.4", "route.proposed.role.m.3.2", "route.proposed.role.m.4.2",
                         "route.proposed.role.x"]
        #expect(pinned.proposedRoutes.map(\.id.rawValue) == pinnedIDs)
        let pinnedRun = try RigMappingProposal.routeIDsForTesting(
            for: ["role.m", "role.m.3", "role.m.4", "role.x"].map { try RoleID($0) }, avoiding: Set(taken.map(\.id))
        )
        #expect(pinnedRun.ids.map(\.rawValue) == pinnedIDs)
        // m: 4 tries (.m, .2, .3, .4); m.3: 2; m.4: 2; x: 1. Bound: r + 2(r + d) = 4 + 2 * 7.
        #expect(pinnedRun.attempts == 9 && pinnedRun.attempts <= 4 + 2 * (4 + 3))

        let long = String(repeating: "r", count: RoleID.maximumLength)
        let longProposal = try Fixture.proposal([Fixture.role(long)], devices)
        let id = try #require(longProposal.proposedRoutes.first?.id.rawValue)
        #expect(id == String(("route.proposed." + long).prefix(RouteID.maximumLength - 8)))
        let used = try Set([RouteID(id)])
        let next = try #require(RigMappingProposal.routeIDsForTesting(for: [RoleID(long)], avoiding: used).ids.first)
        #expect(next.rawValue == id + ".2" && next.rawValue.utf8.count <= RouteID.maximumLength)

        // Two long roles that differ only past the shortened stem still get distinct IDs.
        let twins = try [Fixture.role(long), Fixture.role(String(long.dropLast()) + "s")]
        let twinIDs = try Fixture.proposal(twins, devices).proposedRoutes.map(\.id.rawValue)
        #expect(twinIDs == [id, id + ".2"])
    }

    @Test func manyRolesSharingALongStemGetDistinctIDsInLinearAttempts() throws {
        // 110 shared characters: every role's 120-byte stem is the same.
        let shared = String(repeating: "s", count: 110)
        let roles = try (0..<2_000).map { try Fixture.role(shared + ".\($0)", channels: 1) }
        let ids = try Fixture.proposal(roles, [Fixture.device("dev.a", outputs: 1)]).proposedRoutes.map(\.id.rawValue)
        let stem = String(("route.proposed." + shared).prefix(RouteID.maximumLength - 8))
        #expect(ids == [stem] + (2...2_000).map { "\(stem).\($0)" })
        #expect(ids.last == stem + ".2000")
        // The allocator's cost, counted: one attempt per role (r = 2000, d = 0). Rescanning each stem
        // from `.2` instead would take 2000 * 2001 / 2 attempts.
        let run = RigMappingProposal.routeIDsForTesting(for: roles.map(\.id).sorted(), avoiding: [])
        #expect(run.ids.map(\.rawValue) == ids)
        #expect(run.attempts == 2_000 && run.attempts <= 2_000 + 2 * (2_000 + 0))

        // The document already holds `stem`, `stem.2` … `stem.50` (d = 50): the first role walks past
        // them once (51 attempts), the other 99 resume at once.
        let held = try Set([RouteID(stem)] + (2...50).map { try RouteID("\(stem).\($0)") })
        let crowded = RigMappingProposal.routeIDsForTesting(for: Array(roles.map(\.id).sorted().prefix(100)),
                                                            avoiding: held)
        #expect(crowded.ids.map(\.rawValue) == (51...150).map { "\(stem).\($0)" })
        #expect(crowded.attempts == 150 && crowded.attempts <= 100 + 2 * (100 + 50))
    }

    @Test func proposalsStopAtTheRouteCapacityInRoleOrder() throws {
        let devices = try [Fixture.device("dev.a", outputs: 2)]
        let filler = try (1..<DeviceCapabilityLimits.routes).map {
            try Fixture.route("route.fill.\($0)", role: "role.fill", device: "dev.a", binding: .stale)
        }
        let roles = try [Fixture.role("role.b"), Fixture.role("role.a")]
        let proposal = try Fixture.proposal(roles, devices, routes: filler)
        #expect(filler.count == 4_095 && proposal.orphanRoutes.count == 4_095)
        #expect(proposal.proposedRoutes.map(\.role.rawValue) == ["role.a"])
        #expect(Fixture.outcome(proposal, "role.b") == .unmapped(.routeCapacityExhausted(limit: 4_096)))
        #expect(proposal.unmapped.map(\.rawValue) == ["role.b"])
        #expect(try Fixture.document(devices, routes: filler + proposal.proposedRoutes).routes.count == 4_096)

        let roomy = try Fixture.proposal(roles, devices, routes: Array(filler.dropLast()))
        #expect(roomy.proposedRoutes.map(\.role.rawValue) == ["role.a", "role.b"])
        // A full document: single- and multi-candidate roles alike have no route left to take.
        let full = try Fixture.proposal(roles + [Fixture.role("role.c", channels: 1)], devices, routes: filler + [
            Fixture.route("route.fill.0", role: "role.fill", device: "dev.a", binding: .stale)
        ])
        #expect(full.proposedRoutes.isEmpty && full.unmapped.map(\.rawValue) == ["role.a", "role.b", "role.c"])
        #expect(Fixture.outcome(full, "role.c") == .unmapped(.routeCapacityExhausted(limit: 4_096)))
        #expect(full.awaitingChoice.isEmpty)

        // 4094 routes, two of them a mismatched and an already-routed role's: both new roles still fit.
        let kept = try [
            Fixture.route("route.mis", role: "role.mis", device: "dev.a", channels: [0], binding: .proposed),
            Fixture.route("route.ok", role: "role.ok", device: "dev.a", binding: .proposed)
        ]
        let mixedRoles = try roles + [Fixture.role("role.mis"), Fixture.role("role.ok")]
        let mixedDocument = try Fixture.document(devices, routes: Array(filler.prefix(4_092)) + kept)
        let mixed = try RigMappingProposal.make(roles: mixedRoles, devices: mixedDocument)
        #expect(mixed.proposedRoutes.map(\.role.rawValue) == ["role.a", "role.b"])
        #expect(mixed.mismatched.map(\.rawValue) == ["role.mis"])
        #expect(try Fixture.outcome(mixed, "role.ok") == .alreadyRouted([RouteID("route.ok")]))
        try Fixture.documented(mixed, over: mixedDocument).validate(roles: mixed.requirements)
    }

    @Test func theBudgetRunsOutPartwayThroughTheRoles() throws {
        // One slot left. Mono roles have two blocks on the stereo device; the stereo role has one.
        let devices = try [Fixture.device("dev.a", outputs: 2)]
        let filler = try (1..<DeviceCapabilityLimits.routes).map {
            try Fixture.route("route.fill.\($0)", role: "role.fill", device: "dev.a", binding: .stale)
        }
        let roles = try [Fixture.role("role.c", channels: 1), Fixture.role("role.b"),
                         Fixture.role("role.a", channels: 1)]
        let proposal = try Fixture.proposal(roles, devices, routes: filler)
        // Nothing is reserved for `role.a`'s choice, so `role.b` takes the last slot.
        #expect(Fixture.candidates(proposal, "role.a")?.candidates.count == 2)
        #expect(proposal.proposedRoutes.map(\.role.rawValue) == ["role.b"])
        #expect(Fixture.outcome(proposal, "role.c") == .unmapped(.routeCapacityExhausted(limit: 4_096)))
        let choice = try #require(Fixture.candidates(proposal, "role.a")?.candidates.first)
        #expect(throws: RigMappingRefusal.routeCapacityExhausted(limit: 4_096)) {
            try proposal.choosing(choice, id: RouteID("route.user.a"))
        }
    }

    @Test func choicesStopAtTheRouteCapacity() throws {
        let devices = try [Fixture.device("dev.a", outputs: 3)]
        let filler = try (2..<DeviceCapabilityLimits.routes).map {
            try Fixture.route("route.fill.\($0)", role: "role.fill", device: "dev.a", binding: .stale)
        }
        let roles = try [Fixture.role("role.a"), Fixture.role("role.b"), Fixture.role("role.c")]
        let proposal = try Fixture.proposal(roles, devices, routes: filler)
        #expect(proposal.awaitingChoice.count == 3)
        let first = try proposal.choosing(#require(Fixture.candidates(proposal, "role.a")?.candidates.first),
                                          id: RouteID("route.user.a"))
        let second = try first.choosing(#require(Fixture.candidates(first, "role.b")?.candidates.last),
                                        id: RouteID("route.user.b"))
        #expect(filler.count + second.proposedRoutes.count == 4_096)
        let last = try #require(Fixture.candidates(second, "role.c")?.candidates.first)
        #expect(throws: RigMappingRefusal.routeCapacityExhausted(limit: 4_096)) {
            try second.choosing(last, id: RouteID("route.user.c"))
        }
        #expect(try Fixture.document(devices, routes: filler + second.proposedRoutes).routes.count == 4_096)
    }

    @Test func zeroWidthRequirementsOfferNothing() throws {
        let devices = try RigRouteCandidates.eligibleDevices([Fixture.device("dev.a", outputs: 4)])
        let zero = RouteRoleRequirement(direction: .output, channelCount: 0)
        let found = try RigRouteCandidates.candidates(for: RoleID("role.zero"), requirement: zero, on: devices)
        #expect(found.candidates.isEmpty && found.truncation == nil)
    }

    @Test func roleRequirementsUseTheDeviceContractVocabulary() throws {
        #expect(RigRoleRequirements.direction(of: .input) == .input)
        #expect(RigRoleRequirements.direction(of: .output) == .output)
        #expect(RigRoleRequirements.requirement(for: try Fixture.role("role.a", .input, channels: 64))
            == .audio(RouteRoleRequirement(direction: .input, channelCount: 64)))
        #expect(RigRoleRequirements.requirement(for: try Fixture.role("role.a", channels: 1))
            == .audio(RouteRoleRequirement(direction: .output, channelCount: 1)))
        #expect(RigRoleRequirements.requirement(for: try Fixture.role("role.a", channels: 2, signal: .midi))
            == .notAudio(.midi))
    }

    @Test func wideRolesStillFitWhenTheDeviceIsExactlyAsWide() throws {
        let roles = try [Fixture.role("role.wide", channels: 64), Fixture.role("role.in", .input, channels: 2)]
        let devices = try [Fixture.device("dev.a", inputs: 2, outputs: 64), Fixture.device("dev.z", inputs: 1)]
        let proposal = try Fixture.proposal(roles, devices)
        #expect(proposal.proposedRoutes.map(\.channels) == [[0, 1], Array(0..<64)])
        try Fixture.expectValid(proposal, over: Fixture.document(devices))
    }
}
