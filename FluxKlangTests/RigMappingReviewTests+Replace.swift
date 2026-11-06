import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = RigMappingReviewFixture

@Suite("Rig mapping review: replacement offers")
struct RigMappingReviewReplaceTests {
    /// A muted `rte.space` on missing `dev.b` whose role fits exactly one block of present `dev.a`.
    private static func singleCandidateRig(_ binding: RouteBinding) throws -> DeviceCapabilityDocument {
        try Fixture.document([Fixture.device("dev.a", outputs: 4),
                              Fixture.device("dev.b", outputs: 4, presence: .missing)],
                             routes: [Fixture.route("rte.space", role: "rol.space", device: "dev.b",
                                                    channels: [0, 1, 2, 3], binding: binding)])
    }

    private static func spaceRoles() throws -> [ProjectRole] { try [Fixture.role("rol.space", channels: 4)] }

    fileprivate struct HeldOfferChoiceFixture {
        let document: DeviceCapabilityDocument
        let review: RigMappingReview
        let inputRoles: [RoleID]
        let choices: [RoleID: RigRouteCandidate]
        let choiceIDs: [RoleID: RouteID]
        let outputRole: RoleID
        let outputRoute: RouteID
    }

    fileprivate static func heldOfferChoiceFixture(
        _ inputNames: [String], withCapacityProposal: Bool = false
    ) throws -> HeldOfferChoiceFixture {
        let limit = DeviceCapabilityLimits.routes
        let fillers = try (1..<(limit - 1)).map { index in
            try Fixture.route("rte.fill.\(index)", role: "role.fill.\(index)", device: "dev.fill",
                              direction: .input, channels: [0], binding: .stale)
        }
        let outputRole = try RoleID("role.z-output")
        let outputRoute = try RouteID("rte.output-lost")
        let document = try Fixture.document([Fixture.device("dev.in-a", inputs: 1),
                                             Fixture.device("dev.in-b", inputs: 4),
                                             Fixture.device("dev.fill", inputs: 1),
                                             Fixture.device("dev.lost", outputs: 1, presence: .missing),
                                             Fixture.device("dev.out", outputs: 1)],
                                            routes: [Fixture.route(outputRoute.rawValue, role: outputRole.rawValue,
                                                                   device: "dev.lost", channels: [0],
                                                                   binding: .deviceMissing)] + fillers)
        let inputRoles = try inputNames.map { try RoleID($0) }
        let inputRolesForFixture = try inputNames.map { try Fixture.role($0, .input, channels: 1) }
        let roles = try inputRolesForFixture
            + (withCapacityProposal ? [Fixture.role("role.b-auto", .input, channels: 4)] : [])
            + [Fixture.role(outputRole.rawValue, channels: 1)]
        let review = try RigMappingReview.make(roles: roles, document: document)
        let choices = try Dictionary(uniqueKeysWithValues: inputRoles.map {
            ($0, try Fixture.candidate(review, $0.rawValue, first: 0))
        })
        let choiceIDs = try Dictionary(uniqueKeysWithValues: inputRoles.map {
            ($0, try RouteID("rte.choice.\($0.rawValue)"))
        })
        return HeldOfferChoiceFixture(document: document, review: review, inputRoles: inputRoles,
                                      choices: choices, choiceIDs: choiceIDs, outputRole: outputRole,
                                      outputRoute: outputRoute)
    }

