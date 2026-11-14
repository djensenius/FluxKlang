import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Builders for the rig mapping review suites.
enum RigMappingReviewFixture {
    static let host = HostID(validated: "host.review")

    static func role(_ id: String, _ direction: PortDirection = .output, channels: Int? = 2,
                     signal: PortSignal = .audio) throws -> ProjectRole {
        try ProjectRole(id: RoleID(id), label: id, direction: direction, signal: signal, channels: channels)
    }

    static func device(_ id: String, inputs: Int = 0, outputs: Int = 0,
                       presence: DevicePresence = .present) throws -> DeviceDescriptor {
        try DeviceDescriptor(
            id: DeviceID(id), kind: .audioInterface,
            layout: ChannelLayout(inputs: inputs, outputs: outputs, sampleRate: 48_000),
            binding: .reported, identity: DeviceIdentity(.init(uid: "uid-\(id)", evidence: [.deviceUID])),
            presence: presence
        )
    }

    /// A route; a confirmed one carries current host-local evidence for its device.
    static func route(_ id: String, role: String, device: String, direction: RouteDirection = .output,
                      channels: [Int] = [0, 1], binding: RouteBinding) throws -> AudioRoute {
        var route = try AudioRoute(id: RouteID(id), role: RoleID(role), device: DeviceID(device),
                                   direction: direction, channels: channels, binding: binding)
        if binding == .confirmed {
            route.confirmedHost = host
            route.confirmedEpoch = .initial
            route.confirmedDeviceUID = "uid-\(device)"
            route.evidence = "human-confirmed-port-map"
        }
        return route
    }

    static func document(_ devices: [DeviceDescriptor], routes: [AudioRoute] = [],
                         revision: Int = 0) throws -> DeviceCapabilityDocument {
        try DeviceCapabilityDocument(revision: ContractRevision(revision), host: host, hostEpoch: .initial,
                                     devices: devices, routes: routes)
    }

    /// The `devices.json` example at revision 7: Interface B is missing, so `rte.space` is Lost/Muted.
    static func lostRig(ifaceAOutputs: Int = 6, revision: Int = 7) throws -> DeviceCapabilityDocument {
        try document([device("dev.iface-a", inputs: 4, outputs: ifaceAOutputs),
                      device("dev.iface-b", outputs: 4, presence: .missing)],
                     routes: [route("rte.keys-in", role: "rol.keys-in", device: "dev.iface-a", direction: .input,
                                    binding: .confirmed),
                              route("rte.mic-in", role: "rol.mic-in", device: "dev.iface-a", direction: .input,
                                    channels: [2], binding: .confirmed),
                              route("rte.mains", role: "rol.mains", device: "dev.iface-a", binding: .confirmed),
                              route("rte.space", role: "rol.space", device: "dev.iface-b", channels: [0, 1, 2, 3],
                                    binding: .deviceMissing)],
                     revision: revision)
    }

    static func lostRigRoles() throws -> [ProjectRole] {
        try [role("rol.keys-in", .input, channels: 2), role("rol.mic-in", .input, channels: 1),
             role("rol.mains"), role("rol.space", channels: 4), role("rol.cue")]
    }

    static func lostRigReview() throws -> RigMappingReview {
        try RigMappingReview.make(roles: lostRigRoles(), document: lostRig())
    }

    /// The offered candidate of a role awaiting a choice that starts at `first`.
    static func candidate(_ review: RigMappingReview, _ role: String, first: Int) throws -> RigRouteCandidate {
        let mapping = try #require(review.proposal.mappings.first { $0.role.rawValue == role })
        guard case .awaitingChoice(let offered) = mapping.outcome else { throw RigMappingReviewFixtureError.notPending }
        return try #require(offered.candidates.first { $0.firstChannel == first })
    }

    /// The replacement offered for `role` that starts at `first`.
    static func replacement(_ review: RigMappingReview, _ role: String, first: Int) throws -> RigRouteCandidate {
        let offers = try #require(review.replacementOffers[RoleID(role)])
        return try #require(offers.first { $0.firstChannel == first })
    }

    static func ids(_ raw: [String]) throws -> [RouteID] { try raw.map { try RouteID($0) } }
    static func roles(_ raw: [String]) throws -> [RoleID] { try raw.map { try RoleID($0) } }

