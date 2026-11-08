import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension KernelRetirementCarryTests {
    // MARK: last writer

    @Test func planSupersedesEarlierControlsOfTheSameChannelAndControllerAndCountsThemSuperseded() throws {
        let carry = Self.carry([
            Self.control(frame: 1, value: 10, sequence: 1),
            Self.control(frame: 2, value: 20, sequence: 2),
            Self.control(frame: 3, value: 30, sequence: 3)
        ])
        let plan = try Self.plan(carry)
        #expect(plan.superseded == 2)
        #expect(plan.emissions.map(\.event.payload) == [.control(channel: 0, controller: 1, value: 30)])
    }

    @Test func planControlsDifferingInChannelOrControllerAreBothKept() throws {
        let carry = Self.carry([
            Self.control(frame: 1, channel: 0, controller: 1, sequence: 1),
            Self.control(frame: 2, channel: 1, controller: 1, sequence: 2),
            Self.control(frame: 3, channel: 0, controller: 2, sequence: 3)
        ])
        let plan = try Self.plan(carry)
        #expect(plan.emissions.count == 3)
        #expect(plan.superseded == 0)
    }

    @Test func planSupersedesProgramsByChannelAloneWhateverTheProgramAndBank() throws {
        let carry = Self.carry([
            Self.program(frame: 1, channel: 2, program: 1, bank: 1, sequence: 1),
            Self.program(frame: 2, channel: 3, program: 9, bank: 9, sequence: 2),
            Self.program(frame: 3, channel: 2, program: 7, bank: 8, sequence: 3)
        ])
        let plan = try Self.plan(carry)
        #expect(plan.superseded == 1)
        #expect(plan.emissions.map(\.event.payload) == [
            .program(channel: 3, program: 9, bank: 9), .program(channel: 2, program: 7, bank: 8)
        ])
    }

    @Test func planSupersedesRampsByParameterAloneWhateverTheTargetAndDuration() throws {
        let carry = Self.carry([
            Self.ramp(frame: 1, parameter: 4, value: 1, duration: 5, sequence: 1),
            Self.ramp(frame: 2, parameter: 5, value: 2, duration: 6, sequence: 2),
            Self.ramp(frame: 3, parameter: 4, value: 3, duration: 7, sequence: 3)
        ])
        let plan = try Self.plan(carry)
        #expect(plan.superseded == 1)
        #expect(plan.emissions.map(\.event.payload) == [
            .rampTo(parameter: 5, value: 2, durationFrames: 6), .rampTo(parameter: 4, value: 3, durationFrames: 7)
        ])
    }

    @Test func planKeysOfDifferentKindsNeverSupersedeEachOther() throws {
        let carry = Self.carry([
            Self.control(frame: 1, channel: 0, controller: 0, sequence: 1),
            Self.program(frame: 2, channel: 0, sequence: 2),
            Self.ramp(frame: 3, parameter: 0, sequence: 3)
        ])
        let plan = try Self.plan(carry)
        #expect(plan.emissions.count == 3)
        #expect(plan.superseded == 0)
    }

    @Test func planLastRecordedWriterWinsEvenWithALowerSequenceAndAnEarlierFrame() throws {
        let carry = Self.carry([
            Self.control(frame: 90, value: 1, sequence: 9),
            Self.control(frame: 10, value: 2, sequence: 1)
        ])
        let plan = try Self.plan(carry)
        #expect(plan.emissions.map(\.event.payload) == [.control(channel: 0, controller: 1, value: 2)])
        #expect(plan.emissions.map(\.originalFrame) == [10])
    }

    @Test func planSupersededWritersAreNotCountedAsLoss() throws {
        let carry = Self.carry([Self.control(sequence: 1), Self.control(sequence: 2), Self.program(sequence: 3)])
        let plan = try Self.plan(carry, lanes: KernelCarryLaneCapacity(state: 2, content: 0))
        #expect(plan.superseded == 1)
        #expect(plan.dropped == KernelRetirementLoss())
        #expect(!plan.dropped.receiverStateMayBeStale)
    }

    // MARK: delivery order

    @Test func planOrdersByFrameFirst() throws {
        let carry = Self.carry([
            Self.ramp(frame: 10, parameter: 1, sequence: 9),
            Self.control(frame: 20, controller: 1, sequence: 5),
            Self.program(frame: 30, sequence: 1)
        ])
        #expect(Self.sequences(try Self.plan(carry)) == [9, 5, 1])
    }

    @Test func planOrdersAStateEventBeforeAContentEventOfTheSameFrameWhateverTheirSequence() throws {
        let content = Self.ramp(frame: 40, parameter: 1, sequence: 1)
        let state = Self.control(frame: 40, sequence: 9)
        #expect(Self.sequences(try Self.plan(Self.carry([content, state]))) == [9, 1])
        #expect(Self.sequences(try Self.plan(Self.carry([state, content]))) == [9, 1])
    }

    @Test func planEqualFrameAndLaneKeepOriginalSequenceInBothRecordedOrders() throws {
        let first = Self.control(frame: 40, controller: 1, sequence: 3)
        let second = Self.control(frame: 40, controller: 2, sequence: 8)
        #expect(Self.sequences(try Self.plan(Self.carry([first, second]))) == [3, 8])
        #expect(Self.sequences(try Self.plan(Self.carry([second, first]))) == [3, 8])
    }

    @Test func planEqualSequenceFallsBackToRecordedOrderInBothOrders() throws {
        let first = Self.control(frame: 40, controller: 1, value: 1, sequence: 5)
        let second = Self.control(frame: 40, controller: 2, value: 2, sequence: 5)
        let forward = try Self.plan(Self.carry([first, second]))
        let reversed = try Self.plan(Self.carry([second, first]))
        #expect(forward.emissions.map(\.event) == [first, second])
        #expect(reversed.emissions.map(\.event) == [second, first])
    }

    @Test func planAlreadyDueEventsOrderBySequenceAfterRetimingNotByTheirOriginalFrame() throws {
        let later = Self.control(frame: 3, controller: 1, sequence: 9)
        let earlier = Self.control(frame: 1, controller: 2, sequence: 8)
        let plan = try Self.plan(Self.carry([later, earlier]), firstFrame: 100)
        #expect(Self.sequences(plan) == [8, 9])
        #expect(plan.emissions.map(\.originalFrame) == [1, 3])
    }

    @Test func planRetimedStateEventPrecedesALaterContentEventAtTheFirstFrame() throws {
        let ramp = Self.ramp(frame: 100, parameter: 1, sequence: 1)
        let due = Self.program(frame: 2, sequence: 2)
        let plan = try Self.plan(Self.carry([ramp, due]), firstFrame: 100)
        #expect(Self.sequences(plan) == [2, 1])
    }

    @Test func planningTheEmissionsAgainWithTheSameFirstFrameReproducesThem() throws {
        let carry = Self.carry([
            Self.ramp(frame: 3, parameter: 2, sequence: 4),
            Self.control(frame: 9, controller: 3, sequence: 2),
            Self.program(frame: 150, sequence: 7),
            Self.control(frame: 1, controller: 4, sequence: 1)
        ])
        let first = try Self.plan(carry, firstFrame: 100)
        let second = try Self.plan(Self.carry(first.emissions.map(\.event)), firstFrame: 100)
        #expect(second.emissions.map(\.event) == first.emissions.map(\.event))
        #expect(second.superseded == 0)
    }

    // MARK: ramp validity

    @Test func planRampWithNegativeDurationOrNonFiniteValueIsRefusedWithItsParameter() throws {
        #expect(Self.refusal(Self.carry([Self.ramp(parameter: 9, duration: -1)])) == .invalidRamp(parameter: 9))
        #expect(Self.refusal(Self.carry([Self.ramp(parameter: 8, value: .nan)])) == .invalidRamp(parameter: 8))
        #expect(Self.refusal(Self.carry([Self.ramp(parameter: 7, value: .infinity)])) == .invalidRamp(parameter: 7))
        #expect(Self.refusal(Self.carry([Self.ramp(parameter: 6, value: -.infinity)])) == .invalidRamp(parameter: 6))
        #expect(Self.refusal(Self.carry([Self.ramp(parameter: 5, duration: Int64.min)])) == .invalidRamp(parameter: 5))
    }

    @Test func planRampWithZeroDurationOrTheLargestFiniteValueIsAccepted() throws {
        #expect(Self.refusal(Self.carry([Self.ramp(value: 0, duration: 0)])) == nil)
        #expect(Self.refusal(Self.carry([Self.ramp(value: .greatestFiniteMagnitude, duration: 1)])) == nil)
        #expect(Self.refusal(Self.carry([Self.ramp(value: -.greatestFiniteMagnitude, duration: 1)])) == nil)
    }

    @Test func planInvalidRampReportsTheLowestParameterInBothRecordedOrders() throws {
        let high = Self.ramp(parameter: 7, duration: -1)
        let low = Self.ramp(parameter: 3, value: .nan)
        #expect(Self.refusal(Self.carry([high, low])) == .invalidRamp(parameter: 3))
        #expect(Self.refusal(Self.carry([low, high])) == .invalidRamp(parameter: 3))
        #expect(Self.refusal(Self.carry([Self.ramp(parameter: 0, duration: -1), high])) == .invalidRamp(parameter: 0))
    }

    @Test func planInvalidRampIsRefusedEvenWhenALaterValidWriterSupersedesIt() throws {
        let carry = Self.carry([
            Self.ramp(parameter: 4, duration: -1, sequence: 1),
            Self.ramp(parameter: 4, sequence: 2)
        ])
        #expect(Self.refusal(carry) == .invalidRamp(parameter: 4))
    }

    // MARK: refusal order (both-defects fixtures)

    @Test func planEachRefusalAloneReportsItselfWithItsOwnPayload() throws {
        let valid = Self.carry([Self.control()])
        let invalid = Self.carry([Self.ramp(parameter: 11, duration: -1)])
        #expect(Self.refusal(valid, blockCapacity: 4_100) == .blockCapacityOutOfRange(4_100))
        #expect(Self.refusal(valid, firstFrame: -12) == .negativeFrame(-12))
        #expect(Self.refusal(invalid) == .invalidRamp(parameter: 11))
        let overflowing = Self.carry([Self.ramp(frame: Int64.max, parameter: 4, duration: 1)])
        #expect(Self.refusal(overflowing) == .frameOverflow)
    }

    @Test func planBlockCapacityIsReportedBeforeANegativeFrame() throws {
        let carry = Self.carry([Self.control()])
        #expect(Self.refusal(carry, blockCapacity: 0, firstFrame: -5) == .blockCapacityOutOfRange(0))
        #expect(Self.refusal(carry, blockCapacity: 0, firstFrame: 5) == .blockCapacityOutOfRange(0))
        #expect(Self.refusal(carry, blockCapacity: 1, firstFrame: -5) == .negativeFrame(-5))
    }

    @Test func planNegativeFrameIsReportedBeforeAnInvalidRamp() throws {
        let carry = Self.carry([Self.ramp(parameter: 2, duration: -1)])
        #expect(Self.refusal(carry, firstFrame: -5) == .negativeFrame(-5))
        #expect(Self.refusal(carry, firstFrame: 5) == .invalidRamp(parameter: 2))
    }

    @Test func planInvalidRampIsReportedBeforeARampCompletionOverflow() throws {
        let carry = Self.carry([
            Self.ramp(frame: Int64.max, parameter: 5, duration: 9, sequence: 1),
            Self.ramp(frame: 0, parameter: 2, duration: -1, sequence: 2)
        ])
        #expect(Self.refusal(carry) == .invalidRamp(parameter: 2))
        #expect(Self.refusal(Self.carry([Self.ramp(frame: Int64.max, parameter: 5, duration: 9)])) == .frameOverflow)
    }

    @Test func planEachRefusalFiresAndAValidCarryStillPlans() throws {
        let events = [Self.ramp(parameter: 3, value: .nan, duration: -1), Self.control(sequence: 1), Self.program()]
        let carry = Self.carry(events)
        #expect(Self.refusal(carry, blockCapacity: 0) == .blockCapacityOutOfRange(0))
        #expect(Self.refusal(carry, firstFrame: -1) == .negativeFrame(-1))
        #expect(Self.refusal(carry) == .invalidRamp(parameter: 3))
        let sound = Self.carry(Array(events.dropFirst()))
        let overflowing = Self.carry([Self.ramp(frame: Int64.max, parameter: 4, duration: 1)])
        #expect(Self.refusal(overflowing) == .frameOverflow)
        #expect(try Self.plan(sound).emissions.count == 2)
    }
}
