import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The tempo and meter proposals of Standard MIDI File bytes (#112 CL6). Extension files hold the topics.
#if os(macOS)
@Suite("SMF tempo and meter import", .productionAccessAudit)
#else
@Suite("SMF tempo and meter import")
#endif
struct SMFTempoImportTests {
    // swiftlint:disable:next type_name
    typealias F = Fixture

    @Test func aSingleTempoAtTickZeroIsProposedWithNoDefault() throws {
        let proposal = try F.proposal(F.file(division: 480, tracks: [F.tempo(600_000) + F.note]))
        #expect(proposal.segments == (try F.segments([[0, 600_000]])))
        #expect(proposal.counts == SMFTempoCounts(supersededTempos: 0, coalescedTempos: 0,
                                                  defaultedInitialTempo: false))
        #expect(proposal.initialMeter == nil)
        #expect(proposal.laterMeterChanges.isEmpty)
        #expect(!proposal.defaultedInitialTempo)
    }

    @Test func aFileWithNoTempoProposesTheDefaultAtTickZero() throws {
        let proposal = try F.proposal(F.file(tracks: [F.note]))
        #expect(proposal.segments == (try F.segments([[0, 500_000]])))
        #expect(proposal.defaultedInitialTempo)
        #expect(proposal.supersededTempos == 0)
        #expect(proposal.coalescedTempos == 0)
    }

    @Test func aFirstTempoAfterTickZeroLeavesTheDefaultInForceUntilThen() throws {
        let proposal = try F.proposal(F.file(division: 480, tracks: [F.tempo(400_000, after: 480)]))
        #expect(proposal.segments == (try F.segments([[0, 500_000], [15_360, 400_000]])))
        #expect(proposal.defaultedInitialTempo)
    }

    @Test func aTempoEqualToTheDefaultAfterTickZeroCoalescesIntoTheDefault() throws {
        let proposal = try F.proposal(F.file(tracks: [F.tempo(500_000, after: 480)]))
        #expect(proposal.segments == (try F.segments([[0, 500_000]])))
        #expect(proposal.defaultedInitialTempo)
        #expect(proposal.coalescedTempos == 1)
    }

    @Test func tempoChangesAcrossTwoTracksAreMergedInTickOrderInEitherTrackOrder() throws {
        let first = F.tempo(600_000) + F.tempo(800_000, after: 960)
        let second = F.tempo(400_000, after: 480) + F.tempo(700_000, after: 960)
        let expected = try F.segments([[0, 600_000], [15_360, 400_000], [30_720, 800_000], [46_080, 700_000]])
        #expect(try F.proposal(F.file(tracks: [first, second])).segments == expected)
        let swapped = try F.proposal(F.file(tracks: [second, first]))
        #expect(swapped.segments == expected)
        #expect(!swapped.defaultedInitialTempo)
    }

    @Test func twoTemposAtOneTickKeepTheLastInTrackThenPositionOrder() throws {
        let sameTrack = try F.proposal(F.file(tracks: [F.tempo(400_000, after: 480) + F.tempo(700_000)]))
        #expect(sameTrack.segments == (try F.segments([[0, 500_000], [15_360, 700_000]])))
        #expect(sameTrack.supersededTempos == 1)
        let reversed = try F.proposal(F.file(tracks: [F.tempo(700_000, after: 480) + F.tempo(400_000)]))
        #expect(reversed.segments == (try F.segments([[0, 500_000], [15_360, 400_000]])))
        let lowFirst = try F.proposal(F.file(tracks: [F.tempo(400_000, after: 480), F.tempo(700_000, after: 480)]))
        #expect(lowFirst.segments == (try F.segments([[0, 500_000], [15_360, 700_000]])))
        let highFirst = try F.proposal(F.file(tracks: [F.tempo(700_000, after: 480), F.tempo(400_000, after: 480)]))
        #expect(highFirst.segments == (try F.segments([[0, 500_000], [15_360, 400_000]])))
        #expect(lowFirst.supersededTempos == 1)
        #expect(highFirst.supersededTempos == 1)
    }

    @Test func equalConsecutiveTemposCoalesceAndAreCounted() throws {
        let events = F.tempo(600_000) + F.tempo(600_000, after: 480) + F.tempo(700_000, after: 480)
            + F.tempo(700_000, after: 480) + F.tempo(600_000, after: 480)
        let proposal = try F.proposal(F.file(tracks: [events]))
        #expect(proposal.segments == (try F.segments([[0, 600_000], [30_720, 700_000], [61_440, 600_000]])))
        #expect(proposal.coalescedTempos == 2)
        #expect(proposal.supersededTempos == 0)
    }

    @Test func aSupersededTempoThatEqualsTheLastCountsOnlyAsSuperseded() throws {
        let events = F.tempo(600_000) + F.tempo(700_000, after: 480) + F.tempo(600_000)
        let proposal = try F.proposal(F.file(tracks: [events]))
        #expect(proposal.segments == (try F.segments([[0, 600_000]])))
        #expect(proposal.supersededTempos == 1)
        #expect(proposal.coalescedTempos == 1)
    }

    @Test func eachDivisionScalesFileTicksToExactClipTicks() throws {
        let cases: [[Int]] = [[1, 15_360], [3, 5_120], [10, 1_536], [96, 160], [480, 32], [960, 16], [15_360, 1]]
        for pair in cases {
            let proposal = try F.proposal(F.file(division: pair[0], tracks: [F.tempo(400_000, after: 1)]))
            #expect(proposal.segments == (try F.segments([[0, 500_000], [Int64(pair[1]), 400_000]])),
                    "division \(pair[0])")
        }
    }

    @Test func formatZeroAndFormatOneSingleTrackFilesGiveEqualProposals() throws {
        let events = F.tempo(650_000) + F.meter(3, 2) + F.tempo(450_000, after: 960)
        let zero = try F.proposal(F.file(format: 0, tracks: [events]))
        let one = try F.proposal(F.file(format: 1, tracks: [events]))
        #expect(zero == one)
        #expect(zero.segments == (try F.segments([[0, 650_000], [30_720, 450_000]])))
    }
}
