//
//  ReviewSheetModelTests+Default.swift
//  FluxKlangTests
//
//  The default action of the review sheet (#99 RV1): `activate` only for a fresh, hazard-free, human or controller
//  review in `awaitingReview` that has a change; every other case is `keepAsDraft`. One fixture per condition,
//  each with exactly that condition true, so a flip of one condition is seen by that fixture alone. Return resolves
//  the default, Escape always keeps the draft.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ReviewSheetModelTests {
    static func expectKeys(
        _ built: ReviewSheetModel, returnKey: ReviewDefaultAction, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(built.resolve(.returnKey) == returnKey, sourceLocation: sourceLocation)
        #expect(built.resolve(.escapeKey) == .keepAsDraft, sourceLocation: sourceLocation)
    }

    @Test func aFreshHazardFreeHumanReviewAwaitingReviewActivatesByDefaultAndOnlyReturnActivates() throws {
        let built = try Self.model(try Self.safeInput())
        #expect(built.defaultAction == .activate)
        #expect(built.canActivate && !built.needsExtraConfirmation && built.staleBanner == nil)
        Self.expectKeys(built, returnKey: .activate)
    }

    @Test func aControllerReviewActivatesByDefaultToo() throws {
        var input = try Self.safeInput()
        input.provenance = .controller
        let built = try Self.model(input)
        #expect(built.defaultAction == .activate && built.canActivate)
        Self.expectKeys(built, returnKey: .activate)
    }

    @Test func aHazardThatDoesNotBlockAloneKeepsTheDraftByDefaultButStaysActivatable() throws {
        var input = try Self.safeInput()
        input.hazards = [Self.hazard("hz.soft", blocks: false)]
        let built = try Self.model(input)
        #expect(built.canActivate)
        #expect(built.defaultAction == .keepAsDraft)
        Self.expectKeys(built, returnKey: .keepAsDraft)
    }

    @Test func aHazardThatBlocksAloneStopsActivationAndKeepsTheDraft() throws {
        var input = try Self.safeInput()
        input.hazards = [Self.hazard("hz.hard", blocks: true)]
        let blocked = try Self.model(input)
        #expect(!blocked.canActivate)
        #expect(blocked.defaultAction == .keepAsDraft)
        Self.expectKeys(blocked, returnKey: .keepAsDraft)
        input.hazards = [Self.hazard("hz.soft", blocks: false), Self.hazard("hz.hard", blocks: true)]
        #expect(try !Self.model(input).canActivate)
        input.hazards = [Self.hazard("hz.soft", blocks: false), Self.hazard("hz.other", blocks: false)]
        #expect(try Self.model(input).canActivate)
    }

    @Test func aStaleReviewAloneCannotActivateAndKeepsTheDraft() throws {
        var input = try Self.safeInput()
        input.staleness = try Self.staleness(base: 5, active: 7)
        let built = try Self.model(input)
        #expect(!built.canActivate)
        #expect(built.defaultAction == .keepAsDraft)
        Self.expectKeys(built, returnKey: .keepAsDraft)
    }

    @Test func anAssistantDraftAloneNeedsExtraConfirmationAndKeepsTheDraftByDefault() throws {
        var input = try Self.safeInput()
        input.provenance = .assistant
        let built = try Self.model(input)
        #expect(built.needsExtraConfirmation)
        #expect(built.canActivate)
        #expect(built.defaultAction == .keepAsDraft)
        Self.expectKeys(built, returnKey: .keepAsDraft)
    }

    /// One sample of every `ActivationPhase` case, named by an exhaustive switch so a new case breaks compilation.
    static func phaseCaseName(_ phase: ActivationPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .preparing: "preparing"
        case .awaitingReview: "awaitingReview"
        case .committing: "committing"
        case .acknowledged: "acknowledged"
        case .partial: "partial"
        case .commitFailed: "commitFailed"
        case .prepareFailed: "prepareFailed"
        case .recovering: "recovering"
        }
    }

    static func everyPhaseSample() throws -> [ActivationPhase] {
        let plan = PreparedActivationID(validated: "prep.review")
        return [
            .idle, .preparing, .awaitingReview, .committing, .acknowledged(try Self.revision(8)),
            .partial(plan, applied: [try Self.nodeID("nod.a")], unapplied: [try Self.nodeID("nod.b")]),
            .commitFailed(plan), .prepareFailed(.cancelled), .recovering(plan, cause: .leaseLost)
        ]
    }

    @Test func everyActivationPhaseOtherThanAwaitingReviewKeepsTheDraftByDefault() throws {
        let others = try Self.everyPhaseSample().filter { Self.phaseCaseName($0) != "awaitingReview" }
        #expect(Set(others.map(Self.phaseCaseName)).count == 8)
        var input = try Self.safeInput()
        for phase in others {
            input.phase = phase
            let built = try Self.model(input)
            #expect(built.defaultAction == .keepAsDraft, "\(Self.phaseCaseName(phase))")
            #expect(built.canActivate, "\(Self.phaseCaseName(phase))")
            Self.expectKeys(built, returnKey: .keepAsDraft)
        }
    }

    @Test func everyPhaseOtherThanAwaitingReviewAloneKeepsTheDraftByDefault() throws {
        let phases: [ActivationPhase] = [.idle, .preparing, .committing, .acknowledged(try Self.revision(8))]
        var input = try Self.safeInput()
        for phase in phases {
            input.phase = phase
            let built = try Self.model(input)
            #expect(built.defaultAction == .keepAsDraft, "\(phase)")
            #expect(built.canActivate, "\(phase)")
            Self.expectKeys(built, returnKey: .keepAsDraft)
        }
    }
}