    /// The refusal `body` throws, or `nil` when it succeeds. Any other error is recorded as an issue.
    static func refusal(_ body: () throws -> Void) -> RigReviewRefusal? {
        do {
            try body()
            return nil
        } catch let refusal as RigReviewRefusal {
            return refusal
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }
}

private enum RigMappingReviewFixtureError: Error { case notPending }

private typealias Fixture = RigMappingReviewFixture

@Suite("Rig mapping review and apply", .productionAccessAudit)
struct RigMappingReviewTests {
    @Test func reviewListsTheLostRigFixture() throws {
        let review = try Fixture.lostRigReview()
        #expect(review.baseRevision.value == 7)
        #expect(review.pendingChoices == (try Fixture.roles(["rol.cue", "rol.space"])))
        #expect(review.additions.isEmpty && review.unmapped.isEmpty && review.overlaps.isEmpty)
        #expect(review.removalCandidates.map(\.route) == (try Fixture.ids(["rte.space"])))
        #expect(review.removalCandidates.map(\.role.rawValue) == ["rol.space"])
        #expect(review.removalCandidates.map(\.reason) == [.deviceMissing])
        // Three candidates fit rol.space, so it awaits a choice and nothing is held.
        #expect(review.replacementOffers.keys.map(\.rawValue) == ["rol.space"] && review.heldRoles.isEmpty)
        #expect(review.replacementOffers.values.first?.map(\.firstChannel) == [0, 1, 2])
    }

    @Test func keepMutedKeepsTheLostRouteAndChangesNothing() throws {
        let review = try Fixture.lostRigReview()
        let base = try Fixture.lostRig()
        let change = try review.apply(RigMappingDecisions.make(routes: [.keep(RouteID("rte.space"))]), to: base)
        #expect(change.document == base)
        #expect(change.baseRevision == base.revision && change.document.revision == base.revision)
        #expect(change.kept == (try Fixture.ids(["rte.space"])))
        #expect(change.added.isEmpty && change.removed.isEmpty && change.sharedInputs.isEmpty)
        #expect(change.stillUnmapped == (try Fixture.roles(["rol.cue", "rol.space"])))
        // No decision at all is the same as "Keep muted".
        #expect(try review.apply(.empty, to: base) == change)
    }

