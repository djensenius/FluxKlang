import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Header, chunk and `SMFReadLimits` checks of the scan: each is refused as the CL2 reader refuses it.
extension SMFTempoImportTests {
    // swiftlint:disable:next identifier_name
    private var ok: [UInt8] { F.tempo(600_000) + F.note }

    @Test func eachHeaderDefectIsRefusedWithTheReadersCase() {
        #expect(F.refusal([]) == .file(.missingHeader))
        #expect(F.refusal(Array(F.header(tracks: 1).prefix(13))) == .file(.chunkOverrunsFile(offset: 0, length: 6)))
        #expect(F.refusal(F.chunk("MTrk", [0, 1, 0, 1, 1, 0xE0]) + F.track([])) == .file(.missingHeader))
        #expect(F.refusal(F.chunk("MThd", [0, 1, 0, 1, 1]) + F.track([])) == .file(.missingHeader))
        #expect(F.refusal(F.file(format: 2, tracks: [ok])) == .file(.unsupportedFormat(2)))
        #expect(F.refusal(F.file(division: 0xE728, tracks: [ok])) == .file(.smpteDivision(0xE728)))
        #expect(F.refusal(F.file(division: 0x8000, tracks: [ok])) == .file(.smpteDivision(0x8000)))
        #expect(F.refusal(F.file(division: 0, tracks: [ok])) == .file(.unsupportedDivision(0)))
        #expect(F.refusal(F.file(division: 7, tracks: [ok])) == .file(.unsupportedDivision(7)))
        #expect(F.refusal(F.file(division: 15_361, tracks: [ok])) == .file(.unsupportedDivision(15_361)))
        #expect(F.refusal(F.file(division: 0x7FFF, tracks: [ok])) == .file(.unsupportedDivision(0x7FFF)))
        #expect(F.refusal(F.header(tracks: 0)) == .file(.trackCountOutOfRange(declared: 0, limit: 64)))
        #expect(F.refusal(F.file(format: 0, tracks: [ok, ok])) == .file(.trackCountOutOfRange(declared: 2, limit: 64)))
    }

    @Test func aHeaderWithExtraBytesAndAnUnknownChunkIsScannedNormally() throws {
        let bytes = F.header(tracks: 1, extra: [0xAA, 0xBB]) + F.chunk("XFIH", [1, 2, 3]) + F.track(ok)
            + F.chunk("ZZZZ", [])
        let proposal = try F.proposal(bytes)
        #expect(proposal.segments == (try F.segments([[0, 600_000]])))
    }

