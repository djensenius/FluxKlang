import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Refusals, bounds and the pinned refusal order of `MTCEmitPlan.make`.
extension MTCEmitTests {
    static func start(_ rate: SMPTEFrameRate = .fps24) throws -> SMPTETime {
        try time(0, 0, 0, 0, rate)
    }

    static func shaped(frames: Int, numer: UInt32 = 1, denom: UInt32 = 1, origin: UInt64 = 0,
                       rate: SMPTEFrameRate = .fps24) throws -> MTCEmitRequest {
        MTCEmitRequest(start: try start(rate), direction: .forward, originTicks: origin, frameCount: frames,
                       timebase: HostTimebase(numer: numer, denom: denom), fullFrameDevice: nil)
    }

    @Test func twoAndTwoHundredFiftySixFramesAreAcceptedAndLargerCountsAreTooLarge() throws {
        let two = Self.refusal(try Self.shaped(frames: 2))
        let top = Self.refusal(try Self.shaped(frames: 256))
        let odd = Self.refusal(try Self.shaped(frames: 257))
        let even = Self.refusal(try Self.shaped(frames: 258))
        let huge = Self.refusal(try Self.shaped(frames: Int.max))
        #expect(two == nil)
        #expect(top == nil)
        #expect(odd == .frameCountTooLarge(257))
        #expect(even == .frameCountTooLarge(258))
        #expect(huge == .frameCountTooLarge(Int.max))
    }

    @Test func oneZeroAndNegativeFrameCountsAreTooSmallAndCarryTheirCount() throws {
        let one = Self.refusal(try Self.shaped(frames: 1))
        let zero = Self.refusal(try Self.shaped(frames: 0))
        let negative = Self.refusal(try Self.shaped(frames: -2))
        let least = Self.refusal(try Self.shaped(frames: Int.min))
        #expect(one == .frameCountTooSmall(1))
        #expect(zero == .frameCountTooSmall(0))
        #expect(negative == .frameCountTooSmall(-2))
        #expect(least == .frameCountTooSmall(Int.min))
    }

    @Test func oddCountsThreeSevenAndTwoFiftyFiveAreRefusedAndFourAndTwoFiftyFourAreAccepted() throws {
        let three = Self.refusal(try Self.shaped(frames: 3))
        let seven = Self.refusal(try Self.shaped(frames: 7))
        let top = Self.refusal(try Self.shaped(frames: 255))
        let four = Self.refusal(try Self.shaped(frames: 4))
        let nextToTop = Self.refusal(try Self.shaped(frames: 254))
        #expect(three == .frameCountNotWholeSequences(3))
        #expect(seven == .frameCountNotWholeSequences(7))
        #expect(top == .frameCountNotWholeSequences(255))
        #expect(four == nil)
        #expect(nextToTop == nil)
    }

    @Test func aZeroNumeratorAZeroDenominatorAndBothZeroAreInvalidTimebases() throws {
        let numerator = Self.refusal(try Self.shaped(frames: 2, numer: 0))
        let denominator = Self.refusal(try Self.shaped(frames: 2, denom: 0))
        let both = Self.refusal(try Self.shaped(frames: 2, numer: 0, denom: 0))
        #expect(numerator == .invalidTimebase)
        #expect(denominator == .invalidTimebase)
        #expect(both == .invalidTimebase)
    }

    @Test func thirtyFpsAcceptsANumeratorOfEightMillionThreeHundredThirtyThreeThousandThreeHundredThirtyThree() throws {
        let fine = Self.refusal(try Self.shaped(frames: 2, numer: 8_333_333, rate: .fps30))
        let coarse = Self.refusal(try Self.shaped(frames: 2, numer: 8_333_334, rate: .fps30))
        #expect(fine == nil)
        #expect(coarse == .timebaseTooCoarse)
    }

    @Test func twentyFiveFpsAcceptsANumeratorOfTenMillionExactlyAndRefusesOneMore() throws {
        let fine = Self.refusal(try Self.shaped(frames: 2, numer: 10_000_000, rate: .fps25))
        let coarse = Self.refusal(try Self.shaped(frames: 2, numer: 10_000_001, rate: .fps25))
        #expect(fine == nil)
        #expect(coarse == .timebaseTooCoarse)
    }

    @Test func twentyFourFpsAcceptsANumeratorOfTenMillionFourHundredSixteenThousandSixHundredSixtySix() throws {
        let fine = Self.refusal(try Self.shaped(frames: 2, numer: 10_416_666, rate: .fps24))
        let coarse = Self.refusal(try Self.shaped(frames: 2, numer: 10_416_667, rate: .fps24))
        #expect(fine == nil)
        #expect(coarse == .timebaseTooCoarse)
    }