    @Test(arguments: [RouteBinding.deviceMissing, .stale])
    func aSingleCandidateIsHeldAsAnOfferNotAdded(_ binding: RouteBinding) throws {
        let base = try Self.singleCandidateRig(binding)
        let review = try RigMappingReview.make(roles: Self.spaceRoles(), document: base)
        #expect(review.additions.isEmpty && review.pendingChoices.isEmpty && review.overlaps.isEmpty)
        #expect(review.heldRoles.map(\.rawValue) == ["rol.space"])
        let offer = try Fixture.replacement(review, "rol.space", first: 0)
        #expect(review.replacementOffers[try RoleID("rol.space")] == [offer])
        #expect(offer.device.rawValue == "dev.a" && offer.channels == [0, 1, 2, 3])
        // "Keep muted", or no decision: nothing is added and the role stays unmapped.
        let keep = try review.apply(RigMappingDecisions.make(routes: [.keep(RouteID("rte.space"))]), to: base)
        #expect(keep.document == base && keep.added.isEmpty && keep.removed.isEmpty)
        #expect(keep.kept.map(\.rawValue) == ["rte.space"] && keep.stillUnmapped.map(\.rawValue) == ["rol.space"])
        #expect(try review.apply(.empty, to: base) == keep)
        // "Remove": the route goes and the role stays unmapped.
        let remove = try review.apply(RigMappingDecisions.make(routes: [.remove(RouteID("rte.space"))]), to: base)
        #expect(remove.removed.map(\.rawValue) == ["rte.space"] && remove.added.isEmpty)
        #expect(remove.document.routes.isEmpty && remove.stillUnmapped.map(\.rawValue) == ["rol.space"])
    }