    @Test func headerDefectsAreCheckedInTheReadersOrderWhenSeveralArePresent() {
        let none: [[UInt8]] = []
        #expect(F.refusal(F.file(format: 2, division: 0x8000, declared: 0, tracks: none))
            == .file(.unsupportedFormat(2)))
        #expect(F.refusal(F.file(division: 0x8000, declared: 0, tracks: none)) == .file(.smpteDivision(0x8000)))
        #expect(F.refusal(F.file(division: 7, declared: 0, tracks: none)) == .file(.unsupportedDivision(7)))
        #expect(F.refusal(F.file(format: 0, division: 480, declared: 2, tracks: none))
            == .file(.trackCountOutOfRange(declared: 2, limit: 64)))
        let limits = SMFReadLimits(maximumFileBytes: 5, maximumTracks: 64, maximumEvents: 65_536)
        #expect(F.refusal([], limits: limits) == .file(.missingHeader))
        #expect(F.refusal(F.file(format: 2, tracks: [ok]), limits: limits)
            == .file(.fileTooLarge(bytes: F.file(format: 2, tracks: [ok]).count, limit: 5)))
    }

    @Test func chunkDefectsAreRefusedWithTheReadersCases() {
        let overrun = F.header(tracks: 1) + Array("MTrk".utf8) + [0, 0, 0, 100, 0, 0xFF, 0x2F, 0]
        #expect(F.refusal(overrun) == .file(.chunkOverrunsFile(offset: 14, length: 100)))
        #expect(F.refusal(F.file(declared: 2, tracks: [ok])) == .file(.trackCountMismatch(declared: 2, found: 1)))
        #expect(F.refusal(F.file(declared: 1, tracks: [ok, ok])) == .file(.trackCountMismatch(declared: 1, found: 2)))
        let end = F.file(tracks: [ok]).count
        #expect(F.refusal(F.file(tracks: [ok]) + [1, 2, 3, 4, 5, 6, 7]) == .file(.truncated(offset: end)))
        #expect(F.refusal(F.file(tracks: [ok]) + [1]) == .file(.truncated(offset: end)))
        #expect(F.refusal(F.file(tracks: [ok]) + Array("MTrk".utf8) + [0xFF, 0, 0, 0])
            == .file(.chunkOverrunsFile(offset: end, length: 0xFF00_0000)))
    }

    @Test func anExtraTrackChunkIsRefusedBeforeAnyTrackIsScanned() {
        let broken = F.tempo(1)
        #expect(F.refusal(F.file(declared: 1, tracks: [ok, broken]))
            == .file(.trackCountMismatch(declared: 1, found: 2)))
        #expect(F.refusal(F.file(declared: 1, tracks: [ok, broken, broken]))
            == .file(.trackCountMismatch(declared: 1, found: 2)))
        #expect(F.refusal(F.file(declared: 2, tracks: [broken]))
            == .file(.trackCountMismatch(declared: 2, found: 1)))
        #expect(F.refusal(F.file(tracks: [broken])) == .tempoOutOfRange(atTicks: 0, microsPerQuarter: 1))
    }

    @Test func theFileByteLimitAcceptsExactlyItsSizeAndRefusesOneByteLess() throws {
        let bytes = F.file(tracks: [ok])
        let exact = SMFReadLimits(maximumFileBytes: bytes.count, maximumTracks: 64, maximumEvents: 65_536)
        #expect(try F.proposal(bytes, limits: exact).segments == (try F.segments([[0, 600_000]])))
        let under = SMFReadLimits(maximumFileBytes: bytes.count - 1, maximumTracks: 64, maximumEvents: 65_536)
        #expect(F.refusal(bytes, limits: under) == .file(.fileTooLarge(bytes: bytes.count, limit: bytes.count - 1)))
        #expect(SMFReadLimits.standard.maximumFileBytes == 4 << 20)
    }

    @Test func theTrackLimitAcceptsItsCountAndRefusesOneMoreAtTheStandardAndACustomLimit() throws {
        let sixtyFour = F.file(tracks: Array(repeating: [], count: 64))
        #expect(try F.proposal(sixtyFour).defaultedInitialTempo)
        let sixtyFive = F.file(tracks: Array(repeating: [], count: 65))
        #expect(F.refusal(sixtyFive) == .file(.trackCountOutOfRange(declared: 65, limit: 64)))
        let two = SMFReadLimits(maximumFileBytes: 4 << 20, maximumTracks: 2, maximumEvents: 65_536)
        #expect(try F.proposal(F.file(tracks: [[], []]), limits: two).defaultedInitialTempo)
        #expect(F.refusal(F.file(tracks: [[], [], []]), limits: two)
            == .file(.trackCountOutOfRange(declared: 3, limit: 2)))
        #expect(F.refusal(F.header(tracks: 3), limits: two) == .file(.trackCountOutOfRange(declared: 3, limit: 2)))
    }

    @Test func theEventLimitCountsEveryEventEndOfTrackIncludedAcrossTracks() throws {
        let four = SMFReadLimits(maximumFileBytes: 4 << 20, maximumTracks: 64, maximumEvents: 4)
        let three = SMFReadLimits(maximumFileBytes: 4 << 20, maximumTracks: 64, maximumEvents: 3)
        // A tempo, a Note On, a Note Off and End of Track: four events.
        let single = F.file(tracks: [F.tempo(600_000) + F.note])
        #expect(try F.proposal(single, limits: four).segments == (try F.segments([[0, 600_000]])))
        #expect(F.refusal(single, limits: three) == .file(.tooManyEvents(limit: 3)))
        let twoTracks = F.file(tracks: [F.tempo(600_000), F.meter(4, 2)])
        #expect(try F.proposal(twoTracks, limits: four).initialMeter == (try F.meterValue(4, 4)))
        #expect(F.refusal(twoTracks, limits: three) == .file(.tooManyEvents(limit: 3)))
        let skipped = F.file(tracks: [F.meta(0x01, [0x41]) + [0x00, 0xF0, 0x01, 0x7F]])
        let two = SMFReadLimits(maximumFileBytes: 4 << 20, maximumTracks: 64, maximumEvents: 2)
        #expect(try F.proposal(skipped, limits: three).defaultedInitialTempo)
        #expect(F.refusal(skipped, limits: two) == .file(.tooManyEvents(limit: 2)))
        let none = SMFReadLimits(maximumFileBytes: 4 << 20, maximumTracks: 64, maximumEvents: 0)
        #expect(F.refusal(F.file(tracks: [[]]), limits: none) == .file(.tooManyEvents(limit: 0)))
        #expect(SMFReadLimits.standard.maximumEvents == 65_536)
    }

    @Test func theEventLimitIsCheckedBeforeTheEventItCountsIsParsed() {
        let one = SMFReadLimits(maximumFileBytes: 4 << 20, maximumTracks: 64, maximumEvents: 1)
        let events = F.tempo(600_000) + [0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        #expect(F.refusal(F.file(tracks: [events]), limits: one) == .file(.tooManyEvents(limit: 1)))
        #expect(F.refusal(F.file(tracks: [events])) == .file(.overlongQuantity(offset: 29)))
    }

    @Test func theClipLengthBoundIsAcceptedExactlyAndRefusedOneFileTickLaterAtEachDivision() throws {
        let limit = MIDIClip.maximumLengthTicks
        #expect(limit == 62_914_560)
        for pair in [[15_360, 1], [480, 32], [1, 15_360]] {
            let atLimit = UInt32(limit / Int64(pair[1]))
            let proposal = try F.proposal(F.file(division: pair[0], tracks: [F.tempo(400_000, after: atLimit)]))
            #expect(proposal.segments == (try F.segments([[0, 500_000], [limit, 400_000]])), "division \(pair[0])")
            let over = F.file(division: pair[0], tracks: [F.tempo(400_000, after: atLimit + 1)])
            #expect(F.refusal(over) == .file(.timeBeyondLimit(track: 0, ticks: limit + Int64(pair[1]))),
                    "division \(pair[0])")
            let endOver = F.header(tracks: 1, division: pair[0])
                + F.track([], end: F.vlq(atLimit + 1) + [0xFF, 0x2F, 0])
            #expect(F.refusal(endOver) == .file(.timeBeyondLimit(track: 0, ticks: limit + Int64(pair[1]))))
        }
    }

    @Test func theClipLengthBoundAccumulatesAcrossDeltasAndIsPerTrack() throws {
        let half: UInt32 = 31_457_280
        let split = F.file(division: 15_360, tracks: [F.tempo(400_000, after: half) + F.tempo(500_000, after: half)])
        #expect(try F.proposal(split).segments
            == (try F.segments([[0, 500_000], [Int64(half), 400_000], [62_914_560, 500_000]])))
        let over = F.file(division: 15_360, tracks: [F.tempo(400_000, after: half) + F.tempo(500_000, after: half + 1)])
        #expect(F.refusal(over) == .file(.timeBeyondLimit(track: 0, ticks: 62_914_561)))
        let late = F.tempo(500_000, after: half * 2 + 1)
        let second = F.file(division: 15_360, tracks: [F.tempo(400_000, after: half), late])
        #expect(F.refusal(second) == .file(.timeBeyondLimit(track: 1, ticks: 62_914_561)))
        let perTrack = F.file(division: 15_360, tracks: [F.tempo(400_000, after: half * 2),
                                                         F.tempo(300_000, after: half * 2)])
        #expect(try F.proposal(perTrack).segments == (try F.segments([[0, 500_000], [62_914_560, 300_000]])))
        #expect(try F.proposal(perTrack).supersededTempos == 1)
    }

    @Test func theLargestDeltaAtTheCoarsestScaleIsRefusedWithoutOverflow() throws {
        let largest = F.file(division: 1, tracks: [[0xFF, 0xFF, 0xFF, 0x7F, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]])
        #expect(F.refusal(largest) == .file(.timeBeyondLimit(track: 0, ticks: 4_123_168_588_800)))
        let coarse = F.file(division: 15_360, tracks: [[0xFF, 0xFF, 0xFF, 0x7F, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]])
        #expect(F.refusal(coarse) == .file(.timeBeyondLimit(track: 0, ticks: 268_435_455)))
        let overlong = F.file(tracks: [[0x81, 0x80, 0x80, 0x80, 0x00] + F.tempo(400_000)])
        #expect(F.refusal(overlong) == .file(.overlongQuantity(offset: 22)))
        let fourByte = F.file(division: 15_360, tracks: [F.tempo(400_000, after: 0x20_0000)])
        #expect(try F.proposal(fourByte).segments.last?.atTicks == 2_097_152)
    }

    @Test func aRefusedScanLeavesTheInputAndALaterScanUnchanged() throws {
        let good = F.file(tracks: [F.tempo(600_000) + F.meter(3, 2) + F.note])
        let before = try F.proposal(good)
        let refused: [[UInt8]] = [
            F.file(tracks: [F.tempo(59_999)]), F.file(tracks: [F.meter(65, 2)]), F.file(format: 2, tracks: [ok]),
            F.file(tracks: [F.tempo(600_000)]) + [1], F.file(tracks: [[0x00, 0xFF, 0x51, 0x02, 0, 0]])
        ]
        for bytes in refused {
            let copy = bytes
            let first = F.refusal(bytes)
            #expect(first != nil)
            #expect(bytes == copy)
            #expect(F.refusal(bytes) == first)
            #expect(try F.proposal(good) == before)
        }
    }
}
