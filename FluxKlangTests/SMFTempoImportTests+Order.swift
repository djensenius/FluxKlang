import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Refusal order: every fixture holds two defects at once. Fixtures of two defects that can swap places are checked in
/// both input orders; the header and chunk fixtures have one order, as a header defect always precedes the tracks.
extension SMFTempoImportTests {
    private static let badTempo = F.tempo(5)
    private static let badMeter = F.meter(0, 2)
    private static let badTempoLength = F.meta(0x51, [1])
    private static let badMeterLength = F.meta(0x58, [1])

    @Test func theFirstTempoOrMeterDefectInFileOrderIsTheOneReported() {
        #expect(F.refusal(F.single(Self.badTempo + Self.badMeter))
            == .tempoOutOfRange(atTicks: 0, microsPerQuarter: 5))
        #expect(F.refusal(F.single(Self.badMeter + Self.badTempo))
            == .invalidMeter(numerator: 0, denominatorPower: 2))
        #expect(F.refusal(F.single(Self.badTempoLength + Self.badMeterLength)) == .malformedTempo(track: 0, offset: 23))
        #expect(F.refusal(F.single(Self.badMeterLength + Self.badTempoLength))
            == .malformedTimeSignature(track: 0, offset: 23))
    }

    @Test func aTempoDefectInAnEarlierTrackBeatsAMeterDefectInALaterOneAndViceVersa() {
        #expect(F.refusal(F.file(tracks: [Self.badTempo, Self.badMeter]))
            == .tempoOutOfRange(atTicks: 0, microsPerQuarter: 5))
        #expect(F.refusal(F.file(tracks: [Self.badMeter, Self.badTempo]))
            == .invalidMeter(numerator: 0, denominatorPower: 2))
    }

    @Test func aHeaderOrChunkDefectBeatsAnyTempoOrMeterDefectInATrack() {
        let defects = Self.badTempo + Self.badMeter
        #expect(F.refusal(F.file(declared: 2, tracks: [defects])) == .file(.trackCountMismatch(declared: 2, found: 1)))
        #expect(F.refusal(F.file(format: 2, tracks: [defects])) == .file(.unsupportedFormat(2)))
        #expect(F.refusal(F.header(tracks: 1, division: 0) + F.track(defects)) == .file(.unsupportedDivision(0)))
    }

    @Test func aTempoDefectIsReportedAheadOfALaterMalformedTimeSignatureAndViceVersa() {
        let events = Self.badTempo + F.meta(0x58, [1, 2])
        #expect(F.refusal(F.single(events)) == .tempoOutOfRange(atTicks: 0, microsPerQuarter: 5))
        let swapped = F.meta(0x58, [1, 2]) + Self.badTempo
        #expect(F.refusal(F.single(swapped)) == .malformedTimeSignature(track: 0, offset: 23))
    }

    @Test func tooManySegmentsIsReportedAheadOfTooManyMeterChanges() {
        let tempos = (0..<4_097).flatMap { F.tempo($0 % 2 == 0 ? 600_000 : 700_000, after: $0 == 0 ? 0 : 1) }
        let meters = (0..<258).flatMap { F.meter(4, 2, after: $0 == 0 ? 0 : 1) }
        #expect(F.refusal(F.single(tempos + meters)) == .tooManySegments(limit: 4_096))
        #expect(F.refusal(F.single(meters + tempos)) == .tooManySegments(limit: 4_096))
        #expect(F.refusal(F.single(meters)) == .tooManyMeterChanges(limit: 256))
    }

    @Test func aSegmentLimitIsReportedOnlyAfterEveryEventHasBeenScannedForDefects() {
        let tempos = (0..<4_097).flatMap { F.tempo($0 % 2 == 0 ? 600_000 : 700_000, after: $0 == 0 ? 0 : 1) }
        #expect(F.refusal(F.single(tempos + Self.badMeter)) == .invalidMeter(numerator: 0, denominatorPower: 2))
        #expect(F.refusal(F.single(Self.badMeter + tempos)) == .invalidMeter(numerator: 0, denominatorPower: 2))
    }

    @Test func splittingTheSameEventsAcrossTracksDoesNotChangeTheResult() throws {
        let one = F.tempo(600_000) + F.tempo(700_000)
        let split = try F.proposal(F.file(tracks: [F.tempo(600_000), F.tempo(700_000)]))
        let single = try F.proposal(F.single(one))
        #expect(split.segments == single.segments)
        #expect(split.segments == (try F.segments([[0, 700_000]])))
        #expect(try F.proposal(F.single(one)) == single)
    }

    @Test func theLaterTrackWinsAnEqualTickSoReversingTheTracksChangesTheResult() throws {
        let forward = try F.proposal(F.file(tracks: [F.tempo(600_000), F.tempo(700_000)]))
        let reversed = try F.proposal(F.file(tracks: [F.tempo(700_000), F.tempo(600_000)]))
        #expect(forward.segments == (try F.segments([[0, 700_000]])))
        #expect(reversed.segments == (try F.segments([[0, 600_000]])))
    }

    @Test func makeReportsSegmentDefectsThenMeterDefectsThenCountDefects() throws {
        let valid = try F.segments([[0, 600_000]])
        let unordered = [try F.change(10, 4, 4), try F.change(5, 4, 4)]
        let negative = SMFTempoCounts(supersededTempos: -1, coalescedTempos: 0, defaultedInitialTempo: false)
        let none = SMFTempoCounts(supersededTempos: 0, coalescedTempos: 0, defaultedInitialTempo: false)
        func defect(_ segments: [TempoSegment], _ meters: [SMFMeterChange],
                    _ counts: SMFTempoCounts) -> SMFTempoRefusal? {
            do {
                _ = try SMFTempoProposal.make(segments: segments, initialMeter: nil, laterMeterChanges: meters,
                                              counts: counts)
                return nil
            } catch {
                return error
            }
        }
        #expect(defect([], unordered, negative) == .invalidProposal(.noSegments))
        #expect(defect(valid, unordered, negative) == .invalidProposal(.meterChangesNotOrdered))
        #expect(defect(valid, [], negative) == .invalidProposal(.negativeCount))
        #expect(defect(valid, unordered, none) == .invalidProposal(.meterChangesNotOrdered))
    }
}
