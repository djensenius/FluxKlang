import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Time signature events (FF 58): validity, initial versus later, ordering, length and the change bound.
extension SMFTempoImportTests {
    @Test func commonTimeSignaturesAreProposedWithTheirDenominatorsExpanded() throws {
        let cases: [[Int]] = [[3, 2, 4], [6, 3, 8], [7, 4, 16], [4, 1, 2], [1, 0, 1], [64, 5, 32]]
        for values in cases {
            let (numerator, power, denominator) = (values[0], values[1], values[2])
            let proposal = try F.proposal(F.single(F.meter(numerator, power)))
            #expect(proposal.initialMeter == (try F.meterValue(numerator, denominator)), "\(numerator)/\(denominator)")
            #expect(proposal.laterMeterChanges.isEmpty)
        }
    }

    @Test func aNumeratorOutsideOneToSixtyFourIsRefusedAtItsOwnOffset() {
        for numerator in [0, 65, 128, 255] {
            #expect(F.refusal(F.single(F.meter(numerator, 2)))
                == .invalidMeter(numerator: numerator, denominatorPower: 2), "numerator \(numerator)")
        }
    }

    @Test func aDenominatorPowerAboveFiveIsRefusedIncludingPowersThatOverflowAShift() {
        for power in [6, 7, 8, 31, 63, 64, 255] {
            #expect(F.refusal(F.single(F.meter(4, power)))
                == .invalidMeter(numerator: 4, denominatorPower: power), "power \(power)")
        }
    }

    @Test func theClocksPerClickAndThirtySecondsPerQuarterBytesDoNotChangeTheMeter() throws {
        let plain = try F.proposal(F.single(F.meter(6, 3)))
        for pair: [UInt8] in [[0, 0], [255, 255], [36, 16]] {
            #expect(try F.proposal(F.single(F.meter(6, 3, clocks: pair[0], thirtySeconds: pair[1]))) == plain)
        }
    }

    @Test func aTimeSignatureOfAnyLengthButFourIsMalformedAtItsOwnOffset() throws {
        for length in [0, 1, 2, 3, 5, 6] {
            let payload = [UInt8](repeating: 0x02, count: length)
            #expect(F.refusal(F.single(F.meta(0x58, payload))) == .malformedTimeSignature(track: 0, offset: 23),
                    "length \(length)")
        }
        let second = F.header(tracks: 2) + F.track(F.note) + F.track(F.meta(0x58, [4, 2, 24]))
        #expect(F.refusal(second) == .malformedTimeSignature(track: 1, offset: 44))
        let overrun: [UInt8] = [0x00, 0xFF, 0x58, 0x04, 0x04, 0x02]
        #expect(F.refusal(F.single(overrun, end: [])) == .file(.truncated(offset: 23)))
        let overrunOfAnotherLength: [UInt8] = [0x00, 0xFF, 0x58, 0x05, 0x04, 0x02]
        #expect(F.refusal(F.single(overrunOfAnotherLength, end: [])) == .file(.truncated(offset: 23)))
    }

    @Test func theFirstTimeSignatureAtTickZeroIsInitialAndEveryOtherIsALaterChange() throws {
        let events = F.meter(3, 2) + F.meter(5, 2) + F.meter(7, 3, after: 480) + F.meter(2, 1, after: 0)
        let proposal = try F.proposal(F.single(events))
        #expect(proposal.initialMeter == (try F.meterValue(3, 4)))
        #expect(proposal.laterMeterChanges == [try F.change(0, 5, 4), try F.change(15_360, 7, 8),
                                               try F.change(15_360, 2, 2)])
        let late = try F.proposal(F.single(F.meter(5, 2, after: 1)))
        #expect(late.initialMeter == nil)
        #expect(late.laterMeterChanges == [try F.change(32, 5, 4)])
    }

    @Test func meterChangesFromSeveralTracksAreMergedByTickThenTrackThenPosition() throws {
        let first = F.meter(3, 2, after: 100) + F.meter(9, 3, after: 100)
        let second = F.meter(5, 2, after: 100) + F.meter(2, 2, after: 100)
        let proposal = try F.proposal(F.file(tracks: [first, second]))
        let expected = [try F.change(3_200, 3, 4), try F.change(3_200, 5, 4),
                        try F.change(6_400, 9, 8), try F.change(6_400, 2, 4)]
        #expect(proposal.laterMeterChanges == expected)
        let swapped = try F.proposal(F.file(tracks: [second, first]))
        #expect(swapped.laterMeterChanges == [try F.change(3_200, 5, 4), try F.change(3_200, 3, 4),
                                              try F.change(6_400, 2, 4), try F.change(6_400, 9, 8)])
    }

    @Test func twoHundredFiftySixLaterChangesAreAcceptedAndOneMoreIsRefused() throws {
        func changes(_ count: Int, initial: Bool) -> [UInt8] {
            (initial ? F.meter(4, 2) : []) + (0..<count).flatMap { F.meter(3 + $0 % 2, 2, after: 1) }
        }
        let atLimit = try F.proposal(F.single(changes(256, initial: false)))
        #expect(atLimit.laterMeterChanges.count == 256)
        #expect(atLimit.initialMeter == nil)
        #expect(F.refusal(F.single(changes(257, initial: false))) == .tooManyMeterChanges(limit: 256))
        let withInitial = try F.proposal(F.single(changes(256, initial: true)))
        #expect(withInitial.laterMeterChanges.count == 256)
        #expect(withInitial.initialMeter != nil)
        #expect(F.refusal(F.single(changes(257, initial: true))) == .tooManyMeterChanges(limit: 256))
    }

    @Test func aFileWithoutTimeSignaturesProposesNoMeter() throws {
        let proposal = try F.proposal(F.single(F.tempo(600_000)))
        #expect(proposal.initialMeter == nil)
        #expect(proposal.laterMeterChanges.isEmpty)
    }
}
