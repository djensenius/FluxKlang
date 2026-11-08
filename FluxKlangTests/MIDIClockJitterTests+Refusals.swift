import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Refusals of windows, nominal intervals and tolerances, their order and their bounds.
extension MIDIClockJitterTests {
    static func ascending(count: Int) -> [HostStamp] {
        stamps((0..<count).map { UInt64($0) * 1_000 })
    }

    static func nominalRefusal(span: Int128, pulses: Int128) -> MIDIClockJitterRefusal? {
        do {
            _ = try nominal(span, pulses)
            return nil
        } catch {
            return error
        }
    }

    static func tempoRefusal(_ beatsPerMinute: Int, numer: UInt32 = 1, denom: UInt32 = 1) -> MIDIClockJitterRefusal? {
        do {
            _ = try MIDIClockJitterNominal.make(
                beatsPerMinute: beatsPerMinute, timebase: HostTimebase(numer: numer, denom: denom)
            )
            return nil
        } catch {
            return error
        }
    }

    static func toleranceRefusal(_ perMille: Int) -> MIDIClockJitterRefusal? {
        do {
            _ = try MIDIClockJitterTolerance.make(perMille: perMille)
            return nil
        } catch {
            return error
        }
    }

    // MARK: Window

    @Test func moreThanTheStampCapIsRefusedWithTheCountGiven() {
        #expect(Self.refusal(Self.ascending(count: 1_025)) == .tooManyStamps(1_025))
        #expect(Self.refusal(Self.ascending(count: 3_000)) == .tooManyStamps(3_000))
    }

    @Test func fewerThanTwoStampsAreRefusedWithTheCountGiven() {
        #expect(Self.refusal([]) == .tooFewStamps(0))
        #expect(Self.refusal(Self.stamps([7])) == .tooFewStamps(1))
    }

    @Test func twoStampsAndTheStampCapAreAccepted() throws {
        let two = try Self.summary(Self.stamps([0, 1_000]))
        #expect(two.intervalCount == 1)
        let capped = try Self.summary(Self.ascending(count: 1_024))
        #expect(capped.intervalCount == 1_023)
        #expect(capped.totalTicks == 1_023_000)
        #expect(capped.maximumDeviationScaled == 0)
    }

    @Test func percentileOutsideOneToOneHundredIsRefusedWithTheValueGiven() {
        #expect(Self.refusal(Self.windowA, percentile: 0) == .percentileOutOfRange(0))
        #expect(Self.refusal(Self.windowA, percentile: 101) == .percentileOutOfRange(101))
        #expect(Self.refusal(Self.windowA, percentile: -1) == .percentileOutOfRange(-1))
    }

    @Test func percentileOneAndOneHundredAreAccepted() throws {
        let one = try Self.summary(Self.windowA, percentile: 1)
        let hundred = try Self.summary(Self.windowA, percentile: 100)
        #expect(one.percentile == 1)
        #expect(hundred.percentile == 100)
    }

    @Test func aDecreaseNamesTheFirstStampLowerThanItsPredecessor() {
        #expect(Self.refusal(Self.stamps([0, 10, 5, 20])) == .nonMonotonicStamps(index: 2))
        #expect(Self.refusal(Self.stamps([0, 10, 5, 3, 20])) == .nonMonotonicStamps(index: 2))
        #expect(Self.refusal(Self.stamps([10, 9])) == .nonMonotonicStamps(index: 1))
        #expect(Self.refusal(Self.stamps([0, 10, 20, 19])) == .nonMonotonicStamps(index: 3))
    }

    @Test func aStampEqualToItsPredecessorIsNotADecrease() throws {
        let summary = try Self.summary(Self.stamps([10, 10]))
        #expect(summary.intervalCount == 1)
        #expect(summary.maximumInterval == 0)
    }

    @Test func tooManyStampsOutranksAPercentileAndADecreaseInTheSameWindow() {
        var ticks = (0..<1_025).map { UInt64($0) * 1_000 }
        ticks[5] = 1
        let refusal = Self.refusal(Self.stamps(ticks), percentile: 0)
        #expect(refusal == .tooManyStamps(1_025))
    }

    @Test func tooFewStampsOutranksAPercentileOutOfRange() {
        #expect(Self.refusal(Self.stamps([0]), percentile: 101) == .tooFewStamps(1))
        #expect(Self.refusal([], percentile: 0) == .tooFewStamps(0))
    }

    @Test func aPercentileOutOfRangeOutranksADecrease() {
        let window = Self.stamps([0, 10, 5])
        #expect(Self.refusal(window, percentile: 0) == .percentileOutOfRange(0))
        #expect(Self.refusal(window, percentile: 101) == .percentileOutOfRange(101))
        #expect(Self.refusal(window, percentile: 100) == .nonMonotonicStamps(index: 2))
    }

