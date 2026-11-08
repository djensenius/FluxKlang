import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ShowReadinessTests {
    @Test func moreThanTheMaximumNumberOfReportsIsRefusedWithTheCountSupplied() throws {
        let facts = try Fixture.facts(Fixture.oneSongLibrary(), reports: Fixture.manyReports(4_097))
        let expected = ShowReadinessRefusal.tooManyReports(4_097)
        #expect(throws: expected) { try ShowReadinessEvaluator.evaluate(facts) }
    }

    @Test func theMaximumNumberOfReportsIsAcceptedAndUsed() throws {
        let reports = try Fixture.manyReports(4_096)
        #expect(ShowReadinessEvaluator.maximumReports == 4_096)
        #expect(reports.count == 4_096)
        let facts = try Fixture.facts(Fixture.oneSongLibrary(), reports: reports, knownSets: [Fixture.setOne])
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        #expect(verdict.entries.map(\.blockers) == [[]])
        #expect(verdict.isReadyToStart)
    }

    @Test func noReportsIsAcceptedAndLeavesReferencedSetsUnreported() throws {
        let facts = try Fixture.facts(Fixture.oneSongLibrary(), reports: [], knownSets: [Fixture.setOne])
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        #expect(verdict.entries.map(\.blockers) == [[.actionSetUnreported(Fixture.setOne)]])
    }

    @Test func aSetlistTheLibraryDoesNotHoldIsRefusedWithItsID() throws {
        let facts = try Fixture.facts(Fixture.oneSongLibrary(), setlist: Fixture.unknownList)
        let expected = ShowReadinessRefusal.unknownSetlist(Fixture.unknownList)
        #expect(throws: expected) { try ShowReadinessEvaluator.evaluate(facts) }
    }

    @Test func anEmptyLibraryRefusesASetlistAsUnknown() throws {
        let library = try ShowLibrary.make()
        let facts = try Fixture.facts(library, setlist: Fixture.mainList)
        let expected = ShowReadinessRefusal.unknownSetlist(Fixture.mainList)
        #expect(throws: expected) { try ShowReadinessEvaluator.evaluate(facts) }
    }

    @Test func aRepeatedReportIsRefusedNamingTheFirstSetSeenTwiceInReportOrder() throws {
        typealias Fix = Fixture
        let reports = [Fix.report(Fix.setOne), Fix.report(Fix.setTwo), Fix.report(Fix.setThree),
                       Fix.report(Fix.setOne), Fix.report(Fix.setTwo)]
        let facts = try Fix.facts(Fix.oneSongLibrary(), reports: reports)
        let expected = ShowReadinessRefusal.duplicateReport(Fix.setOne)
        #expect(throws: expected) { try ShowReadinessEvaluator.evaluate(facts) }
    }

    @Test func twoReportsForOneSetAreRefusedEvenWhenTheirStatesDiffer() throws {
        let reports = [Fixture.report(Fixture.setOne, .ready), Fixture.report(Fixture.setOne, .failed)]
        let facts = try Fixture.facts(Fixture.oneSongLibrary(), reports: reports)
        let expected = ShowReadinessRefusal.duplicateReport(Fixture.setOne)
        #expect(throws: expected) { try ShowReadinessEvaluator.evaluate(facts) }
    }

    @Test func tooManyReportsAreRefusedBeforeAnUnknownSetlist() throws {
        let facts = try Fixture.facts(Fixture.oneSongLibrary(), reports: Fixture.manyReports(4_097),
                                      setlist: Fixture.unknownList)
        let expected = ShowReadinessRefusal.tooManyReports(4_097)
        #expect(throws: expected) { try ShowReadinessEvaluator.evaluate(facts) }
    }

    @Test func anUnknownSetlistIsRefusedBeforeARepeatedReport() throws {
        let reports = [Fixture.report(Fixture.setOne), Fixture.report(Fixture.setOne)]
        let facts = try Fixture.facts(Fixture.oneSongLibrary(), reports: reports, setlist: Fixture.unknownList)
        let expected = ShowReadinessRefusal.unknownSetlist(Fixture.unknownList)
        #expect(throws: expected) { try ShowReadinessEvaluator.evaluate(facts) }
    }

    @Test func tooManyReportsAreRefusedBeforeARepeatedReport() throws {
        let reports = try Fixture.manyReports(4_096) + [Fixture.report(Fixture.setOne)]
        let facts = try Fixture.facts(Fixture.oneSongLibrary(), reports: reports)
        let expected = ShowReadinessRefusal.tooManyReports(4_097)
        #expect(reports.count == 4_097)
        #expect(throws: expected) { try ShowReadinessEvaluator.evaluate(facts) }
    }
}