    @Test(arguments: [RouteBinding.deviceMissing, .stale])
    func chooseAnotherDeviceBindsTheSingleCandidate(_ binding: RouteBinding) throws {
        let base = try Self.singleCandidateRig(binding)
        let review = try RigMappingReview.make(roles: Self.spaceRoles(), document: base)
        let offer = try Fixture.replacement(review, "rol.space", first: 0)
        let replace = try RigMappingDecisions.make(routes: [.replace(RouteID("rte.space"), with: offer,
                                                                     id: RouteID("rte.space-a"))])
        let change = try review.apply(replace, to: base)
        #expect(change.removed.map(\.rawValue) == ["rte.space"] && change.added.map(\.rawValue) == ["rte.space-a"])
        #expect(change.kept.isEmpty && change.stillUnmapped.isEmpty)
        #expect(change.document.routes.count == 1)
        let added = try #require(change.document.routes.first)
        #expect(added.binding == .proposed && added.device.rawValue == "dev.a" && added.channels == [0, 1, 2, 3])
        #expect(added.evidence == nil && added.confirmedHost == nil)
        // The held candidate is a replacement only: it cannot be chosen beside the muted route.
        let choose = try RigMappingDecisions.make(roles: [.choose(offer, id: RouteID("rte.space-a"))])
        #expect(Fixture.refusal { _ = try review.apply(choose, to: base) } == .mapping(.candidateNotOffered(offer)))
        #expect(Fixture.refusal { _ = try review.choosing(offer, id: RouteID("rte.space-a")) }
                == .mapping(.candidateNotOffered(offer)))
    }

    @Test func aChoiceForAnOfferedRoleEndsItsOffer() throws {
        let review = try Fixture.lostRigReview()
        let base = try Fixture.lostRig()
        let (pick, other) = try (Fixture.candidate(review, "rol.space", first: 2),
                                 Fixture.candidate(review, "rol.space", first: 1))
        // Choosing beside the muted route adds the choice and keeps the route.
        let decisions = try RigMappingDecisions.make(roles: [.choose(pick, id: RouteID("rte.space-a"))])
        let change = try review.apply(decisions, to: base)
        #expect(change.added.map(\.rawValue) == ["rte.space-a"] && change.kept.map(\.rawValue) == ["rte.space"])
        let chosen = try review.choosing(pick, id: RouteID("rte.space-a"))
        #expect(chosen.additions.map(\.id.rawValue) == ["rte.space-a"] && chosen.replacementOffers.isEmpty)
        #expect(try chosen.apply(.empty, to: base) == change)
        // The role is no longer offered for replacement.
        let replace = try RigMappingDecisions.make(routes: [.replace(RouteID("rte.space"), with: other,
                                                                     id: RouteID("rte.space-b"))])
        #expect(Fixture.refusal { _ = try chosen.apply(replace, to: base) } == .mapping(.candidateNotOffered(other)))
    }

    @Test func aMismatchedRouteCanBeReplaced() throws {
        let base = try Fixture.document([Fixture.device("dev.a", inputs: 2, outputs: 8)], routes: [
            Fixture.route("rte.mismatch", role: "role.mains", device: "dev.a", direction: .input, binding: .confirmed),
            Fixture.route("rte.stale", role: "role.mains", device: "dev.a", channels: [6, 7], binding: .stale)
        ])
        let review = try RigMappingReview.make(roles: [Fixture.role("role.mains")], document: base)
        #expect(review.removalCandidates.map(\.reason) == [.mismatched, .stale])
        #expect(review.additions.isEmpty && review.pendingChoices.isEmpty && review.heldRoles.isEmpty)
        #expect(review.replacementOffers[try RoleID("role.mains")]?.map(\.firstChannel) == Array(0...6))
        let offer = try Fixture.replacement(review, "role.mains", first: 2)
        let replace = try RigMappingDecisions.make(routes: [.replace(RouteID("rte.mismatch"), with: offer,
                                                                     id: RouteID("rte.mains"))])
        let change = try review.apply(replace, to: base)
        #expect(change.removed.map(\.rawValue) == ["rte.mismatch"] && change.added.map(\.rawValue) == ["rte.mains"])
        #expect(change.kept.map(\.rawValue) == ["rte.stale"] && change.stillUnmapped.isEmpty)
        #expect(change.document.routes.map(\.id.rawValue) == ["rte.stale", "rte.mains"])
        #expect(change.document.routes.last?.channels == [2, 3] && change.document.routes.last?.binding == .proposed)
        // A role that keeps a fitting route beside the mismatched one gets no offer.
        var fitting = base
        fitting.routes.append(try Fixture.route("rte.ok", role: "role.mains", device: "dev.a", channels: [4, 5],
                                                binding: .confirmed))
        let routed = try RigMappingReview.make(roles: [Fixture.role("role.mains")], document: fitting)
        #expect(routed.removalCandidates.map(\.route.rawValue) == ["rte.mismatch", "rte.stale"])
        #expect(routed.replacementOffers.isEmpty)
        let refused = try RigMappingDecisions.make(routes: [.replace(RouteID("rte.mismatch"), with: offer,
                                                                     id: RouteID("rte.mains"))])
        #expect(Fixture.refusal { _ = try routed.apply(refused, to: fitting) } == .mapping(.candidateNotOffered(offer)))
    }

    @Test func aReplaceIsAcceptedAtFullRouteCapacity() throws {
        let limit = DeviceCapabilityLimits.routes
        let fillers = try (1..<limit).map { index in
            try Fixture.route("rte.\(index)", role: "role.\(index)", device: "dev.in", direction: .input,
                              channels: [0], binding: .proposed)
        }
        var base = try Self.singleCandidateRig(.deviceMissing)
        base.devices.append(try Fixture.device("dev.in", inputs: 1))
        base.routes += fillers
        #expect(base.routes.count == limit)
        let review = try RigMappingReview.make(roles: Self.spaceRoles(), document: base)
        // RG1 has no budget left at the limit; the offer comes from the document without the muted route.
        #expect(review.unmapped.map(\.reason) == [.routeCapacityExhausted(limit: limit)])
        let offer = try Fixture.replacement(review, "rol.space", first: 0)
        let replace = try RigMappingDecisions.make(routes: [.replace(RouteID("rte.space"), with: offer,
                                                                     id: RouteID("rte.space-a"))])
        let change = try review.apply(replace, to: base)
        #expect(change.document.routes.count == limit && change.added.map(\.rawValue) == ["rte.space-a"])
        #expect(change.stillUnmapped.isEmpty && change.kept.count == limit - 1)
    }

    @Test func aChoiceFitsWhenTheOnlyProposalIsHeldForReplacement() throws {
        let limit = DeviceCapabilityLimits.routes
        let fixture = try Self.heldOfferChoiceFixture(["role.a-input"])
        let inputRole = try #require(fixture.inputRoles.first)
        let choice = try #require(fixture.choices[inputRole])
        let choiceID = try #require(fixture.choiceIDs[inputRole])
        #expect(fixture.document.routes.count == limit - 1)
        #expect(fixture.review.pendingChoices == [inputRole])
        #expect(fixture.review.heldRoles == [fixture.outputRole])
        #expect(fixture.review.replacementOffers[fixture.outputRole]?.count == 1)
        #expect(Fixture.refusal { _ = try fixture.review.choosing(choice, id: fixture.outputRoute) }
                == .mapping(.routeIDInUse(fixture.outputRoute)))
        let reusedID = try RigMappingDecisions.make(roles: [.choose(choice, id: fixture.outputRoute)])
        #expect(Fixture.refusal { _ = try fixture.review.apply(reusedID, to: fixture.document) }
                == .mapping(.routeIDInUse(fixture.outputRoute)))

        let chosen = try fixture.review.choosing(choice, id: choiceID)
        #expect(chosen.additions.map(\.id) == [choiceID])
        #expect(chosen.heldRoles == [fixture.outputRole] && chosen.pendingChoices.isEmpty)
        #expect(fixture.review.additions.isEmpty && fixture.review.pendingChoices == [inputRole])

        let decisions = try RigMappingDecisions.make(roles: [.choose(choice, id: choiceID)])
        let change = try fixture.review.apply(decisions, to: fixture.document)
        #expect(change.document.routes.count == limit && change.added == [choiceID])
        #expect(change.kept.contains(fixture.outputRoute) && change.removed.isEmpty)
        #expect(change.stillUnmapped.contains(fixture.outputRole))
        #expect(change.document.routes.first { $0.id == fixture.outputRoute }?.binding == .deviceMissing)
    }

    @Test func choicesRespectThe4096And4097FinalRouteBoundaries() throws {
        let limit = DeviceCapabilityLimits.routes
        let fixture = try Self.heldOfferChoiceFixture(["role.a-input", "role.b-input"])
        let firstRole = try #require(fixture.inputRoles.first)
        let secondRole = try #require(fixture.inputRoles.last)
        let firstChoice = try #require(fixture.choices[firstRole])
        let secondChoice = try #require(fixture.choices[secondRole])
        let firstID = try #require(fixture.choiceIDs[firstRole])
        let secondID = try #require(fixture.choiceIDs[secondRole])
        let originalReview = fixture.review

        let first = try fixture.review.choosing(firstChoice, id: firstID)
        #expect(first.additions.map(\.id) == [firstID] && fixture.document.routes.count + 1 == limit)
        #expect(Fixture.refusal { _ = try first.choosing(secondChoice, id: secondID) }
                == .mapping(.routeCapacityExhausted(limit: limit)))
        #expect(first.pendingChoices == [secondRole] && fixture.review == originalReview)

        let choices = try RigMappingDecisions.make(roles: [
            .choose(firstChoice, id: firstID), .choose(secondChoice, id: secondID)
        ])
        #expect(Fixture.refusal { _ = try fixture.review.apply(choices, to: fixture.document) }
                == .mapping(.routeCapacityExhausted(limit: limit)))
        #expect(fixture.review == originalReview && fixture.document.routes.count == limit - 1)

        let exactCapacity = try RigMappingDecisions.make(roles: [.choose(firstChoice, id: firstID)])
        let change = try fixture.review.apply(exactCapacity, to: fixture.document)
        #expect(change.document.routes.count == limit && change.added == [firstID])
    }

    @Test func replacingTheHeldRouteCountsTheFinalCandidate() throws {
        let limit = DeviceCapabilityLimits.routes
        let fixture = try Self.heldOfferChoiceFixture(["role.a-input"])
        let inputRole = try #require(fixture.inputRoles.first)
        let choice = try #require(fixture.choices[inputRole])
        let choiceID = try #require(fixture.choiceIDs[inputRole])
        let offer = try Fixture.replacement(fixture.review, fixture.outputRole.rawValue, first: 0)
        let replacementID = try RouteID("rte.output-replacement")
        let replace = try RigMappingDecisions.make(
            routes: [.replace(fixture.outputRoute, with: offer, id: replacementID)],
            roles: [.choose(choice, id: choiceID)]
        )
        let replaced = try fixture.review.apply(replace, to: fixture.document)
        try replaced.document.validate()
        #expect(replaced.document.routes.count == limit)
        #expect(replaced.removed == [fixture.outputRoute] && replaced.added == [choiceID, replacementID])
        #expect(!replaced.stillUnmapped.contains(fixture.outputRole))

        let declined = try RigMappingDecisions.make(roles: [
            .choose(choice, id: choiceID), .leaveUnmapped(fixture.outputRole)
        ])
        let declinedChange = try fixture.review.apply(declined, to: fixture.document)
        #expect(declinedChange.document.routes.count == limit)
        #expect(declinedChange.kept.contains(fixture.outputRoute))
        #expect(declinedChange.stillUnmapped.contains(fixture.outputRole))
    }

    @Test func removingAMismatchedRouteMakesRoomForAnApplyChoice() throws {
        let limit = DeviceCapabilityLimits.routes
        let fillers = try (1..<(limit - 1)).map { index in
            try Fixture.route("rte.fill.\(index)", role: "role.fill.\(index)", device: "dev.fill",
                              direction: .input, channels: [0], binding: .stale)
        }
        let mismatchID = try RouteID("rte.mismatch")
        let inputRole = try RoleID("role.a-input")
        let autoRole = try RoleID("role.b-auto")
        let outputRole = try RoleID("role.z-output")
        let base = try Fixture.document([Fixture.device("dev.in-a", inputs: 2),
                                         Fixture.device("dev.in-b", inputs: 2),
                                         Fixture.device("dev.fill", inputs: 1),
                                         Fixture.device("dev.auto", outputs: 1)],
                                        routes: [Fixture.route(mismatchID.rawValue, role: outputRole.rawValue,
                                                               device: "dev.in-a", direction: .input,
                                                               channels: [0], binding: .confirmed)] + fillers)
        let roles = try [Fixture.role(inputRole.rawValue, .input, channels: 1),
                         Fixture.role(autoRole.rawValue, channels: 1),
                         Fixture.role(outputRole.rawValue, channels: 1)]
        let review = try RigMappingReview.make(roles: roles, document: base)
        let choice = try Fixture.candidate(review, inputRole.rawValue, first: 0)
        let choiceID = try RouteID("rte.input-choice")
        #expect(base.routes.count == limit - 1)
        #expect(review.pendingChoices.map(\.rawValue) == [inputRole.rawValue])
        #expect(review.additions.map(\.role.rawValue) == [autoRole.rawValue])
        #expect(Fixture.refusal { _ = try review.choosing(choice, id: choiceID) }
                == .mapping(.routeCapacityExhausted(limit: limit)))

        let decisions = try RigMappingDecisions.make(routes: [.remove(mismatchID)],
                                                     roles: [.choose(choice, id: choiceID)])
        let change = try review.apply(decisions, to: base)
        try change.document.validate()
        #expect(change.document.routes.count == limit)
        #expect(change.removed == [mismatchID] && change.added.count == 2)
        #expect(change.added.contains(choiceID) && change.added.contains(where: { $0 != choiceID }))
    }

    @Test func twoLostRolesCanBeReplacedAtFullRouteCapacity() throws {
        let limit = DeviceCapabilityLimits.routes
        let fillers = try (1..<(limit - 1)).map { index in
            try Fixture.route("rte.fill.\(index)", role: "role.fill.\(index)", device: "dev.fill",
                              direction: .input, channels: [0], binding: .stale)
        }
        let base = try Fixture.document([Fixture.device("dev.a", outputs: 1),
                                         Fixture.device("dev.b", outputs: 1),
                                         Fixture.device("dev.fill", inputs: 1),
                                         Fixture.device("dev.missing", outputs: 1, presence: .missing)],
                                        routes: [
                                            Fixture.route("rte.a-lost", role: "role.a", device: "dev.missing",
                                                          channels: [0], binding: .deviceMissing),
                                            Fixture.route("rte.b-lost", role: "role.b", device: "dev.missing",
                                                          channels: [0], binding: .deviceMissing)
                                        ] + fillers)
        let roles = try [Fixture.role("role.a", channels: 1), Fixture.role("role.b", channels: 1)]
        #expect(base.routes.count == limit)

        let review = try RigMappingReview.make(roles: roles, document: base)
        let offersA = try #require(review.replacementOffers[RoleID("role.a")])
        let offersB = try #require(review.replacementOffers[RoleID("role.b")])
        let offerA = try #require(offersA.first { $0.device.rawValue == "dev.a" })
        let offerB = try #require(offersB.first { $0.device.rawValue == "dev.b" })
        #expect(offerA.role.rawValue == "role.a" && offerB.role.rawValue == "role.b")

        // Both valid swaps are net-zero together: applying them must not surface a route-capacity refusal.
        let decisions = try RigMappingDecisions.make(routes: [
            .replace(try RouteID("rte.a-lost"), with: offerA, id: try RouteID("rte.a-new")),
            .replace(try RouteID("rte.b-lost"), with: offerB, id: try RouteID("rte.b-new"))
        ])
        let change = try review.apply(decisions, to: base)
        #expect(change.document.routes.count == base.routes.count)
        #expect(change.added.map(\.rawValue) == ["rte.a-new", "rte.b-new"])
        #expect(change.removed.map(\.rawValue) == ["rte.a-lost", "rte.b-lost"])
        #expect(change.stillUnmapped.isEmpty)
    }

    @Test func aRoleOrderedCapacityMissCanBeRetriedAfterRemovingAnotherRoute() throws {
        let limit = DeviceCapabilityLimits.routes
        let fillers = try (1..<limit).map { index in
            try Fixture.route("rte.fill.\(index)", role: "role.fill.\(index)", device: "dev.in",
                              direction: .input, channels: [0], binding: .stale)
        }
        let base = try Fixture.document([Fixture.device("dev.a", outputs: 4),
                                         Fixture.device("dev.b", outputs: 4, presence: .missing),
                                         Fixture.device("dev.in", inputs: 1)],
                                        routes: [Fixture.route("rte.space", role: "rol.space", device: "dev.b",
                                                               channels: [0, 1, 2, 3], binding: .deviceMissing)]
                                            + fillers)
        let roles = try [Fixture.role("rol.a", .input, channels: 1), Fixture.role("rol.space", channels: 4)]
        let spaceRoute = try RouteID("rte.space")
        let fillerRoute = try RouteID("rte.fill.1")
        let recoveredRoute = try RouteID("rte.space-recovered")
        #expect(base.routes.count == limit)

        let full = try RigMappingReview.make(roles: roles, document: base)
        #expect(full.replacementOffers[try RoleID("rol.space")] == nil)

        // A later review with one route freed supplies the candidate; the full review must refuse that
        // candidate rather than silently accepting a replacement it did not offer.
        var retryBase = base
        retryBase.routes.removeAll { $0.id == fillerRoute }
        let retry = try RigMappingReview.make(roles: roles, document: retryBase)
        let offer = try Fixture.replacement(retry, "rol.space", first: 0)
        let replace = try RigMappingDecisions.make(routes: [.replace(spaceRoute, with: offer,
                                                                     id: RouteID("rte.space-retried"))])
        #expect(Fixture.refusal { _ = try full.apply(replace, to: base) }
                == .mapping(.candidateNotOffered(offer)))

        // Remove one other orphan route and review again: the earlier single-candidate role consumes
        // one budget slot, and rol.space now receives the next one.
        let remove = try RigMappingDecisions.make(routes: [.remove(fillerRoute)])
        let removed = try full.apply(remove, to: base)
        let reviewedAgain = try RigMappingReview.make(roles: roles, document: removed.document)
        let recoveredOffer = try Fixture.replacement(reviewedAgain, "rol.space", first: 0)
        let recoveredReplace = try RigMappingDecisions.make(routes: [
            .replace(spaceRoute, with: recoveredOffer, id: recoveredRoute)
        ])
        let recovered = try reviewedAgain.apply(recoveredReplace, to: removed.document)
        #expect(recovered.document.routes.count == limit)
        #expect(recovered.added.map(\.rawValue).contains(recoveredRoute.rawValue))
        #expect(recovered.removed.map(\.rawValue) == [spaceRoute.rawValue] && recovered.stillUnmapped.isEmpty)
    }
}