    // MARK: Nominal

    @Test func nominalSpanIsAcceptedFromOneToTwoToTheEightyAndRefusedOutside() throws {
        let top = Int128(1) << 80
        let low = try Self.nominal(1, 1)
        let high = try Self.nominal(top, 1)
        #expect(low.spanTicks == 1)
        #expect(high.spanTicks == top)
        #expect(Self.nominalRefusal(span: top + 1, pulses: 1) == .nominalSpanOutOfRange)
        #expect(Self.nominalRefusal(span: 0, pulses: 1) == .nominalSpanOutOfRange)
        #expect(Self.nominalRefusal(span: -1, pulses: 1) == .nominalSpanOutOfRange)
    }

    @Test func nominalPulsesAreAcceptedFromOneToTwoToTheFortyEightAndRefusedOutside() throws {
        let top = Int128(1) << 48
        let low = try Self.nominal(1_000, 1)
        let high = try Self.nominal(1_000, top)
        #expect(low.pulses == 1)
        #expect(high.pulses == top)
        #expect(Self.nominalRefusal(span: 1_000, pulses: top + 1) == .nominalPulsesOutOfRange)
        #expect(Self.nominalRefusal(span: 1_000, pulses: 0) == .nominalPulsesOutOfRange)
        #expect(Self.nominalRefusal(span: 1_000, pulses: -1) == .nominalPulsesOutOfRange)
    }

    @Test func aBadSpanOutranksABadPulseCountInTheSameNominal() {
        #expect(Self.nominalRefusal(span: 0, pulses: 0) == .nominalSpanOutOfRange)
        #expect(Self.nominalRefusal(span: 1_000, pulses: 0) == .nominalPulsesOutOfRange)
    }

    @Test func tempoBetweenTwentyAndThreeHundredIsAcceptedAndOutsideIsRefusedWithTheValueGiven() {
        #expect(Self.tempoRefusal(19) == .beatsPerMinuteOutOfRange(19))
        #expect(Self.tempoRefusal(20) == nil)
        #expect(Self.tempoRefusal(300) == nil)
        #expect(Self.tempoRefusal(301) == .beatsPerMinuteOutOfRange(301))
        #expect(Self.tempoRefusal(0) == .beatsPerMinuteOutOfRange(0))
        #expect(Self.tempoRefusal(-120) == .beatsPerMinuteOutOfRange(-120))
    }

    @Test func aTimebaseWithAZeroNumeratorOrDenominatorIsRefused() {
        #expect(Self.tempoRefusal(120, numer: 0, denom: 1) == .invalidTimebase)
        #expect(Self.tempoRefusal(120, numer: 1, denom: 0) == .invalidTimebase)
        #expect(Self.tempoRefusal(120, numer: 0, denom: 0) == .invalidTimebase)
        #expect(Self.tempoRefusal(120, numer: 1, denom: 1) == nil)
    }

    @Test func aTempoOutOfRangeOutranksAnInvalidTimebase() {
        #expect(Self.tempoRefusal(19, numer: 0, denom: 0) == .beatsPerMinuteOutOfRange(19))
        #expect(Self.tempoRefusal(301, numer: 1, denom: 0) == .beatsPerMinuteOutOfRange(301))
    }

    // MARK: Tolerance

    @Test func toleranceIsAcceptedFromOneToFiveHundredAndRefusedOutsideWithTheValueGiven() throws {
        let low = try MIDIClockJitterTolerance.make(perMille: 1)
        let high = try MIDIClockJitterTolerance.make(perMille: 500)
        #expect(low.perMille == 1)
        #expect(high.perMille == 500)
        #expect(Self.toleranceRefusal(0) == .toleranceOutOfRange(0))
        #expect(Self.toleranceRefusal(501) == .toleranceOutOfRange(501))
        #expect(Self.toleranceRefusal(-5) == .toleranceOutOfRange(-5))
    }

    @Test func toleranceRangeIsTheArbitrationPolicyRangeAndItsEndsBuild() throws {
        let policyRange = MIDIClockArbitrationPolicy.jitterTolerancePerMilleRange
        #expect(MIDIClockJitterTolerance.perMilleRange == policyRange)
        let lowest = try MIDIClockJitterTolerance.make(perMille: policyRange.lowerBound)
        let highest = try MIDIClockJitterTolerance.make(perMille: policyRange.upperBound)
        #expect(lowest.perMille == policyRange.lowerBound)
        #expect(highest.perMille == policyRange.upperBound)
        #expect(Self.toleranceRefusal(policyRange.lowerBound - 1) != nil)
        #expect(Self.toleranceRefusal(policyRange.upperBound + 1) != nil)
    }
}