    @Test func chooseAnotherDeviceReplacesTheLostRouteAtomically() throws {
        let review = try Fixture.lostRigReview()
        let base = try Fixture.lostRig()
        let pick = try Fixture.candidate(review, "rol.space", first: 2)
        let decisions = try RigMappingDecisions.make(routes: [.replace(RouteID("rte.space"), with: pick,
                                                                       id: RouteID("rte.space-a"))])
        let change = try review.apply(decisions, to: base)
        #expect(change.removed == (try Fixture.ids(["rte.space"])))
        #expect(change.added == (try Fixture.ids(["rte.space-a"])))
        #expect(change.kept.isEmpty)
        #expect(change.stillUnmapped == (try Fixture.roles(["rol.cue"])))
        #expect(change.document.routes.map(\.id) == (try Fixture.ids(["rte.keys-in", "rte.mic-in", "rte.mains",
                                                                     "rte.space-a"])))
        let added = try #require(change.document.routes.last)
        #expect(added.binding == .proposed && added.device.rawValue == "dev.iface-a")
        #expect(added.channels == [2, 3, 4, 5] && added.role.rawValue == "rol.space")
        #expect(added.evidence == nil && added.confirmedHost == nil && added.confirmedDeviceUID == nil)
        #expect(change.document.devices == base.devices && change.document.revision == base.revision)
    }

    @Test func aRefusedReplacementRemovesNothing() throws {
        let review = try Fixture.lostRigReview()
        let base = try Fixture.lostRig()
        let wider = try RigMappingReview.make(roles: Fixture.lostRigRoles(),
                                              document: Fixture.lostRig(ifaceAOutputs: 8))
        let notOffered = try Fixture.candidate(wider, "rol.space", first: 4)
        let space = try RouteID("rte.space")
        let unoffered = try RigMappingDecisions.make(routes: [.replace(space, with: notOffered, id: RouteID("rte.x"))])
        #expect(Fixture.refusal { _ = try review.apply(unoffered, to: base) }
                == .mapping(.candidateNotOffered(notOffered)))
        let pick = try Fixture.candidate(review, "rol.space", first: 2)
        let reused = try RigMappingDecisions.make(routes: [.replace(space, with: pick, id: RouteID("rte.mains"))])
        #expect(Fixture.refusal { _ = try review.apply(reused, to: base) }
                == .mapping(.routeIDInUse(try RouteID("rte.mains"))))
    }

    @Test func applyAddsProposedRoutesAfterExistingRoutesInRoleOrder() throws {
        let base = try Fixture.document(
            [Fixture.device("dev.a", inputs: 2, outputs: 2), Fixture.device("dev.b", inputs: 1)],
            routes: [Fixture.route("rte.c", role: "role.c", device: "dev.b", direction: .input, channels: [0],
                                   binding: .confirmed)]
        )
        let roles = try [Fixture.role("role.b"), Fixture.role("role.a", .input),
                         Fixture.role("role.c", .input, channels: 1)]
        let change = try RigMappingReview.make(roles: roles, document: base).apply(.empty, to: base)
        #expect(change.added.map(\.rawValue) == ["route.proposed.role.a", "route.proposed.role.b"])
        #expect(change.document.routes.map(\.id.rawValue)
                == ["rte.c", "route.proposed.role.a", "route.proposed.role.b"])
        #expect(change.document.routes.dropFirst().allSatisfy { $0.binding == .proposed && $0.evidence == nil })
        #expect(change.removed.isEmpty && change.kept.isEmpty && change.stillUnmapped.isEmpty)
    }

    /// Orphan, mismatched, requirement-less and stale routes on one device, with room for every route.
    private static func untidyRig() throws -> (DeviceCapabilityDocument, [ProjectRole]) {
        let base = try Fixture.document([Fixture.device("dev.a", inputs: 2, outputs: 8)], routes: [
            Fixture.route("rte.orphan", role: "role.gone", device: "dev.a", channels: [2, 3], binding: .confirmed),
            Fixture.route("rte.mismatch", role: "role.mains", device: "dev.a", direction: .input, binding: .confirmed),
            Fixture.route("rte.legacy", role: "role.legacy", device: "dev.a", channels: [4, 5], binding: .confirmed),
            Fixture.route("rte.stale", role: "role.mains", device: "dev.a", channels: [6, 7], binding: .stale)
        ])
        return (base, try [Fixture.role("role.mains"), Fixture.role("role.legacy", channels: nil)])
    }

    @Test func routesAreKeptUnlessADecisionRemovesThem() throws {
        let (base, roles) = try Self.untidyRig()
        let review = try RigMappingReview.make(roles: roles, document: base)
        #expect(review.removalCandidates.map(\.route.rawValue)
                == ["rte.legacy", "rte.mismatch", "rte.orphan", "rte.stale"])
        #expect(review.removalCandidates.map(\.reason) == [.noRequirement, .mismatched, .orphan, .stale])
        let change = try review.apply(.empty, to: base)
        #expect(change.document == base && change.removed.isEmpty)
        #expect(change.kept.map(\.rawValue) == ["rte.orphan", "rte.mismatch", "rte.legacy", "rte.stale"])
        try change.document.validate()
    }

    @Test func explicitRemoveTakesOnlyTheNamedRoutesInAnyOrder() throws {
        let (base, roles) = try Self.untidyRig()
        let review = try RigMappingReview.make(roles: roles, document: base)
        let decisions: [RigRouteDecision] = try [.remove(RouteID("rte.mismatch")), .keep(RouteID("rte.legacy")),
                                                 .remove(RouteID("rte.orphan"))]
        let change = try review.apply(RigMappingDecisions.make(routes: decisions), to: base)
        #expect(try review.apply(RigMappingDecisions.make(routes: decisions.reversed()), to: base) == change)
        #expect(change.removed.map(\.rawValue) == ["rte.orphan", "rte.mismatch"])
        #expect(change.kept.map(\.rawValue) == ["rte.legacy", "rte.stale"])
        #expect(change.document.routes.map(\.id.rawValue) == ["rte.legacy", "rte.stale"])
        // role.mains lost its only live route; role.legacy keeps its confirmed one.
        #expect(change.stillUnmapped.map(\.rawValue) == ["role.mains"])
    }

    @Test func removalReasonsFollowTheirPrecedence() throws {
        let base = try Fixture.document([Fixture.device("dev.a", inputs: 2, outputs: 4)], routes: [
            Fixture.route("rte.lost-orphan", role: "role.gone", device: "dev.a", binding: .deviceMissing),
            Fixture.route("rte.legacy-in", role: "role.legacy", device: "dev.a", direction: .input,
                          binding: .confirmed),
            Fixture.route("rte.midi", role: "role.midi", device: "dev.a", channels: [2, 3], binding: .proposed)
        ])
        let roles = try [Fixture.role("role.legacy", channels: nil), Fixture.role("role.midi", signal: .midi)]
        let review = try RigMappingReview.make(roles: roles, document: base)
        #expect(review.removalCandidates.map(\.route.rawValue) == ["rte.legacy-in", "rte.lost-orphan", "rte.midi"])
        #expect(review.removalCandidates.map(\.reason) == [.mismatched, .orphan, .noRequirement])
        #expect(review.unmapped.isEmpty)
    }

    @Test func removingAWorkingRouteIsNotAReviewDecision() throws {
        let review = try Fixture.lostRigReview()
        let base = try Fixture.lostRig()
        let mains = try RouteID("rte.mains")
        #expect(Fixture.refusal { _ = try review.apply(RigMappingDecisions.make(routes: [.remove(mains)]), to: base) }
                == .removeNotCandidate(mains))
        let cue = try Fixture.candidate(review, "rol.cue", first: 2)
        let replace = try RigMappingDecisions.make(routes: [.replace(mains, with: cue, id: RouteID("rte.cue"))])
        #expect(Fixture.refusal { _ = try review.apply(replace, to: base) } == .removeNotCandidate(mains))
        // Keeping it is always fine.
        #expect(try review.apply(RigMappingDecisions.make(routes: [.keep(mains)]), to: base).document == base)
    }

    @Test func unknownRoutesAndForeignReplacementsAreRefused() throws {
        let review = try Fixture.lostRigReview()
        let base = try Fixture.lostRig()
        let nope = try RouteID("rte.nope")
        #expect(Fixture.refusal { _ = try review.apply(RigMappingDecisions.make(routes: [.keep(nope)]), to: base) }
                == .unknownRoute(nope))
        let cue = try Fixture.candidate(review, "rol.cue", first: 2)
        let space = try RouteID("rte.space")
        let foreign = try RigMappingDecisions.make(routes: [.replace(space, with: cue, id: RouteID("rte.cue"))])
        let (spaceRole, cueRole) = try (RoleID("rol.space"), RoleID("rol.cue"))
        #expect(Fixture.refusal { _ = try review.apply(foreign, to: base) }
                == .replaceRoleMismatch(route: space, role: spaceRole, candidateRole: cueRole))
    }

    @Test func aStaleRevisionIsRefused() throws {
        let review = try Fixture.lostRigReview()
        for revision in [6, 8] {
            let document = try Fixture.lostRig(revision: revision)
            #expect(Fixture.refusal { _ = try review.apply(.empty, to: document) }
                    == .staleDocument(base: try ContractRevision(7), found: try ContractRevision(revision)))
        }
    }

    @Test func theResultValidatesAndConfirmsNothing() throws {
        let review = try Fixture.lostRigReview()
        let base = try Fixture.lostRig()
        let cue = try Fixture.candidate(review, "rol.cue", first: 2)
        let change = try review.apply(RigMappingDecisions.make(roles: [.choose(cue, id: RouteID("rte.cue"))]), to: base)
        try change.document.validate()
        var checked = change.document
        checked.routes.removeAll { change.kept.contains($0.id) }
        try checked.validate(roles: review.proposal.requirements)
        let confirmed = change.document.routes.filter { $0.binding == .confirmed }.map(\.id)
        #expect(confirmed == base.routes.filter { $0.binding == .confirmed }.map(\.id))
        #expect(change.added.map(\.rawValue) == ["rte.cue"] && change.stillUnmapped.map(\.rawValue) == ["rol.space"])
    }

    @Test func aSameRevisionDocumentThatChangedIsRefused() throws {
        let review = try Fixture.lostRigReview()
        let revision = try ContractRevision(7)
        // Interface B came back and rte.space works again: removing it is not the reviewed change.
        var revived = try Fixture.lostRig()
        revived.devices[1] = try Fixture.device("dev.iface-b", outputs: 4)
        revived.routes[3].binding = .proposed
        try revived.validate()
        let remove = try RigMappingDecisions.make(routes: [.remove(RouteID("rte.space"))])
        #expect(try review.apply(remove, to: Fixture.lostRig()).removed.map(\.rawValue) == ["rte.space"])
        #expect(Fixture.refusal { _ = try review.apply(remove, to: revived) } == .documentChanged(revision: revision))
        // Any other change at the same revision is refused the same way, before any decision is checked.
        let shrunk = try Fixture.lostRig(ifaceAOutputs: 4)
        var extra = try Fixture.lostRig()
        extra.routes.append(try Fixture.route("rte.extra", role: "rol.extra", device: "dev.iface-a", channels: [4, 5],
                                              binding: .proposed))
        var moved = try Fixture.lostRig()
        moved.routes[3].channels = [1, 2, 3, 0]
        for document in [shrunk, extra, moved] {
            #expect(Fixture.refusal { _ = try review.apply(remove, to: document) }
                    == .documentChanged(revision: revision))
        }
        #expect(review.baseDocument == (try Fixture.lostRig()))
    }

    @Test func leaveUnmappedDeclinesAProposalOrAChoice() throws {
        let base = try Fixture.document([Fixture.device("dev.a", outputs: 4)],
                                        routes: [Fixture.route("rte.mains", role: "role.mains", device: "dev.a",
                                                               binding: .confirmed)])
        let roles = try [Fixture.role("role.mains"), Fixture.role("role.mono", channels: 1),
                         Fixture.role("role.quad", channels: 4), Fixture.role("role.wide", channels: 8),
                         Fixture.role("role.click", signal: .midi)]
        let review = try RigMappingReview.make(roles: roles, document: base)
        #expect(review.additions.map(\.role.rawValue) == ["role.quad"])
        // The single-candidate proposal already writes the mains' outputs.
        #expect(review.overlaps.map(\.channel) == [0, 1] && review.overlaps.allSatisfy { $0.kind == .outputConflict })
        #expect(review.pendingChoices.map(\.rawValue) == ["role.mono"])
        #expect(review.unmapped.map(\.role.rawValue) == ["role.wide"])
        #expect(review.unmapped.map(\.reason) == [.noCompatibleBlock])
        let declined = try RigMappingDecisions.make(roles: [.leaveUnmapped(RoleID("role.quad")),
                                                            .leaveUnmapped(RoleID("role.mono"))])
        let change = try review.apply(declined, to: base)
        #expect(change.added.isEmpty && change.document == base)
        #expect(change.stillUnmapped.map(\.rawValue) == ["role.mono", "role.quad", "role.wide"])
        let mains = try RoleID("role.mains")
        let keepMains = try RigMappingDecisions.make(roles: [.leaveUnmapped(mains)])
        #expect(Fixture.refusal { _ = try review.apply(keepMains, to: base) } == .declineNotOffered(mains))
        let ghost = try RoleID("role.ghost")
        let ghostly = try RigMappingDecisions.make(roles: [.leaveUnmapped(ghost)])
        #expect(Fixture.refusal { _ = try review.apply(ghostly, to: base) } == .mapping(.unknownRole(ghost)))
    }

    @Test func duplicateDecisionsAreRefused() throws {
        let review = try Fixture.lostRigReview()
        let space = try RouteID("rte.space")
        let pick = try Fixture.candidate(review, "rol.space", first: 2)
        #expect(Fixture.refusal { _ = try RigMappingDecisions.make(routes: [.keep(space), .remove(space)]) }
                == .duplicateDecision(.route(space)))
        let (zeta, alpha) = try (RouteID("rte.zeta"), RouteID("rte.alpha"))
        #expect(Fixture.refusal {
            _ = try RigMappingDecisions.make(routes: [.keep(zeta), .keep(alpha), .keep(zeta), .remove(alpha)])
        } == .duplicateDecision(.route(alpha)))
        let role = try RoleID("rol.space")
        #expect(Fixture.refusal {
            _ = try RigMappingDecisions.make(roles: [.choose(pick, id: RouteID("rte.a")), .leaveUnmapped(role)])
        } == .duplicateDecision(.role(role)))
        #expect(Fixture.refusal {
            _ = try RigMappingDecisions.make(routes: [.replace(space, with: pick, id: RouteID("rte.a"))],
                                             roles: [.choose(pick, id: RouteID("rte.b"))])
        } == .duplicateDecision(.role(role)))
    }

    @Test func decisionCountsAreBounded() throws {
        let limit = DeviceCapabilityLimits.routes
        let keeps = try (0...limit).map { try RigRouteDecision.keep(RouteID("rte.\($0)")) }
        #expect(try RigMappingDecisions.make(routes: Array(keeps.prefix(limit))).routes.count == limit)
        #expect(Fixture.refusal { _ = try RigMappingDecisions.make(routes: keeps) }
                == .tooManyDecisions(count: limit + 1, maximum: limit))
        let roleLimit = RigMappingLimits.roles
        let declines = try (0...roleLimit).map { try RigRoleDecision.leaveUnmapped(RoleID("rol.\($0)")) }
        #expect(try RigMappingDecisions.make(roles: Array(declines.prefix(roleLimit))).roles.count == roleLimit)
        #expect(Fixture.refusal { _ = try RigMappingDecisions.make(roles: declines) }
                == .tooManyDecisions(count: roleLimit + 1, maximum: roleLimit))
    }

    @Test func mappingRefusalsAreLiftedAndLeaveTheReviewUnchanged() throws {
        let roles = try Fixture.lostRigRoles()
        let rig = try Fixture.lostRig()
        #expect(Fixture.refusal { _ = try RigMappingReview.make(roles: roles + [roles[0]], document: rig) }
                == .mapping(.duplicateRole(try RoleID("rol.keys-in"))))
        let review = try Fixture.lostRigReview()
        let before = review
        let wider = try RigMappingReview.make(roles: roles, document: Fixture.lostRig(ifaceAOutputs: 8))
        let notOffered = try Fixture.candidate(wider, "rol.cue", first: 6)
        #expect(Fixture.refusal { _ = try review.choosing(notOffered, id: RouteID("rte.cue")) }
                == .mapping(.candidateNotOffered(notOffered)))
        #expect(Fixture.refusal { _ = try review.apply(.empty, to: Fixture.lostRig(revision: 8)) } != nil)
        #expect(review == before)
        let cue = try Fixture.candidate(review, "rol.cue", first: 2)
        let chosen = try review.choosing(cue, id: RouteID("rte.cue"))
        #expect(review == before && chosen.additions.map(\.id.rawValue) == ["rte.cue"])
        #expect(chosen.pendingChoices.map(\.rawValue) == ["rol.space"])
    }

    @Test func fallbackOffersExposeTruncation() throws {
        let route = try Fixture.route("rte.mono-mismatch", role: "role.mono-truncation", device: "dev.present",
                                      channels: [0, 1], binding: .confirmed)
        let base = try Fixture.document([Fixture.device("dev.present", outputs: 100)], routes: [route])
        let role = try RoleID("role.mono-truncation")
        let review = try RigMappingReview.make(roles: [Fixture.role(role.rawValue, channels: 1)], document: base)
        let offers = try #require(review.replacementOffers[role])
        let truncation = try #require(review.replacementTruncations[role])
        #expect(offers.count == 64)
        #expect(truncation.listed == 64 && truncation.total == 100 && truncation.omitted == 36)

        let replacementID = try RouteID("rte.mono-replacement")
        let firstOffer = try #require(offers.first)
        let decision = try RigMappingDecisions.make(
            routes: [.replace(route.id, with: firstOffer, id: replacementID)]
        )
        let change = try review.apply(decision, to: base)
        #expect(change.removed == [route.id] && change.added == [replacementID])
        #expect(change.document.routes.last?.channels == [0])
    }

    @Test func proposalOffersExposeTruncation() throws {
        let role = try RoleID("role.missing-truncation")
        let base = try Fixture.document(
            [
                Fixture.device("dev.lost", outputs: 1, presence: .missing),
                Fixture.device("dev.present", outputs: 100)
            ],
            routes: [Fixture.route("rte.missing-truncation", role: role.rawValue, device: "dev.lost", channels: [0],
                                   binding: .deviceMissing)]
        )
        let review = try RigMappingReview.make(roles: [Fixture.role(role.rawValue, channels: 1)], document: base)
        let offers = try #require(review.replacementOffers[role])
        let truncation = try #require(review.replacementTruncations[role])
        #expect(review.pendingChoices == [role] && offers.count == 64)
        #expect(truncation.listed == 64 && truncation.total == 100 && truncation.omitted == 36)
    }

    @Test func offerTruncationAt64Boundary() throws {
        let role = try RoleID("role.truncation-boundary")
        let limit = RigMappingLimits.candidatesPerRole
        let exact = try Self.replacementReview(outputs: limit)
        #expect(limit == 64 && exact.replacementOffers[role]?.count == limit)
        #expect(exact.replacementTruncations[role] == nil)

        let over = try Self.replacementReview(outputs: limit + 1)
        let truncation = try #require(over.replacementTruncations[role])
        #expect(over.replacementOffers[role]?.count == limit)
        #expect(truncation.listed == limit && truncation.total == limit + 1 && truncation.omitted == 1)
    }

    @Test func completeAndHeldOffersHaveNoTruncation() throws {
        let role = try RoleID("role.truncation-boundary")
        let fewer = try Self.replacementReview(outputs: 10)
        #expect(fewer.pendingChoices == [role] && fewer.replacementOffers[role]?.count == 10)
        #expect(fewer.replacementTruncations[role] == nil)

        let held = try Self.replacementReview(outputs: 1)
        #expect(held.heldRoles == [role] && held.replacementOffers[role]?.count == 1)
        #expect(held.replacementTruncations[role] == nil)
    }

    @Test func choosingClearsOneTruncation() throws {
        let first = try RoleID("role.alpha-truncation")
        let second = try RoleID("role.beta-truncation")
        let base = try Fixture.document(
            [
                Fixture.device("dev.lost", outputs: 1, presence: .missing),
                Fixture.device("dev.present", outputs: 100)
            ],
            routes: [
                Fixture.route("rte.alpha-lost", role: first.rawValue, device: "dev.lost", channels: [0],
                              binding: .deviceMissing),
                Fixture.route("rte.beta-lost", role: second.rawValue, device: "dev.lost", channels: [0],
                              binding: .deviceMissing)
            ]
        )
        let roles = try [Fixture.role(first.rawValue, channels: 1), Fixture.role(second.rawValue, channels: 1)]
        let review = try RigMappingReview.make(roles: roles, document: base)
        let before = review
        #expect(Set(review.replacementTruncations.keys) == Set([first, second]))
        let offer = try #require(review.replacementOffers[first]?.first)
        let chosen = try review.choosing(offer, id: RouteID("rte.alpha-choice"))
        #expect(chosen.replacementTruncations[first] == nil)
        #expect(chosen.replacementTruncations[second] == review.replacementTruncations[second])
        #expect(Set(chosen.replacementTruncations.keys) == Set([second]))
        #expect(chosen.replacementOffers[first] == nil && chosen.replacementOffers[second] != nil)
        #expect(review == before)
    }

    private static func replacementReview(outputs: Int) throws -> RigMappingReview {
        let role = "role.truncation-boundary"
        let base = try Fixture.document(
            [
                Fixture.device("dev.lost", outputs: 1, presence: .missing),
                Fixture.device("dev.present", outputs: outputs)
            ],
            routes: [Fixture.route("rte.boundary-lost", role: role, device: "dev.lost", channels: [0],
                                   binding: .deviceMissing)]
        )
        return try RigMappingReview.make(roles: [Fixture.role(role, channels: 1)], document: base)
    }
}
