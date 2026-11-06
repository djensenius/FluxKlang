import Testing
@testable import FluxKlang

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
        #expect(wide.truncation == RigCandidateTruncation(listed: 64, total: 100))
        #expect(wide.truncation?.omitted == 36)

        let split = try #require(Fixture.candidates(Fixture.proposal(mono, [
            Fixture.device("dev.a", outputs: 40), Fixture.device("dev.b", outputs: 40)
        ]), "role.mono"))
        #expect(split.candidates.filter { $0.device.rawValue == "dev.b" }.count == 24)
        #expect(split.truncation == RigCandidateTruncation(listed: 64, total: 80))

        let exact = try #require(Fixture.candidates(Fixture.proposal(mono, [Fixture.device("dev.a", outputs: 64)]),
                                                    "role.mono"))
        #expect(exact.candidates.count == 64 && exact.truncation == nil)
        let over = try #require(Fixture.candidates(Fixture.proposal(mono, [Fixture.device("dev.a", outputs: 65)]),
                                                   "role.mono"))
        #expect(over.candidates.count == 64 && over.truncation == RigCandidateTruncation(listed: 64, total: 65))
    }

    @Test func blocksPastTheCapCannotBeChosen() throws {
        let mono = try [Fixture.role("role.mono", channels: 1)]
        let devices = try [Fixture.device("dev.a", outputs: 100), Fixture.device("dev.b", outputs: 1)]
        let capped = try Fixture.proposal(mono, devices)
        #expect(Fixture.candidates(capped, "role.mono")?.truncation == RigCandidateTruncation(listed: 64, total: 101))
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

        let long = String(repeating: "r", count: RoleID.maximumLength)
        let longProposal = try Fixture.proposal([Fixture.role(long)], devices)
        let id = try #require(longProposal.proposedRoutes.first?.id.rawValue)
        #expect(id == String(("route.proposed." + long).prefix(RouteID.maximumLength - 8)))
        let used = try Set([RouteID(id)])
        let next = try RigMappingProposal.routeID(for: RoleID(long), avoiding: used)
        #expect(next.rawValue == id + ".2" && next.rawValue.utf8.count <= RouteID.maximumLength)

        // Two long roles that differ only past the shortened stem still get distinct IDs.
        let twins = try [Fixture.role(long), Fixture.role(String(long.dropLast()) + "s")]
        let twinIDs = try Fixture.proposal(twins, devices).proposedRoutes.map(\.id.rawValue)
        #expect(twinIDs == [id, id + ".2"])
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
