import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension KernelRetirementCarryTests {
    @Test func planEmptyCarryPlansToAnEmptyPlan() throws {
        let plan = try Self.plan(KernelRetirementCarry(), blockCapacity: 1, firstFrame: 0)
        #expect(plan.emissions.isEmpty)
        #expect(plan.dropped == KernelRetirementLoss())
        #expect(plan.superseded == 0)
        #expect(plan.droppedAtRecord == 0)
    }

    @Test func planBlockCapacityBoundsZeroOneMaximumAndMaximumPlusOne() throws {
        let carry = Self.carry([Self.control()])
        #expect(Self.refusal(carry, blockCapacity: -1) == .blockCapacityOutOfRange(-1))
        #expect(Self.refusal(carry, blockCapacity: 0) == .blockCapacityOutOfRange(0))
        #expect(Self.refusal(carry, blockCapacity: 1) == nil)
        #expect(Self.refusal(carry, blockCapacity: KernelCycle.maximumBlockCapacity) == nil)
        #expect(Self.refusal(carry, blockCapacity: 4_097) == .blockCapacityOutOfRange(4_097))
        #expect(Self.refusal(KernelRetirementCarry(), blockCapacity: 0) == .blockCapacityOutOfRange(0))
    }

    @Test func planNegativeFirstFrameIsRefusedWithItsFrameAndZeroIsAccepted() throws {
        let carry = Self.carry([Self.control()])
        #expect(Self.refusal(carry, firstFrame: -1) == .negativeFrame(-1))
        #expect(Self.refusal(carry, firstFrame: Int64.min) == .negativeFrame(Int64.min))
        #expect(Self.refusal(carry, firstFrame: 0) == nil)
        #expect(Self.refusal(KernelRetirementCarry(), firstFrame: -9) == .negativeFrame(-9))
    }

    @Test func planAlreadyDueEventIsEmittedAtTheReplacementFirstFrame() throws {
        let due = Self.control(frame: 5, sequence: 4)
        let plan = try Self.plan(Self.carry([due]), firstFrame: 100)
        let emission = try #require(plan.emissions.first)
        #expect(plan.emissions.count == 1)
        #expect(emission.event.frame == 100)
        #expect(emission.originalFrame == 5)
        #expect(emission.event.scope == due.scope)
        #expect(emission.event.sequence == 4)
        #expect(emission.event.payload == due.payload)
        #expect(emission.completionFrame == nil)
    }

    @Test func planEventsOneBelowAtAndOneAboveTheFirstFrameAreMovedOrKept() throws {
        let carry = Self.carry([
            Self.control(frame: 99, controller: 1, sequence: 1),
            Self.control(frame: 100, controller: 2, sequence: 2),
            Self.control(frame: 101, controller: 3, sequence: 3)
        ])
        let plan = try Self.plan(carry, firstFrame: 100)
        #expect(Self.frames(plan) == [100, 100, 101])
        #expect(plan.emissions.map(\.originalFrame) == [99, 100, 101])
    }

    @Test func planNegativeRecordedFrameIsAlreadyDueAndMovesToFirstFrameZero() throws {
        let plan = try Self.plan(Self.carry([Self.program(frame: -50), Self.control(frame: Int64.min)]), firstFrame: 0)
        #expect(Self.frames(plan) == [0, 0])
        #expect(plan.emissions.map(\.originalFrame) == [-50, Int64.min])
    }

    @Test func planRampCompletionIsTheEmittedFramePlusItsFullDuration() throws {
        let carry = Self.carry([
            Self.ramp(frame: 10, parameter: 1, duration: 40),
            Self.ramp(frame: 500, parameter: 2, duration: 0)
        ])
        let plan = try Self.plan(carry, firstFrame: 100)
        #expect(plan.emissions.map(\.completionFrame) == [140, 500])
        #expect(plan.emissions.map(\.event.frame) == [100, 500])
    }

    @Test func planBlockEndOverflowIsRefusedExactlyWhenFirstFramePlusCapacityExceedsInt64() throws {
        let carry = Self.carry([Self.control()])
        let last = Int64.max - 4_096
        #expect(Self.refusal(carry, blockCapacity: 4_096, firstFrame: last) == nil)
        #expect(Self.refusal(carry, blockCapacity: 4_096, firstFrame: last + 1) == .frameOverflow)
        #expect(Self.refusal(carry, blockCapacity: 1, firstFrame: Int64.max - 1) == nil)
        #expect(Self.refusal(carry, blockCapacity: 1, firstFrame: Int64.max) == .frameOverflow)
        #expect(Self.refusal(KernelRetirementCarry(), blockCapacity: 1, firstFrame: Int64.max) == .frameOverflow)
    }

    @Test func planRampCompletionOverflowIsRefusedExactlyAtTheInt64Boundary() throws {
        let nearEnd = Int64.max - 10
        #expect(Self.refusal(Self.carry([Self.ramp(frame: nearEnd, duration: 10)]), firstFrame: 0) == nil)
        #expect(Self.refusal(Self.carry([Self.ramp(frame: nearEnd, duration: 11)]), firstFrame: 0) == .frameOverflow)
        let moved = Self.carry([Self.ramp(frame: 0, duration: Int64.max)])
        #expect(Self.refusal(moved, firstFrame: 0) == nil)
        #expect(Self.refusal(moved, firstFrame: 1) == .frameOverflow)
    }

    @Test func planSupersededRampWhoseCompletionOverflowsDoesNotRefuse() throws {
        let carry = Self.carry([
            Self.ramp(frame: Int64.max - 1, parameter: 4, duration: 500, sequence: 1),
            Self.ramp(frame: 3, parameter: 4, duration: 5, sequence: 2)
        ])
        let plan = try Self.plan(carry, firstFrame: 0)
        #expect(plan.superseded == 1)
        #expect(plan.emissions.map(\.completionFrame) == [8])
    }

    @Test func planLaneBudgetOfZeroNMinusOneAndNControlsReportsTheOverflowByKind() throws {
        let carry = Self.carry([
            Self.control(frame: 1, controller: 1, sequence: 1),
            Self.control(frame: 2, controller: 2, sequence: 2),
            Self.control(frame: 3, controller: 3, sequence: 3)
        ])
        let all = try Self.plan(carry, lanes: KernelCarryLaneCapacity(state: 3, content: 0))
        #expect(all.emissions.count == 3)
        #expect(all.dropped == KernelRetirementLoss())
        let short = try Self.plan(carry, lanes: KernelCarryLaneCapacity(state: 2, content: 0))
        #expect(Self.sequences(short) == [1, 2])
        #expect(short.dropped.controls == 1)
        #expect(short.dropped.stateful == 1)
        let none = try Self.plan(carry, lanes: KernelCarryLaneCapacity(state: 0, content: 9))
        #expect(none.emissions.isEmpty)
        #expect(none.dropped.controls == 3)
    }

    @Test func planLaneBudgetsCountProgramsAndRampsOnTheirOwnLanes() throws {
        let carry = Self.carry([
            Self.control(frame: 1, sequence: 1),
            Self.program(frame: 2, sequence: 2),
            Self.program(frame: 3, channel: 1, sequence: 3),
            Self.ramp(frame: 4, parameter: 1, sequence: 4),
            Self.ramp(frame: 5, parameter: 2, sequence: 5),
            Self.ramp(frame: 6, parameter: 3, sequence: 6)
        ])
        let plan = try Self.plan(carry, lanes: KernelCarryLaneCapacity(state: 1, content: 2))
        #expect(Self.sequences(plan) == [1, 4, 5])
        #expect(plan.dropped.controls == 0)
        #expect(plan.dropped.programs == 2)
        #expect(plan.dropped.ramps == 1)
        #expect(plan.dropped.noteOns == 0)
        #expect(plan.dropped.clockPulses == 0)
    }

    @Test func planNegativeLaneBudgetIsNoRoomAndNeverTraps() throws {
        let lanes = KernelCarryLaneCapacity(state: -5, content: -1)
        #expect(lanes.state == 0)
        #expect(lanes.content == 0)
        let plan = try Self.plan(Self.carry([Self.control(), Self.ramp()]), lanes: lanes)
        #expect(plan.emissions.isEmpty)
        #expect(plan.dropped.controls == 1)
        #expect(plan.dropped.ramps == 1)
    }

    @Test func planUncarriedLanesHaveNoRoom() {
        #expect(Self.roomy.room(for: .release) == 0)
        #expect(Self.roomy.room(for: .transport) == 0)
        #expect(KernelCarryLaneCapacity(state: 3, content: 5).room(for: .state) == 3)
        #expect(KernelCarryLaneCapacity(state: 3, content: 5).room(for: .content) == 5)
    }

    @Test func planBlockCapacityCutKeepsTheEarliestAndCountsTheRestByKind() throws {
        let carry = Self.carry([
            Self.control(frame: 1, sequence: 1),
            Self.program(frame: 2, sequence: 2),
            Self.ramp(frame: 3, sequence: 3),
            Self.ramp(frame: 4, parameter: 2, sequence: 4)
        ])
        let exact = try Self.plan(carry, blockCapacity: 4)
        #expect(exact.emissions.count == 4)
        #expect(exact.dropped == KernelRetirementLoss())
        let cut = try Self.plan(carry, blockCapacity: 2)
        #expect(Self.sequences(cut) == [1, 2])
        #expect(cut.dropped.controls == 0)
        #expect(cut.dropped.programs == 0)
        #expect(cut.dropped.ramps == 2)
    }

    @Test func planLaneBudgetCutRunsBeforeTheBlockCapacityCut() throws {
        let carry = Self.carry([
            Self.control(frame: 1, controller: 1, sequence: 1),
            Self.control(frame: 2, controller: 2, sequence: 2),
            Self.control(frame: 3, controller: 3, sequence: 3),
            Self.ramp(frame: 4, sequence: 4)
        ])
        let plan = try Self.plan(carry, blockCapacity: 2, lanes: KernelCarryLaneCapacity(state: 1, content: 1))
        #expect(Self.sequences(plan) == [1, 4])
        #expect(plan.dropped.controls == 2)
        #expect(plan.dropped.ramps == 0)
    }

    @Test func planFullCarryReportsItsRecordTimeDropsAndPlansTheStoredEvents() throws {
        let carry = Self.carry(Self.distinctControls(259))
        let plan = try Self.plan(carry, blockCapacity: 4_096)
        #expect(plan.emissions.count == 256)
        #expect(plan.droppedAtRecord == 3)
        #expect(plan.dropped == KernelRetirementLoss())
        #expect(plan.superseded == 0)
    }

    @Test func planFullCarryOverASmallBlockReportsEveryCutControl() throws {
        let plan = try Self.plan(Self.carry(Self.distinctControls(256)), blockCapacity: 1)
        #expect(plan.emissions.count == 1)
        #expect(plan.dropped.controls == 255)
    }

    @Test func planControlsOfDifferentScopesNeverSupersedeEachOtherButTheSameScopeDoes() throws {
        let other = Self.scoped(Self.control(sequence: 2), 8)
        let both = try Self.plan(Self.carry([Self.control(sequence: 1), other]))
        #expect(both.superseded == 0)
        #expect(both.emissions.map(\.event.scope) == [3, 8])
        let same = try Self.plan(Self.carry([Self.control(sequence: 1), Self.control(sequence: 2)]))
        #expect(same.superseded == 1)
        #expect(same.emissions.count == 1)
    }

    @Test func planProgramsOfDifferentScopesNeverSupersedeEachOtherButTheSameScopeDoes() throws {
        let other = Self.scoped(Self.program(sequence: 2), 8)
        let both = try Self.plan(Self.carry([Self.program(sequence: 1), other]))
        #expect(both.superseded == 0)
        #expect(both.emissions.map(\.event.scope) == [3, 8])
        let same = try Self.plan(Self.carry([Self.program(sequence: 1), Self.program(sequence: 2)]))
        #expect(same.superseded == 1)
        #expect(same.emissions.count == 1)
    }

    @Test func planRampsOfDifferentScopesNeverSupersedeEachOtherButTheSameScopeDoes() throws {
        let other = Self.scoped(Self.ramp(sequence: 2), 8)
        let both = try Self.plan(Self.carry([Self.ramp(sequence: 1), other]))
        #expect(both.superseded == 0)
        #expect(both.emissions.map(\.event.scope) == [3, 8])
        let same = try Self.plan(Self.carry([Self.ramp(sequence: 1), Self.ramp(sequence: 2)]))
        #expect(same.superseded == 1)
        #expect(same.emissions.count == 1)
    }

    @Test func planExtraScopedSurvivorsBeyondTheBlockCapacityAreReportedAsDropped() throws {
        let carry = Self.carry([Self.control(sequence: 1), Self.scoped(Self.control(sequence: 2), 8)])
        let plan = try Self.plan(carry, blockCapacity: 1)
        #expect(plan.emissions.count == 1)
        #expect(plan.superseded == 0)
        #expect(plan.dropped.controls == 1)
    }
}
