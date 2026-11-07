import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Tempo events (FF 51): range, byte order, length, merge and the segment bound.
extension SMFTempoImportTests {
    @Test func aTempoIsAcceptedAtBothEndsOfTheContractRangeAndRefusedOneOutsideIt() throws {
        for micros in [60_000, 3_000_000] {
            let proposal = try F.proposal(F.single(F.tempo(micros)))
            #expect(proposal.segments == (try F.segments([[0, Int64(micros)]])), "tempo \(micros)")
        }
        for micros in [59_999, 3_000_001, 0, 1, 0xFF_FFFF] {
            #expect(F.refusal(F.single(F.tempo(micros, after: 10)))
                == .tempoOutOfRange(atTicks: 320, microsPerQuarter: Int64(micros)), "tempo \(micros)")
        }
    }

    @Test func aTempoOutOfRangeRefusesEvenWhenALaterEventAtTheSameTickSupersedesIt() {
        #expect(F.refusal(F.single(F.tempo(59_999) + F.tempo(600_000)))
            == .tempoOutOfRange(atTicks: 0, microsPerQuarter: 59_999))
        #expect(F.refusal(F.single(F.tempo(600_000) + F.tempo(3_000_001)))
            == .tempoOutOfRange(atTicks: 0, microsPerQuarter: 3_000_001))
        let elsewhere = F.file(tracks: [F.tempo(600_000), F.tempo(3_000_001, after: 960)])
        #expect(F.refusal(elsewhere) == .tempoOutOfRange(atTicks: 30_720, microsPerQuarter: 3_000_001))
    }

    @Test func theTempoValueIsReadAsABigEndianTwentyFourBitNumber() throws {
        let events: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x0A, 0x1B, 0x2C]
        #expect(try F.proposal(F.single(events)).segments == (try F.segments([[0, 662_316]])))
        let low: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x00, 0xEA, 0x60]
        #expect(try F.proposal(F.single(low)).segments == (try F.segments([[0, 60_000]])))
        let high: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x2D, 0xC6, 0xC0]
        #expect(try F.proposal(F.single(high)).segments == (try F.segments([[0, 3_000_000]])))
    }

    @Test func aTempoEventOfAnyLengthButThreeIsMalformedAtItsOwnOffset() throws {
        for length in [0, 1, 2, 4, 5] {
            let payload = [UInt8](repeating: 0x07, count: length)
            #expect(F.refusal(F.single(F.meta(0x51, payload))) == .malformedTempo(track: 0, offset: 23),
                    "length \(length)")
        }
        let second = F.header(tracks: 2) + F.track(F.note) + F.track(F.meta(0x51, [1, 2]))
        #expect(F.refusal(second) == .malformedTempo(track: 1, offset: 44))
        #expect(try F.proposal(F.single(F.meta(0x51, [0x07, 0xA1, 0x20]))).segments == (try F.segments([[0, 500_000]])))
    }

    @Test func aTempoLengthThatOverrunsTheTrackIsTruncatedNotMalformed() {
        let overrun: [UInt8] = [0x00, 0xFF, 0x51, 0x04, 0x07, 0xA1, 0x20]
        #expect(F.refusal(F.single(overrun, end: [])) == .file(.truncated(offset: 23)))
        let short: [UInt8] = [0x00, 0xFF, 0x51, 0x02, 0x07]
        #expect(F.refusal(F.single(short, end: [])) == .file(.truncated(offset: 23)))
        let fits: [UInt8] = [0x00, 0xFF, 0x51, 0x02, 0x07, 0xA1]
        #expect(F.refusal(F.single(fits, end: [])) == .malformedTempo(track: 0, offset: 23))
    }

    @Test func aTempoDefectIsRefusedAheadOfAMissingEndOfTrack() {
        #expect(F.refusal(F.single(F.meta(0x51, [1, 2]), end: [])) == .malformedTempo(track: 0, offset: 23))
        #expect(F.refusal(F.single(F.tempo(5), end: [])) == .tempoOutOfRange(atTicks: 0, microsPerQuarter: 5))
    }

    @Test func fourThousandNinetySixSegmentsAreAcceptedAndOneMoreIsRefused() throws {
        func tempos(_ count: Int, from first: Int) -> [UInt8] {
            (first..<first + count).flatMap { index in
                F.tempo(index % 2 == 0 ? 600_000 : 700_000, after: index == first ? UInt32(first) : 1)
            }
        }
        // Ticks 0...4095 hold 4,096 distinct tempos: no default is needed.
        let atLimit = try F.proposal(F.single(tempos(4_096, from: 0)))
        #expect(atLimit.segments.count == 4_096)
        #expect(atLimit.segments.last == (try F.segment(4_095 * 32, 700_000)))
        #expect(!atLimit.defaultedInitialTempo)
        #expect(F.refusal(F.single(tempos(4_097, from: 0))) == .tooManySegments(limit: 4_096))
        // From tick 1 the default fills tick 0: 4,095 tempos make 4,096 segments, 4,096 make 4,097.
        let withDefault = try F.proposal(F.single(tempos(4_095, from: 1)))
        #expect(withDefault.segments.count == 4_096)
        #expect(withDefault.defaultedInitialTempo)
        #expect(F.refusal(F.single(tempos(4_096, from: 1))) == .tooManySegments(limit: 4_096))
    }

    @Test func supersededAndCoalescedTemposDoNotCountTowardTheSegmentBound() throws {
        let doubled = (0..<4_096).flatMap { index in
            let micros = index % 2 == 0 ? 600_000 : 700_000
            return F.tempo(micros, after: index == 0 ? 0 : 1) + F.tempo(micros)
        }
        let proposal = try F.proposal(F.single(doubled))
        #expect(proposal.segments.count == 4_096)
        #expect(proposal.supersededTempos == 4_096)
        let equal = (0..<5_000).flatMap { F.tempo(600_000, after: $0 == 0 ? 0 : 1) }
        let coalesced = try F.proposal(F.single(equal))
        #expect(coalesced.segments == (try F.segments([[0, 600_000]])))
        #expect(coalesced.coalescedTempos == 4_999)
    }
}