    @Test func dropFrameAcceptsANumeratorOfEightMillionThreeHundredFortyOneThousandSixHundredSixtySix() throws {
        let fine = Self.refusal(try Self.shaped(frames: 2, numer: 8_341_666, rate: .fps2997DropFrame))
        let coarse = Self.refusal(try Self.shaped(frames: 2, numer: 8_341_667, rate: .fps2997DropFrame))
        #expect(fine == nil)
        #expect(coarse == .timebaseTooCoarse)
    }

    @Test func aDenominatorOfTwoDoublesTheCoarseBoundaryAtThirtyFps() throws {
        let fine = Self.refusal(try Self.shaped(frames: 2, numer: 16_666_666, denom: 2, rate: .fps30))
        let coarse = Self.refusal(try Self.shaped(frames: 2, numer: 16_666_667, denom: 2, rate: .fps30))
        #expect(fine == nil)
        #expect(coarse == .timebaseTooCoarse)
    }

    @Test func aMaximumNumeratorIsCoarseAndAMaximumDenominatorIsAccepted() throws {
        let coarse = Self.refusal(try Self.shaped(frames: 2, numer: UInt32.max, denom: 1))
        let fine = Self.refusal(try Self.shaped(frames: 2, numer: 1, denom: UInt32.max))
        #expect(coarse == .timebaseTooCoarse)
        #expect(fine == nil)
    }

    @Test func anOriginAtTheEndOfTheRangeOverflowsOnTheFirstEntryAboveTheOrigin() throws {
        let refused = Self.refusal(try Self.shaped(frames: 2, origin: UInt64.max))
        let alone = Self.refusal(try Self.shaped(frames: 2, origin: UInt64.max - 72_916_666))
        #expect(refused == .tickOverflow)
        #expect(alone == nil)
    }

    @Test func anOddCountAboveTheCapIsReportedAsTooLargeBeforeNotWholeSequences() throws {
        let both = Self.refusal(try Self.shaped(frames: 301))
        let second = Self.refusal(try Self.shaped(frames: 7))
        #expect(both == .frameCountTooLarge(301))
        #expect(second == .frameCountNotWholeSequences(7))
    }

    @Test func aCountOfOneWithAZeroNumeratorIsReportedAsTooSmallBeforeNotWholeSequences() throws {
        let both = Self.refusal(try Self.shaped(frames: 1, numer: 0))
        let second = Self.refusal(try Self.shaped(frames: 3, numer: 1))
        #expect(both == .frameCountTooSmall(1))
        #expect(second == .frameCountNotWholeSequences(3))
    }

    @Test func aCountOfSevenWithAZeroNumeratorIsReportedAsNotWholeSequencesBeforeAnInvalidTimebase() throws {
        let both = Self.refusal(try Self.shaped(frames: 7, numer: 0))
        let second = Self.refusal(try Self.shaped(frames: 6, numer: 0))
        #expect(both == .frameCountNotWholeSequences(7))
        #expect(second == .invalidTimebase)
    }

    @Test func aZeroDenominatorWithANonzeroNumeratorIsReportedAsInvalidBeforeCoarse() throws {
        let both = Self.refusal(try Self.shaped(frames: 2, numer: 1, denom: 0))
        let second = Self.refusal(try Self.shaped(frames: 2, numer: 8_333_334, rate: .fps30))
        #expect(both == .invalidTimebase)
        #expect(second == .timebaseTooCoarse)
    }

    @Test func aCoarseTimebaseWithAnOriginAtTheEndOfTheRangeIsReportedAsCoarseBeforeATickOverflow() throws {
        let both = Self.refusal(try Self.shaped(frames: 2, numer: 8_333_334, origin: UInt64.max, rate: .fps30))
        let second = Self.refusal(try Self.shaped(frames: 2, numer: 8_333_333, origin: UInt64.max, rate: .fps30))
        #expect(both == .timebaseTooCoarse)
        #expect(second == .tickOverflow)
    }

    @Test func theTickFunctionRefusesAZeroNumeratorOrDenominatorItself() {
        let zeroNumer = HostTimebase(numer: 0, denom: 1)
        let zeroDenom = HostTimebase(numer: 1, denom: 0)
        let first = Self.directTick(quarter: 1, timebase: zeroNumer)
        let second = Self.directTick(quarter: 1, timebase: zeroDenom)
        #expect(first == .invalidTimebase)
        #expect(second == .invalidTimebase)
    }

    @Test func theTickFunctionRefusesAnIntMaxQuarterIndexWithTickOverflow() {
        let huge = HostTimebase(numer: 1, denom: UInt32.max)
        let refused = Self.directTick(quarter: Int.max, timebase: huge, rate: .fps2997DropFrame)
        #expect(refused == .tickOverflow)
    }

    static func directTick(quarter: Int, timebase: HostTimebase, rate: SMPTEFrameRate = .fps24) -> MTCEmitRefusal? {
        do {
            _ = try MTCEmitTimebase.tick(origin: 0, quarter: quarter, rate: rate, timebase: timebase)
            return nil
        } catch {
            return error
        }
    }
}