@Suite("Rig mapping review: choice capacity accounting")
struct RigMappingReviewCapacityTests {
    @Test func decliningAnAutoProposalCreditsChoiceCapacity() throws {
        let limit = DeviceCapabilityLimits.routes
        let fixture = try RigMappingReviewReplaceTests.heldOfferChoiceFixture(
            ["role.a-input"], withCapacityProposal: true
        )
        let role = try RoleID("role.a-input")
        let choice = try #require(fixture.choices[role])
        let choiceID = try #require(fixture.choiceIDs[role])
        #expect(fixture.document.routes.count == limit - 1)
        #expect(fixture.review.pendingChoices == [role])
        #expect(fixture.review.additions.map(\.role.rawValue) == ["role.b-auto"])
        #expect(fixture.review.replacementOffers[fixture.outputRole]?.count == 1)
        let chooseOnly = try RigMappingDecisions.make(roles: [.choose(choice, id: choiceID)])
        #expect(Fixture.refusal { _ = try fixture.review.apply(chooseOnly, to: fixture.document) }
                == .mapping(.routeCapacityExhausted(limit: limit)))

        let declineAuto = try RigMappingDecisions.make(roles: [
            .choose(choice, id: choiceID), .leaveUnmapped(try RoleID("role.b-auto"))
        ])
        let change = try fixture.review.apply(declineAuto, to: fixture.document)
        #expect(change.document.routes.count == limit && change.added == [choiceID])
    }

    @Test func replacingHeldRouteDoesNotCreditItsSlotForTwoChoices() throws {
        let limit = DeviceCapabilityLimits.routes
        let fixture = try RigMappingReviewReplaceTests.heldOfferChoiceFixture(
            ["role.a-input", "role.b-input"]
        )
        let first = try RoleID("role.a-input")
        let second = try RoleID("role.b-input")
        let firstChoice = try #require(fixture.choices[first])
        let secondChoice = try #require(fixture.choices[second])
        let offer = try Fixture.replacement(fixture.review, fixture.outputRole.rawValue, first: 0)
        let decisions = try RigMappingDecisions.make(
            routes: [.replace(fixture.outputRoute, with: offer, id: try RouteID("rte.output-replacement"))],
            roles: [
                .choose(firstChoice, id: try #require(fixture.choiceIDs[first])),
                .choose(secondChoice, id: try #require(fixture.choiceIDs[second]))
            ]
        )
        #expect(Fixture.refusal { _ = try fixture.review.apply(decisions, to: fixture.document) }
                == .mapping(.routeCapacityExhausted(limit: limit)))
    }

    @Test func decliningCountsOnlyRoutesThatRemainSelectedAtCapacity() throws {
        let limit = DeviceCapabilityLimits.routes
        let fixture = try RigMappingReviewReplaceTests.heldOfferChoiceFixture(
            ["role.a-input", "role.b-input"]
        )
        let before = fixture.review
        let first = try RoleID("role.a-input")
        let second = try RoleID("role.b-input")
        let firstChoice = try #require(fixture.choices[first])
        let secondChoice = try #require(fixture.choices[second])
        let firstID = try #require(fixture.choiceIDs[first])
        let secondID = try #require(fixture.choiceIDs[second])
        let held = fixture.outputRole
        #expect(fixture.document.routes.count == limit - 1)

        let selected = try before.choosing(secondChoice, id: secondID)
        let selectedBefore = selected
        let exact = try RigMappingDecisions.make(roles: [
            .choose(firstChoice, id: firstID), .leaveUnmapped(second), .leaveUnmapped(held)
        ])
        let change = try selected.apply(exact, to: fixture.document)
        #expect(change.document.routes.count == limit && change.added == [firstID])
        #expect(change.stillUnmapped.contains(second) && change.stillUnmapped.contains(held))
        #expect(selected == selectedBefore && fixture.review == before)

        let overLimit = try RigMappingDecisions.make(roles: [
            .choose(firstChoice, id: firstID), .choose(secondChoice, id: secondID), .leaveUnmapped(held)
        ])
        #expect(Fixture.refusal { _ = try before.apply(overLimit, to: fixture.document) }
                == .mapping(.routeCapacityExhausted(limit: limit)))
        #expect(fixture.review == before && selected == selectedBefore)
        #expect(fixture.document.routes.count == limit - 1)
    }
}
