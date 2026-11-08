//
//  ReviewSheetModelTests+Stale.swift
//  FluxKlangTests
//
//  The stale state of the review sheet (#99 RV1), taken from `WiringStaleDraft.check`: the banner carries both
//  revisions, the draft and the revalidate state, stays whatever else the input says, and a report of another active
//  revision is refused. Also the first two refusal-order pairs (revision overflow, stale mismatch, row count).
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ReviewSheetModelTests {
    @Test func aStaleReviewCarriesBothRevisionsTheDraftAndTheMessage() throws {
        var input = try Self.safeInput()
        input.staleness = try Self.staleness(base: 5, active: 7)
        let banner = try #require(try Self.model(input).staleBanner)
        #expect(banner.baseRevision == (try Self.revision(5)))
        #expect(banner.activeRevision == (try Self.revision(7)))
        #expect(banner.draft == Self.draftID)
        #expect(banner.message == "Based on rev 5; active is 7")
    }

    @Test func aDraftBasedAheadOfTheActiveRevisionIsStaleWithBothRevisions() throws {
        var input = try Self.safeInput()
        input.staleness = try Self.staleness(base: 9, active: 7)
        let banner = try #require(try Self.model(input).staleBanner)
        #expect(banner.baseRevision == (try Self.revision(9)))
        #expect(banner.activeRevision == (try Self.revision(7)))
    }

    @Test func theRevalidateStateOfTheBannerIsTheOneGivenForBothStates() throws {
        var input = try Self.safeInput()
        input.staleness = try Self.staleness(base: 5, active: 7, revalidate: .available)
        let available = try Self.model(input)
        input.staleness = try Self.staleness(base: 5, active: 7, revalidate: .inProgress)
        let running = try Self.model(input)
        #expect(available.staleBanner?.revalidate == .available)
        #expect(running.staleBanner?.revalidate == .inProgress)
        #expect(available != running)
    }

    @Test func aFreshReviewHasNoBannerAndANilCheckIsFresh() throws {
        #expect(try Self.model(try Self.safeInput()).staleBanner == nil)
        #expect(ReviewStaleness.from(check: nil, revalidate: .inProgress) == .fresh)
        let draft = Self.draft([], on: try Self.graph(revision: 5))
        let report = try #require(WiringStaleDraft.check(draft, active: try Self.graph(revision: 7)))
        #expect(ReviewStaleness.from(check: report, revalidate: .inProgress)
            == .stale(report, revalidate: .inProgress))
    }

    @Test func aStaleBannerStaysForEveryPhaseProvenanceAndHazardSet() throws {
        var input = try Self.safeInput()
        input.staleness = try Self.staleness(base: 5, active: 7)
        let phases: [ActivationPhase] = [.idle, .preparing, .awaitingReview, .committing]
        for phase in phases {
            for provenance in ReviewProvenance.allCases {
                for hazards in [[], [Self.hazard("hz.soft")], [Self.hazard("hz.hard", blocks: true)]] {
                    input.phase = phase
                    input.provenance = provenance
                    input.hazards = hazards
                    let built = try Self.model(input)
                    #expect(built.staleBanner?.baseRevision == (try Self.revision(5)))
                    #expect(!built.canActivate && built.defaultAction == .keepAsDraft)
                }
            }
        }
    }

    @Test func aStaleReviewStillNamesTheRevisionItWouldCreate() throws {
        var input = try Self.safeInput()
        input.staleness = try Self.staleness(base: 5, active: 7)
        #expect(try Self.model(input).creates == (try Self.revision(8)))
    }

    @Test func aStaleReviewWithAnEmptyDiffHasNoRowsNoCreatedRevisionAndCannotActivate() throws {
        var input = try Self.safeInput()
        input.diff = try Self.emptyDiff()
        input.staleness = try Self.staleness(base: 5, active: 7)
        let built = try Self.model(input)
        #expect(built.rows.isEmpty && built.creates == nil && !built.canActivate)
        #expect(built.staleBanner?.activeRevision == (try Self.revision(7)))
    }

    @Test func aStaleReportOfAnotherActiveRevisionIsRefusedWithBothRevisions() throws {
        var input = try Self.safeInput()
        input.staleness = try Self.staleness(base: 5, active: 6)
        #expect(Self.refusal(of: input) == .staleActiveRevisionMismatch(
            stale: try Self.revision(6), active: try Self.revision(7)
        ))
        input.staleness = try Self.staleness(base: 5, active: 8)
        #expect(Self.refusal(of: input) == .staleActiveRevisionMismatch(
            stale: try Self.revision(8), active: try Self.revision(7)
        ))
    }

    @Test func aMaximumActiveRevisionIsRefusedBeforeAStaleReportOfAnotherRevision() throws {
        var input = try Self.safeInput()
        input.activeRevision = try Self.revision(ContractRevision.maximumValue)
        input.staleness = try Self.staleness(base: 5, active: 7)
        #expect(Self.refusal(of: input) == .revisionOverflow)
    }

    @Test func aStaleReportOfAnotherRevisionIsRefusedBeforeTooManyRows() throws {
        var input = try Self.safeInput()
        input.diff = try Self.addedNodesDiff(count: 513)
        input.staleness = try Self.staleness(base: 5, active: 6)
        #expect(Self.refusal(of: input) == .staleActiveRevisionMismatch(
            stale: try Self.revision(6), active: try Self.revision(7)
        ))
    }
}
