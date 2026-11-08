import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ShowResumePlannerTests {
    struct Scenario {
        let point: ShowResumePoint
        let library: ShowLibrary
        let basis: ShowResumeBasis
    }

    private static func scenarios() throws -> [Scenario] {
        var partsAdded = Fixture.Spec()
        partsAdded.entry = Fixture.e4
        partsAdded.song = Fixture.songC
        partsAdded.part = nil
        partsAdded.ordinal = 3
        partsAdded.previous = Fixture.e3
        partsAdded.next = Fixture.e5
        let third = [Fixture.entry(Fixture.e4, Fixture.songC), Fixture.entry(Fixture.e5, Fixture.songD),
                     Fixture.entry(Fixture.e6, Fixture.songA)]
        return [
            Scenario(point: Fixture.Spec().point,
                     library: try Fixture.library(partsOfA: [Fixture.a1, Fixture.a3]),
                     basis: .partMissing(Fixture.a2)),
            Scenario(point: partsAdded.point,
                     library: try Fixture.library(partsOfA: [Fixture.a1], partsOfC: [Fixture.c1]),
                     basis: .partsAdded),
            Scenario(point: Fixture.Spec().point, library: try Fixture.library(partsOfA: []),
                     basis: .partMissing(Fixture.a2)),
            Scenario(point: Fixture.secondEntrySpec().point, library: try Fixture.withoutEntries([Fixture.e2]),
                     basis: .entryMissingNext(Fixture.e2)),
            Scenario(point: Fixture.secondEntrySpec().point,
                     library: try Fixture.withoutEntries([Fixture.e2, Fixture.e3]),
                     basis: .entryMissingPrevious(Fixture.e2)),
            Scenario(point: Fixture.secondEntrySpec().point, library: try Fixture.library(main: third),
                     basis: .entryMissingOrdinal(Fixture.e2))
        ]
    }

    private static func move(_ cursor: inout ShowCursor, _ command: ShowNavigationCommand,
                             in library: ShowLibrary, sequence: UInt64) throws -> ShowNavigationResult {
        let input = ShowNavigationInput(command, source: Fixture.foot, sequence: sequence, tick: 0)
        return try cursor.navigate(input, in: library, catalog: ShowLinkCatalog.make())
    }

    @Test func theJumpOfAnExactDecisionIsAcceptedByTheRealCursorAndLandsOnTheSavedPosition() throws {
        let library = try Fixture.standardLibrary()
        let saved = try Fixture.cursor(in: library, at: Fixture.e3, part: Fixture.a2)
        let point = try ShowResumePoint.capture(from: saved, in: library)
        let decision = try ShowResumePlanner.plan(point, in: library)
        let jump = try #require(decision.jumpCommand)
        var fresh = try Fixture.cursor(in: library)
        let result = try Self.move(&fresh, jump, in: library, sequence: 1)
        let target = try #require(decision.target)
        guard case let .moved(stop) = result else {
            Issue.record("the cursor ignored the exact jump")
            return
        }
        let landed = stop.position
        let savedPosition = try #require(saved.position)
        #expect(landed == target)
        #expect(landed == savedPosition)
        #expect(fresh.position == savedPosition)
    }

    @Test func theJumpOfEveryConfirmBasisIsAcceptedByTheRealCursorAndLandsOnItsTarget() throws {
        let all = try Self.scenarios()
        #expect(all.count == 6)
        for scenario in all {
            let decision = try ShowResumePlanner.plan(scenario.point, in: scenario.library)
            guard case let .confirm(proposal) = decision else {
                Issue.record("a scenario did not give a confirm decision")
                continue
            }
            var fresh = try Fixture.cursor(in: scenario.library)
            let result = try Self.move(&fresh, proposal.jump, in: scenario.library, sequence: 1)
            guard case let .moved(stop) = result else {
                Issue.record("the cursor ignored a confirm jump")
                continue
            }
            let landed = stop.position
            let status = fresh.status(in: scenario.library)
            #expect(proposal.basis == scenario.basis)
            #expect(landed == proposal.target)
            #expect(status == .current)
        }
    }

    @Test func aStaleCursorIsRefusedRelativeMovesAndRecoversOnlyThroughTheJumpOfItsDecision() throws {
        let library = try Fixture.standardLibrary()
        var cursor = try Fixture.cursor(in: library, at: Fixture.e3, part: Fixture.a2)
        let point = try ShowResumePoint.capture(from: cursor, in: library)
        let edited = try Fixture.withoutEntries([Fixture.e3])
        let staleStatus = cursor.status(in: edited)
        let expectedStatus = ShowCursorStatus.entryRemoved(Fixture.e3)
        let refusal = ShowRefusal.cursorTargetRemoved(expectedStatus)
        #expect(staleStatus == expectedStatus)
        #expect(throws: refusal) { try Self.move(&cursor, .nextSong, in: edited, sequence: 2) }
        let decision = try ShowResumePlanner.plan(point, in: edited)
        let jump = try #require(decision.jumpCommand)
        let result = try Self.move(&cursor, jump, in: edited, sequence: 3)
        guard case let .moved(stop) = result else {
            Issue.record("the stale cursor ignored the jump")
            return
        }
        let landed = stop.position
        let target = try #require(decision.target)
        let recovered = cursor.status(in: edited)
        #expect(landed == target)
        #expect(recovered == .current)
    }

    @Test func capturePlanAndJumpOnAFreshCursorRestoreEverySavedPositionOfTheStandardLibrary() throws {
        let library = try Fixture.standardLibrary()
        let saves: [(SetlistEntryID, SongPartID?)] = [
            (Fixture.e1, Fixture.a1), (Fixture.e1, Fixture.a2), (Fixture.e1, Fixture.a3), (Fixture.e2, Fixture.b1),
            (Fixture.e2, Fixture.b2), (Fixture.e3, Fixture.a1), (Fixture.e3, Fixture.a2), (Fixture.e3, Fixture.a3),
            (Fixture.e4, nil), (Fixture.e5, Fixture.d1)
        ]
        #expect(saves.count == 10)
        for (entry, part) in saves {
            let saved = try Fixture.cursor(in: library, at: entry, part: part)
            let point = try ShowResumePoint.capture(from: saved, in: library)
            let decision = try ShowResumePlanner.plan(point, in: library)
            let jump = try #require(decision.jumpCommand)
            var fresh = try Fixture.cursor(in: library)
            _ = try Self.move(&fresh, jump, in: library, sequence: 1)
            let expected = saved.position
            #expect(!decision.needsOperator)
            #expect(fresh.position == expected)
        }
    }
}
