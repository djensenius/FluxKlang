import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// `SMFTempoProposal.make` re-validates caller-built values; `makeMap` builds the map of a proposal.
extension SMFTempoImportTests {
    private static let noCounts = SMFTempoCounts(supersededTempos: 0, coalescedTempos: 0, defaultedInitialTempo: false)

    private func make(_ pairs: [[Int64]], meters: [SMFMeterChange] = [],
                      counts: SMFTempoCounts = noCounts) throws(SMFTempoRefusal) -> SMFTempoProposal {
        let segments: [TempoSegment]
        do {
            segments = try F.segments(pairs)
        } catch {
            Issue.record("invalid fixture segments \(pairs): \(error)")
            segments = []
        }
        return try SMFTempoProposal.make(segments: segments, initialMeter: nil, laterMeterChanges: meters,
                                         counts: counts)
    }

    @Test func makeAcceptsAValidProposalAndKeepsEveryField() throws {
        let initial = try F.meterValue(4, 4)
        let counts = SMFTempoCounts(supersededTempos: 2, coalescedTempos: 3, defaultedInitialTempo: false)
        let proposal = try SMFTempoProposal.make(
            segments: try F.segments([[0, 600_000], [960, 700_000]]), initialMeter: initial,
            laterMeterChanges: [try F.change(5, 3, 4)], counts: counts)
        #expect(proposal.initialMeter == initial)
        #expect(proposal.counts == counts)
        #expect(proposal.segments.count == 2)
        #expect(proposal.laterMeterChanges.count == 1)
    }

    @Test func makeRefusesEachSegmentDefectWithItsOwnCase() throws {
        func defect(_ pairs: [[Int64]]) -> SMFTempoRefusal? {
            do {
                _ = try make(pairs)
                return nil
            } catch {
                return error
            }
        }
        #expect(defect([]) == .invalidProposal(.noSegments))
        #expect(defect([[1, 600_000]]) == .invalidProposal(.firstSegmentNotAtZero))
        #expect(defect([[0, 600_000], [0, 700_000]]) == .invalidProposal(.segmentsNotStrictlyIncreasing))
        #expect(defect([[0, 600_000], [10, 700_000], [5, 800_000]]) == .invalidProposal(.segmentsNotStrictlyIncreasing))
        #expect(defect([[0, 600_000], [10, 600_000]]) == .invalidProposal(.adjacentSegmentsHaveEqualTempo))
        let limit = Int64(MIDIClip.maximumLengthTicks)
        #expect(defect([[0, 600_000], [limit, 700_000]]) == nil)
        #expect(defect([[0, 600_000], [limit + 1, 700_000]]) == .invalidProposal(.segmentBeyondClipLimit))
    }

    @Test func makeChecksTicksBeforeEqualTempoOnTheSamePair() {
        do {
            _ = try make([[0, 600_000], [0, 600_000]])
            Issue.record("expected a refusal")
        } catch {
            #expect(error == .invalidProposal(.segmentsNotStrictlyIncreasing))
        }
    }

    @Test func makeChecksTheSegmentBoundAheadOfTheSegmentRules() throws {
        let alternating = (0..<4_097).map { [Int64($0), $0 % 2 == 0 ? 600_000 : 700_000] }
        let atLimit = try make(Array(alternating.prefix(4_096)))
        #expect(atLimit.segments.count == 4_096)
        let broken = [[Int64(1), Int64(600_000)]] + alternating.dropFirst()
        do {
            _ = try make(broken)
            Issue.record("expected a refusal")
        } catch {
            #expect(error == .tooManySegments(limit: 4_096))
        }
    }

    @Test func makeChecksTheMeterBoundAheadOfSegmentDefectsAndMeterRules() throws {
        let change = try F.change(0, 4, 4)
        #expect(try make([[0, 600_000]], meters: Array(repeating: change, count: 256)).laterMeterChanges.count == 256)
        do {
            _ = try make([], meters: Array(repeating: change, count: 257))
            Issue.record("expected a refusal")
        } catch {
            #expect(error == .tooManyMeterChanges(limit: 256))
        }
    }

    @Test func makeRefusesMeterChangesOutOfRangeAheadOfUnorderedOnes() throws {
        let limit = Int64(MIDIClip.maximumLengthTicks)
        let edge = try make([[0, 600_000]], meters: [try F.change(0, 4, 4), try F.change(limit, 4, 4)])
        #expect(edge.laterMeterChanges.count == 2)
        let both = [try F.change(limit + 1, 4, 4), try F.change(5, 4, 4)]
        let negative = [try F.change(10, 4, 4), try F.change(-1, 4, 4)]
        for meters in [both, negative, both.reversed()] {
            do {
                _ = try make([[0, 600_000]], meters: meters)
                Issue.record("expected a refusal")
            } catch {
                #expect(error == .invalidProposal(.meterChangeOutOfRange))
            }
        }
        let unordered = [try F.change(10, 4, 4), try F.change(9, 4, 4)]
        do {
            _ = try make([[0, 600_000]], meters: unordered)
            Issue.record("expected a refusal")
        } catch {
            #expect(error == .invalidProposal(.meterChangesNotOrdered))
        }
        let equal = try make([[0, 600_000]], meters: [try F.change(9, 4, 4), try F.change(9, 3, 4)])
        #expect(equal.laterMeterChanges.count == 2)
    }

    @Test func makeRefusesNegativeCountsAndAMismatchedDefaultedTempo() throws {
        for counts in [SMFTempoCounts(supersededTempos: -1, coalescedTempos: 0, defaultedInitialTempo: false),
                       SMFTempoCounts(supersededTempos: 0, coalescedTempos: -1, defaultedInitialTempo: false)] {
            do {
                _ = try make([[0, 600_000]], counts: counts)
                Issue.record("expected a refusal")
            } catch {
                #expect(error == .invalidProposal(.negativeCount))
            }
        }
        let defaulted = SMFTempoCounts(supersededTempos: 0, coalescedTempos: 0, defaultedInitialTempo: true)
        #expect(try make([[0, 500_000]], counts: defaulted).defaultedInitialTempo)
        do {
            _ = try make([[0, 500_001]], counts: defaulted)
            Issue.record("expected a refusal")
        } catch {
            #expect(error == .invalidProposal(.defaultedTempoMismatch))
        }
        let both = SMFTempoCounts(supersededTempos: -1, coalescedTempos: 0, defaultedInitialTempo: true)
        do {
            _ = try make([[0, 500_001]], counts: both)
            Issue.record("expected a refusal")
        } catch {
            #expect(error == .invalidProposal(.negativeCount))
        }
    }

    @Test func makeMapBuildsTheMapOfTheSegmentsForTheGivenClockAndRevision() throws {
        let proposal = try F.proposal(F.single(F.tempo(600_000) + F.tempo(700_000, after: 480)))
        let other = ClockID(validated: "clock.musical.other")
        let first = try proposal.makeMap(clock: F.clock, revision: .initial)
        let second = try proposal.makeMap(clock: other, revision: try Generation(7))
        #expect(first.clock == F.clock)
        #expect(first.revision == Generation.initial)
        #expect(first.segments == proposal.segments)
        #expect(second.clock == other)
        #expect(second.revision == (try Generation(7)))
        #expect(second.segments == proposal.segments)
        #expect(first != second)
    }
}
