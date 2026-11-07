import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIInternalClockTests {
    // MARK: - Transitions

    @Test
    func initialTransportIsStoppedAtTickZeroOnTheFirstGeneration() {
        #expect(MIDIInternalTransport.initial.generation == .initial)
        #expect(MIDIInternalTransport.initial.state == .stopped(atTicks: 0))
    }

    @Test
    func startingRunsFromPositionZeroAndAdvancesTheGenerationByOne() throws {
        let initial = MIDIInternalTransport.initial
        let started = try initial.starting(atFrame: 4_800)
        let second = try Generation(2)
        #expect(started.generation == second)
        #expect(started.state == .running(Self.run(from: 0, at: 4_800, .start)))
        #expect(initial.generation == .initial)
        #expect(initial.state == .stopped(atTicks: 0))
    }

    @Test
    func startingIgnoresTheStoppedPositionAndAlwaysBeginsAtZero() throws {
        let stopped = try MIDIInternalTransport.stopped(atTicks: 7_680, generation: .initial)
        let started = try stopped.starting(atFrame: 10)
        #expect(started.state == .running(Self.run(from: 0, at: 10, .start)))
        #expect(stopped.state == .stopped(atTicks: 7_680))
    }

    @Test
    func continuingRunsFromTheStoppedPositionWithTheContinueOrigin() throws {
        let stopped = try MIDIInternalTransport.stopped(atTicks: 7_680, generation: .initial)
        let continued = try stopped.continuing(atFrame: 12_000)
        let second = try Generation(2)
        #expect(continued.generation == second)
        #expect(continued.state == .running(Self.run(from: 7_680, at: 12_000, .continue)))
        #expect(stopped.state == .stopped(atTicks: 7_680))
        let atZero = try MIDIInternalTransport.initial.continuing(atFrame: 5)
        #expect(atZero.state == .running(Self.run(from: 0, at: 5, .continue)))
    }

    @Test
    func stoppingRecordsTheStopFrameAndTheMapsRestingPosition() throws {
        let running = try Self.started()
        let map = try Self.map(for: running)
        let run = Self.run(from: 0, at: 0, .start)
        let pending = try running.stopping(atFrame: 2_500, in: map)
        let third = try Generation(3)
        #expect(pending.generation == third)
        #expect(pending.state == .stopping(run, stopFrame: 2_500, restingAtTicks: 1_600))
        let earlier = try running.stopping(atFrame: 2_000, in: map)
        #expect(earlier.state == .stopping(run, stopFrame: 2_000, restingAtTicks: 1_280))
        let second = try Generation(2)
        #expect(running.generation == second)
    }

    @Test
    func stoppingAContinueRestsAtTheMapPositionAfterTheStopFrame() throws {
        let running = try Self.continued(fromTicks: 3_840, atFrame: 6_000)
        let map = try Self.map(for: running, anchorFrame: 6_000, anchorTicks: 3_840)
        let pending = try running.stopping(atFrame: 12_000, in: map)
        let run = Self.run(from: 3_840, at: 6_000, .continue)
        #expect(pending.state == .stopping(run, stopFrame: 12_000, restingAtTicks: 7_680))
    }

    @Test
    func locatingMovesAStoppedTransportAndAdvancesTheGeneration() throws {
        let located = try MIDIInternalTransport.initial.locating(toTicks: 3_840)
        let second = try Generation(2)
        #expect(located.generation == second)
        #expect(located.state == .stopped(atTicks: 3_840))
    }

    @Test
    func generationsAdvanceByExactlyOnePerTransitionAndSettlingKeepsThem() throws {
        let first = MIDIInternalTransport.initial
        let running = try first.starting(atFrame: 0)
        let pending = try running.stopping(atFrame: 2_500, in: Self.map(for: running))
        let holding = try Self.plan(pending, Self.map(for: pending), Self.window(0, 2_501))
        let settled = pending.settled(after: holding)
        let located = try settled.locating(toTicks: 3_840)
        let continued = try located.continuing(atFrame: 6_000)
        let values = [first, running, pending, settled, located, continued].map(\.generation.value)
        #expect(values == [1, 2, 3, 3, 4, 5])
        #expect(settled.state == .stopped(atTicks: 1_600))
        #expect(located.state == .stopped(atTicks: 3_840))
    }

    // MARK: - Refusals

    @Test
    func stoppingAStoppedTransportIsRefused() throws {
        let stopped = MIDIInternalTransport.initial
        let map = try Self.map(for: stopped)
        #expect(throws: MIDIInternalClockError.alreadyStopped) { try stopped.stopping(atFrame: 1_000, in: map) }
    }

    @Test
    func startingContinuingAndLocatingAreRefusedWhileRunning() throws {
        let running = try Self.started()
        #expect(throws: MIDIInternalClockError.alreadyRunning) { try running.starting(atFrame: 10) }
        #expect(throws: MIDIInternalClockError.alreadyRunning) { try running.continuing(atFrame: 10) }
        #expect(throws: MIDIInternalClockError.locateWhileRunning) { try running.locating(toTicks: 3_840) }
    }

    @Test
    func everyTransitionIsRefusedWhileAStopIsPending() throws {
        let pending = try Self.stopPending(atFrame: 2_500)
        let map = try Self.map(for: pending)
        let refusal = MIDIInternalClockError.stopPending(stopFrame: 2_500)
        #expect(throws: refusal) { try pending.starting(atFrame: 3_000) }
        #expect(throws: refusal) { try pending.continuing(atFrame: 3_000) }
        #expect(throws: refusal) { try pending.stopping(atFrame: 4_000, in: map) }
        #expect(throws: refusal) { try pending.locating(toTicks: 0) }
    }

    @Test
    func stoppingWithAMapOfAnotherTransportGenerationIsRefused() throws {
        let running = try Self.started()
        let older = try Self.map(for: .initial)
        let newer = try Self.map(for: running.stopping(atFrame: 2_500, in: Self.map(for: running)))
        #expect(throws: MIDIInternalClockError.staleTransport) { try running.stopping(atFrame: 1_000, in: older) }
        #expect(throws: MIDIInternalClockError.staleTransport) { try running.stopping(atFrame: 1_000, in: newer) }
    }

    @Test
    func theStopFrameMustBeAtLeastOneFrameAfterTheRunStart() throws {
        let running = try Self.started(atFrame: 100)
        let map = try Self.map(for: running, anchorFrame: 100)
        for frame in [Int64(99), 100] {
            #expect(throws: MIDIInternalClockError.stopNotAfterStart(startFrame: 100, stopFrame: frame)) {
                try running.stopping(atFrame: frame, in: map)
            }
        }
        let pending = try running.stopping(atFrame: 101, in: map)
        let run = Self.run(from: 0, at: 100, .start)
        #expect(pending.state == .stopping(run, stopFrame: 101, restingAtTicks: 1))
    }

    @Test
    func stoppingRefusesAFrameWhoseRestingPositionOverflowsTheTickRange() throws {
        let running = try Self.started()
        let map = try Self.map(for: running, rate: 192_000, tempos: [(0, 60_000)])
        #expect(throws: MIDIInternalClockError.clockMap(.overflow)) {
            try running.stopping(atFrame: Int64.max, in: map)
        }
    }

    @Test
    func aRestingPositionOfZeroIsAcceptedAndNegativePositionsAreRefused() throws {
        let running = try Self.started()
        let map = try Self.map(for: running, anchorFrame: 100_000)
        let atZero = try running.stopping(atFrame: 100_000, in: map)
        let run = Self.run(from: 0, at: 0, .start)
        #expect(atZero.state == .stopping(run, stopFrame: 100_000, restingAtTicks: 0))
        #expect(throws: MIDIInternalClockError.positionOutOfRange(ticks: -1)) {
            try running.stopping(atFrame: 99_999, in: map)
        }
        #expect(throws: MIDIInternalClockError.positionOutOfRange(ticks: -63_999)) {
            try running.stopping(atFrame: 1, in: map)
        }
    }

    @Test
    func aStopBeyondTheSongPositionRangeRestsThereAndThenRefusesContinue() throws {
        let running = try Self.started()
        let map = try Self.map(for: running)
        let pending = try running.stopping(atFrame: 98_304_000, in: map)
        let run = Self.run(from: 0, at: 0, .start)
        #expect(pending.state == .stopping(run, stopFrame: 98_304_000, restingAtTicks: 62_914_560))
        let holding = try Self.plan(pending, Self.map(for: pending), Self.window(98_304_000, 1))
        #expect(holding.events == [Self.event(98_304_000, .stop)])
        let stopped = pending.settled(after: holding)
        #expect(stopped.state == .stopped(atTicks: 62_914_560))
        #expect(throws: MIDIInternalClockError.positionOutOfRange(ticks: 62_914_560)) {
            try stopped.continuing(atFrame: 0)
        }
        let restarted = try stopped.starting(atFrame: 10)
        #expect(restarted.state == .running(Self.run(from: 0, at: 10, .start)))
    }

    @Test
    func refusedTransitionsLeaveEveryStateAsItWasAndTheNextSuccessAdvancesByOne() throws {
        let stopped = MIDIInternalTransport.initial
        let running = try Self.started()
        let pending = try Self.stopPending(atFrame: 2_500)
        let map = try Self.map(for: running)
        let holding = try Self.plan(pending, Self.map(for: pending), Self.window(0, 2_501))
        #expect(throws: MIDIInternalClockError.alreadyStopped) { try stopped.stopping(atFrame: 1_000, in: map) }
        #expect(throws: MIDIInternalClockError.alreadyRunning) { try running.starting(atFrame: 10) }
        #expect(throws: MIDIInternalClockError.stopPending(stopFrame: 2_500)) { try pending.locating(toTicks: 0) }
        let run = Self.run(from: 0, at: 0, .start)
        #expect(stopped.generation == .initial)
        #expect(stopped.state == .stopped(atTicks: 0))
        #expect(running.generation.value == 2)
        #expect(running.state == .running(run))
        #expect(pending.generation.value == 3)
        #expect(pending.state == .stopping(run, stopFrame: 2_500, restingAtTicks: 1_600))
        #expect(try stopped.starting(atFrame: 0).generation.value == 2)
        #expect(try running.stopping(atFrame: 2_500, in: map).generation.value == 3)
        #expect(pending.settled(after: holding).generation.value == 3)
    }

    // MARK: - Bounds

    @Test
    func locatingAndContinuingAcceptTheSongPositionRangeAndRefuseOneTickBeyond() throws {
        let last = MIDIClockMath.maximumSongPositionTicks
        let beyond = last + 1
        #expect(last == 62_910_720)
        let atLast = try MIDIInternalTransport.initial.locating(toTicks: last)
        #expect(atLast.state == .stopped(atTicks: 62_910_720))
        let atZero = try atLast.locating(toTicks: 0)
        #expect(atZero.state == .stopped(atTicks: 0))
        for ticks in [Int64(-1), beyond] {
            #expect(throws: MIDIInternalClockError.positionOutOfRange(ticks: ticks)) {
                try MIDIInternalTransport.initial.locating(toTicks: ticks)
            }
        }
        let continuable = try MIDIInternalTransport.stopped(atTicks: last, generation: .initial)
        let continued = try continuable.continuing(atFrame: 0)
        #expect(continued.state == .running(Self.run(from: 62_910_720, at: 0, .continue)))
        let stoppedBeyond = try MIDIInternalTransport.stopped(atTicks: beyond, generation: .initial)
        #expect(throws: MIDIInternalClockError.positionOutOfRange(ticks: 62_910_721)) {
            try stoppedBeyond.continuing(atFrame: 0)
        }
    }

    @Test
    func theStoppedFactoryRefusesNegativePositionsAndKeepsAnyOther() throws {
        let zero = try MIDIInternalTransport.stopped(atTicks: 0, generation: .initial)
        #expect(zero == MIDIInternalTransport.initial)
        let beyond = try MIDIInternalTransport.stopped(atTicks: 62_910_721, generation: .initial)
        #expect(beyond.state == .stopped(atTicks: 62_910_721))
        let third = try Generation(3)
        let onThird = try MIDIInternalTransport.stopped(atTicks: 5, generation: third)
        #expect(onThird.generation == third)
        #expect(onThird.state == .stopped(atTicks: 5))
        #expect(throws: MIDIInternalClockError.positionOutOfRange(ticks: -1)) {
            try MIDIInternalTransport.stopped(atTicks: -1, generation: .initial)
        }
    }

    @Test
    func everyTransitionRefusesAtTheLastGenerationAndSucceedsOneBefore() throws {
        let last = try Generation(Generation.maximumValue)
        let beforeLast = try Generation(Generation.maximumValue - 1)
        let stoppedAtLast = try MIDIInternalTransport.stopped(atTicks: 0, generation: last)
        #expect(throws: MIDIInternalClockError.generationOverflow) { try stoppedAtLast.starting(atFrame: 0) }
        #expect(throws: MIDIInternalClockError.generationOverflow) { try stoppedAtLast.continuing(atFrame: 0) }
        #expect(throws: MIDIInternalClockError.generationOverflow) { try stoppedAtLast.locating(toTicks: 0) }
        let stoppedBefore = try MIDIInternalTransport.stopped(atTicks: 0, generation: beforeLast)
        #expect(try stoppedBefore.continuing(atFrame: 0).generation == last)
        #expect(try stoppedBefore.locating(toTicks: 0).generation == last)
        let running = try stoppedBefore.starting(atFrame: 0)
        #expect(running.generation == last)
        let map = try Self.map(for: running)
        #expect(throws: MIDIInternalClockError.generationOverflow) { try running.stopping(atFrame: 1_000, in: map) }
        // Argument refusals come before the generation check.
        #expect(throws: MIDIInternalClockError.positionOutOfRange(ticks: -1)) {
            try stoppedAtLast.locating(toTicks: -1)
        }
        #expect(throws: MIDIInternalClockError.stopNotAfterStart(startFrame: 0, stopFrame: 0)) {
            try running.stopping(atFrame: 0, in: map)
        }
    }

    // MARK: - Settling

    @Test
    func settlingCompletesAStopOnlyOnceTheWindowEndIsPastTheStopFrame() throws {
        let pending = try Self.stopPending(atFrame: 2_500)
        let map = try Self.map(for: pending)
        let beforeStop = [Self.event(0, .start), Self.clock(0, 0), Self.clock(1_000, 1), Self.clock(2_000, 2)]
        for count in [Int64(2_499), 2_500] {
            let plan = try Self.plan(pending, map, Self.window(0, count))
            #expect(plan.events == beforeStop)
            #expect(pending.settled(after: plan) == pending)
        }
        let holding = try Self.plan(pending, map, Self.window(0, 2_501))
        let settled = pending.settled(after: holding)
        #expect(settled.state == .stopped(atTicks: 1_600))
        #expect(settled.generation == pending.generation)
        let late: [(Int64, Int64)] = [(2_501, 1_000), (100_000, 1_000), (Int64.max - 1_000, 1_000)]
        for (start, count) in late {
            let plan = try Self.plan(pending, map, Self.window(start, count))
            #expect(plan.events == [Self.event(start, .stop)])
            #expect(pending.settled(after: plan).state == .stopped(atTicks: 1_600))
        }
    }

    @Test
    func settlingIgnoresAPlanWithoutAStopAndAPlanOfAnotherTransportGeneration() throws {
        let pending = try Self.stopPending(atFrame: 2_500)
        let map = try Self.map(for: pending)
        let holding = try Self.plan(pending, map, Self.window(0, 2_501))
        let withoutStop = try Self.plan(pending, map, Self.window(0, 2_500))
        #expect(withoutStop.events.count == 4)
        #expect(pending.settled(after: withoutStop) == pending)
        let later = try Self.laterStopPending(atFrame: 2_500)
        let laterHolding = try Self.plan(later, Self.map(for: later), Self.window(0, 2_501))
        #expect(later.generation.value == 4)
        #expect(laterHolding.transportGeneration == later.generation)
        #expect(laterHolding.events.last == Self.event(2_500, .stop))
        #expect(pending.settled(after: laterHolding) == pending)
        #expect(later.settled(after: holding) == later)
        #expect(pending.settled(after: holding).state == .stopped(atTicks: 1_600))
        #expect(later.settled(after: laterHolding).state == .stopped(atTicks: 1_600))
    }

    @Test
    func settlingLeavesRunningAndStoppedTransportsAlone() throws {
        let pending = try Self.stopPending(atFrame: 2_500)
        let holding = try Self.plan(pending, Self.map(for: pending), Self.window(0, 2_501))
        // `running` shares the generation of `pending`, so only its state keeps the plan from settling it.
        let running = try MIDIInternalTransport.initial.locating(toTicks: 0).starting(atFrame: 0)
        #expect(running.generation == pending.generation)
        #expect(running.settled(after: holding) == running)
        let stopped = try MIDIInternalTransport.stopped(atTicks: 3_840, generation: pending.generation)
        #expect(stopped.settled(after: holding) == stopped)
    }
}
