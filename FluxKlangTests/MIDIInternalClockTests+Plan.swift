import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIInternalClockTests {
    // MARK: - Start, Continue and clocks

    @Test
    func aStartPrecedesTheFirstClockAtTheSameFrame() throws {
        let running = try Self.started()
        let plan = try Self.plan(running, Self.map(for: running), Self.window(0, 2_500))
        #expect(plan.events == [Self.event(0, .start), Self.clock(0, 0), Self.clock(1_000, 1), Self.clock(2_000, 2)])
        #expect(plan.events.allSatisfy { $0.hostStamp == nil })
    }

    @Test
    func aPlanCarriesTheGenerationsClockAndWindowItWasMadeFor() throws {
        let running = try Self.started()
        let window = try Self.window(0, 2_500)
        let plan = try Self.plan(running, Self.map(for: running), window)
        let second = try Generation(2)
        #expect(plan.transportGeneration == second)
        #expect(plan.sampleGeneration == .initial)
        #expect(plan.sampleClock == Self.sampleClock)
        #expect(plan.window == window)
        let secondWindow = try Self.window(0, 2_500, sampleGeneration: second)
        let secondMap = try Self.map(Self.map(for: running), onSampleGeneration: second)
        let onSecond = try Self.plan(running, secondMap, secondWindow)
        #expect(onSecond.sampleGeneration == second)
        #expect(onSecond.events == plan.events)
    }

    @Test
    func aContinueEmitsTheSongPositionThenTheContinueThenTheClocks() throws {
        let running = try Self.continued(fromTicks: 3_840, atFrame: 6_000)
        let map = try Self.map(for: running, anchorFrame: 6_000, anchorTicks: 3_840)
        let plan = try Self.plan(running, map, Self.window(6_000, 2_001))
        #expect(plan.events == [Self.event(6_000, .songPosition(1)), Self.event(6_000, .continue),
                                Self.clock(6_000, 6), Self.clock(7_000, 7), Self.clock(8_000, 8)])
    }

    @Test
    func aContinueAtPositionZeroEmitsSongPositionZeroAndTheContinueMessage() throws {
        let running = try Self.continued(fromTicks: 0, atFrame: 0)
        let plan = try Self.plan(running, Self.map(for: running), Self.window(0, 1_001))
        #expect(plan.events == [Self.event(0, .songPosition(0)), Self.event(0, .continue),
                                Self.clock(0, 0), Self.clock(1_000, 1)])
    }

    @Test
    func aContinueAtTheLastSongPositionEmitsPointerSixteenThousandThreeHundredEightyThree() throws {
        let last = MIDIClockMath.maximumSongPositionTicks
        let running = try Self.continued(fromTicks: last, atFrame: 0)
        let map = try Self.map(for: running, anchorTicks: last)
        let plan = try Self.plan(running, map, Self.window(0, 1_001))
        #expect(plan.events == [Self.event(0, .songPosition(16_383)), Self.event(0, .continue),
                                Self.clock(0, 98_298), Self.clock(1_000, 98_299)])
    }

    @Test
    func aTempoChangeInTheMapMovesLaterPulsesToTheirExactFrames() throws {
        let running = try Self.started()
        let map = try Self.map(for: running, tempos: [(0, 500_000), (1_280, 250_000)])
        let plan = try Self.plan(running, map, Self.window(0, 3_001))
        #expect(plan.events == [Self.event(0, .start), Self.clock(0, 0), Self.clock(1_000, 1), Self.clock(2_000, 2),
                                Self.clock(2_500, 3), Self.clock(3_000, 4)])
    }

    // MARK: - Song Position representability

    @Test
    func aContinueBetweenSongPositionUnitsIsRefusedWithTheDistanceAboveTheFloorPointer() throws {
        let cases: [(Int64, Int64)] = [(1, 1), (5_000, 1_160), (3_839, 3_839), (7_679, 3_839)]
        for (ticks, remainder) in cases {
            let running = try Self.continued(fromTicks: ticks, atFrame: 0)
            let map = try Self.map(for: running, anchorTicks: ticks)
            #expect(throws: MIDIInternalClockError.positionNotRepresentable(remainderTicks: remainder)) {
                try Self.plan(running, map, Self.window(0, 1_000))
            }
        }
        let whole = try Self.continued(fromTicks: 7_680, atFrame: 0)
        let wholeMap = try Self.map(for: whole, anchorTicks: 7_680)
        let accepted = try Self.plan(whole, wholeMap, Self.window(0, 1))
        #expect(accepted.events == [Self.event(0, .songPosition(2)), Self.event(0, .continue), Self.clock(0, 12)])
    }

    @Test
    func aContinueBetweenSongPositionUnitsIsRefusedForEveryWindowOfTheRun() throws {
        let running = try Self.continued(fromTicks: 5_000, atFrame: 12_000)
        let map = try Self.map(for: running, anchorFrame: 12_000, anchorTicks: 5_000)
        let refusal = MIDIInternalClockError.positionNotRepresentable(remainderTicks: 1_160)
        for start in [Int64(0), 11_000, 12_000, 50_000] {
            #expect(throws: refusal) { try Self.plan(running, map, Self.window(start, 1_000)) }
        }
    }

    @Test
    func aPendingStopOnAnUnalignedContinueIsDeliveredByTheWindowsAfterTheRunsFirstFrame() throws {
        // Position 1,600 is not a whole Song Position unit (3,840 ticks), so a running Continue refuses every window.
        // Once a Stop is pending only the windows that begin at or before the run's first frame refuse: they would
        // emit the Continue. Later windows plan the clocks and the Stop, so the caller can settle.
        let refusal = MIDIInternalClockError.positionNotRepresentable(remainderTicks: 1_600)
        let running = try Self.continued(fromTicks: 1_600, atFrame: 0)
        let runningMap = try Self.map(for: running, anchorTicks: 1_600)
        for start in [Int64(0), 1, 2_000] {
            #expect(throws: refusal) { try Self.plan(running, runningMap, Self.window(start, 2_000)) }
        }
        let pending = try running.stopping(atFrame: 100, in: runningMap)
        let run = Self.run(from: 1_600, at: 0, .continue)
        #expect(pending.state == .stopping(run, stopFrame: 100))
        let map = try Self.map(for: pending, anchorTicks: 1_600)
        #expect(throws: refusal) { try Self.plan(pending, map, Self.window(0, 2_000)) }
        let onTime = try Self.plan(pending, map, Self.window(1, 2_000))
        #expect(onTime.events == [Self.event(100, .stop)])
        let late = try Self.plan(pending, map, Self.window(2_000, 2_000))
        #expect(late.events == [Self.event(2_000, .stop)])
        for holding in [onTime, late] {
            // The position is that of the requested frame 100, also when the Stop is planned at a later frame.
            #expect(holding.restingTicks == 1_664)
            let settled = pending.settled(after: holding)
            #expect(settled.state == .stopped(atTicks: 1_664))
            #expect(settled.generation == pending.generation)
        }
        let laterStop = try running.stopping(atFrame: 2_500, in: runningMap)
        let laterMap = try Self.map(for: laterStop, anchorTicks: 1_600)
        let withClocks = try Self.plan(laterStop, laterMap, Self.window(1_000, 2_000))
        #expect(withClocks.events == [Self.clock(1_500, 4), Self.event(2_500, .stop)])
        #expect(laterStop.settled(after: withClocks).state == .stopped(atTicks: 3_200))
    }

    // MARK: - Stop

    @Test
    func aPendingStopSuppressesItsOwnPulseAndEveryLaterOne() throws {
        let onPulse = try Self.stopPending(atFrame: 2_000)
        let planOnPulse = try Self.plan(onPulse, Self.map(for: onPulse), Self.window(0, 4_096))
        #expect(planOnPulse.events == [Self.event(0, .start), Self.clock(0, 0), Self.clock(1_000, 1),
                                       Self.event(2_000, .stop)])
        let betweenPulses = try Self.stopPending(atFrame: 2_500)
        let planBetween = try Self.plan(betweenPulses, Self.map(for: betweenPulses), Self.window(0, 4_096))
        #expect(planBetween.events == [Self.event(0, .start), Self.clock(0, 0), Self.clock(1_000, 1),
                                       Self.clock(2_000, 2), Self.event(2_500, .stop)])
    }

    @Test
    func theStopIsPlannedByTheWindowThatContainsItsFrame() throws {
        let pending = try Self.stopPending(atFrame: 2_500)
        let map = try Self.map(for: pending)
        let before = try Self.plan(pending, map, Self.window(0, 2_500))
        #expect(before.events == [Self.event(0, .start), Self.clock(0, 0), Self.clock(1_000, 1), Self.clock(2_000, 2)])
        let lastFrame = try Self.plan(pending, map, Self.window(0, 2_501))
        #expect(lastFrame.events.last == Self.event(2_500, .stop))
        #expect(lastFrame.events.count == 5)
        let firstFrame = try Self.plan(pending, map, Self.window(2_500, 2_500))
        #expect(firstFrame.events == [Self.event(2_500, .stop)])
    }

    @Test
    func aStopBehindTheWindowIsPlannedAtItsFirstFrameAndTheTransportSettlesOnThatPlan() throws {
        let pending = try Self.stopPending(atFrame: 1_500)
        let map = try Self.map(for: pending)
        let late = try Self.plan(pending, map, Self.window(2_000, 2_000))
        #expect(late.events == [Self.event(2_000, .stop)])
        let settled = pending.settled(after: late)
        #expect(settled.state == .stopped(atTicks: 960))
        #expect(settled.generation == pending.generation)
        // The resting position is that of the requested frame 1,500 (tick 960), not of the planned frame 2,000.
        #expect(late.restingTicks == 960)
        let run = Self.run(from: 0, at: 0, .start)
        #expect(pending.state == .stopping(run, stopFrame: 1_500))
    }

    @Test
    func aStopBehindTheWindowEmitsNoClockEvenWhenTheWindowHoldsPulses() throws {
        let running = try Self.started()
        let runningPlan = try Self.plan(running, Self.map(for: running), Self.window(2_000, 2_000))
        #expect(runningPlan.events == [Self.clock(2_000, 2), Self.clock(3_000, 3)])
        let pending = try Self.stopPending(atFrame: 1_500)
        let map = try Self.map(for: pending)
        let atWindowStart = try Self.plan(pending, map, Self.window(2_000, 2_000))
        #expect(atWindowStart.events == [Self.event(2_000, .stop)])
        let laterWindow = try Self.plan(pending, map, Self.window(2_500, 2_000))
        #expect(laterWindow.events == [Self.event(2_500, .stop)])
    }

    @Test
    func aStopIsPlannedAtTheLaterOfItsFrameAndTheWindowsFirstFrame() throws {
        let window = try Self.window(2_000, 2_000)
        let oneBehind = try Self.stopPending(atFrame: 1_999)
        let oneBehindPlan = try Self.plan(oneBehind, Self.map(for: oneBehind), window)
        #expect(oneBehindPlan.events == [Self.event(2_000, .stop)])
        let atStart = try Self.stopPending(atFrame: 2_000)
        let atStartPlan = try Self.plan(atStart, Self.map(for: atStart), window)
        #expect(atStartPlan.events == [Self.event(2_000, .stop)])
        let oneInside = try Self.stopPending(atFrame: 2_001)
        let oneInsidePlan = try Self.plan(oneInside, Self.map(for: oneInside), window)
        #expect(oneInsidePlan.events == [Self.clock(2_000, 2), Self.event(2_001, .stop)])
    }

    @Test
    func aWindowAfterTheStopPlansItAgainWhileTheTransportIsPendingAndNothingOnceSettled() throws {
        let pending = try Self.stopPending(atFrame: 2_500)
        let map = try Self.map(for: pending)
        let first = try Self.plan(pending, map, Self.window(2_000, 1_000))
        #expect(first.events == [Self.clock(2_000, 2), Self.event(2_500, .stop)])
        // The caller settles after the first plan that holds the Stop; until it does, every later window plans it.
        let again = try Self.plan(pending, map, Self.window(2_501, 4_000))
        #expect(again.events == [Self.event(2_501, .stop)])
        let settled = pending.settled(after: first)
        let none = try Self.plan(settled, Self.map(for: settled), Self.window(2_501, 4_000))
        #expect(none.events.isEmpty)
        #expect(none.transportGeneration == settled.generation)
    }

    @Test
    func aStoppedTransportPlansNothing() throws {
        let stopped = MIDIInternalTransport.initial
        let plan = try Self.plan(stopped, Self.map(for: stopped), Self.window(0, 4_096))
        #expect(plan.events.isEmpty)
        #expect(plan.transportGeneration == .initial)
        let pending = try Self.stopPending(atFrame: 2_500)
        let holding = try Self.plan(pending, Self.map(for: pending), Self.window(0, 2_501))
        let settled = pending.settled(after: holding)
        let afterStop = try Self.plan(settled, Self.map(for: settled), Self.window(0, 4_096))
        #expect(afterStop.events.isEmpty)
    }

    // MARK: - The resting position travels with the plan

    @Test
    func aTempoEditWhileAStopIsPendingMovesWhereTheTransportRestsToTheAcceptedPlansMap() throws {
        let running = try Self.started()
        let pending = try running.stopping(atFrame: 12_000, in: Self.map(for: running))
        // The accepted map doubles the tempo from tick 3,840 on: frame 12,000 is then tick 11,520, not 7,680.
        let edited = try Self.map(for: pending, tempos: [(0, 500_000), (3_840, 250_000)])
        let holding = try Self.plan(pending, edited, Self.window(11_000, 1_001))
        #expect(holding.events == [Self.clock(11_000, 16), Self.clock(11_500, 17), Self.event(12_000, .stop)])
        #expect(holding.restingTicks == 11_520)
        let settled = pending.settled(after: holding)
        #expect(settled.state == .stopped(atTicks: 11_520))
        #expect(settled.generation == pending.generation)
        let continued = try settled.continuing(atFrame: 20_000)
        let continuedMap = try Self.map(for: continued, anchorFrame: 20_000, anchorTicks: 11_520)
        let resumed = try Self.plan(continued, continuedMap, Self.window(20_000, 1))
        #expect(resumed.events == [Self.event(20_000, .songPosition(3)), Self.event(20_000, .continue),
                                   Self.clock(20_000, 18)])
        // Control: planned with the unedited map, the same pending Stop rests where it was requested.
        let control = try Self.plan(pending, Self.map(for: pending), Self.window(12_000, 1))
        #expect(control.restingTicks == 7_680)
        #expect(pending.settled(after: control).state == .stopped(atTicks: 7_680))
    }

    @Test
    func aPlanThatHoldsTheStopRefusesAMapThatCannotPlaceTheRequestedFrameButEarlierWindowsStillPlan() throws {
        let running = try Self.started()
        let nearby = try Self.map(for: running, rate: 192_000, tempos: [(0, 60_000)], anchorFrame: Int64.max - 1_000)
        let pending = try running.stopping(atFrame: Int64.max - 1, in: nearby)
        // The accepted map is anchored at frame 0, where the requested frame is beyond the tick range.
        let farMap = try Self.map(for: pending, rate: 192_000, tempos: [(0, 60_000)])
        let earlier = try Self.plan(pending, farMap, Self.window(0, 1_000))
        #expect(earlier.events == [Self.event(0, .start), Self.clock(0, 0), Self.clock(480, 1), Self.clock(960, 2)])
        #expect(earlier.restingTicks == nil)
        #expect(throws: MIDIInternalClockError.clockMap(.overflow)) {
            try Self.plan(pending, farMap, Self.window(Int64.max - 1, 1))
        }
    }

    @Test
    func aPlanThatHoldsTheStopRefusesAMapThatPlacesTheRequestedFrameBelowZero() throws {
        let running = try Self.started()
        let pending = try running.stopping(atFrame: 2_500, in: Self.map(for: running))
        // Anchored at frame 100,000, tick 0: frame 2,500 lies 97,500 frames before it, at tick -62,400.
        let shifted = try Self.map(for: pending, anchorFrame: 100_000)
        #expect(throws: MIDIInternalClockError.positionOutOfRange(ticks: -62_400)) {
            try Self.plan(pending, shifted, Self.window(3_000, 1_000))
        }
        let earlier = try Self.plan(pending, shifted, Self.window(1_000, 1_000))
        #expect(earlier.events.isEmpty)
        #expect(earlier.restingTicks == nil)
    }

    // MARK: - Windows around the Start

    @Test
    func theStartIsPlannedOnlyByTheWindowThatContainsItsFrame() throws {
        let running = try Self.started(atFrame: 1_000)
        let map = try Self.map(for: running, anchorFrame: 1_000)
        let atStart = try Self.plan(running, map, Self.window(1_000, 1_000))
        #expect(atStart.events == [Self.event(1_000, .start), Self.clock(1_000, 0)])
        let before = try Self.plan(running, map, Self.window(0, 1_000))
        #expect(before.events.isEmpty)
        let after = try Self.plan(running, map, Self.window(1_001, 1_000))
        #expect(after.events == [Self.clock(2_000, 1)])
    }

    @Test
    func aRunBeginningBeforeTheFirstPlannedWindowHoldsClocksOnlyWithoutStartContinueOrSongPosition() throws {
        // The frame of a Start or Continue must not precede the first window planned for the run: the caller owns
        // that, because the transport does not know what was planned and a late Start cannot be clamped.
        let startedRun = try Self.started(atFrame: 1_000)
        let startedMap = try Self.map(for: startedRun, anchorFrame: 1_000)
        let afterStart = try Self.plan(startedRun, startedMap, Self.window(2_000, 2_000))
        #expect(afterStart.events == [Self.clock(2_000, 1), Self.clock(3_000, 2)])
        let continuedRun = try Self.continued(fromTicks: 3_840, atFrame: 6_000)
        let continuedMap = try Self.map(for: continuedRun, anchorFrame: 6_000, anchorTicks: 3_840)
        let afterContinue = try Self.plan(continuedRun, continuedMap, Self.window(8_000, 2_000))
        #expect(afterContinue.events == [Self.clock(8_000, 8), Self.clock(9_000, 9)])
    }

    @Test
    func adjacentWindowsPlanExactlyTheEventsOfTheWholeSpan() throws {
        let running = try Self.started()
        let map = try Self.map(for: running)
        var pieces: [MIDIInternalClockEvent] = []
        for start in stride(from: Int64(0), to: 4_500, by: 1_500) {
            pieces += try Self.plan(running, map, Self.window(start, 1_500)).events
        }
        let whole = try Self.plan(running, map, Self.window(0, 4_500))
        #expect(pieces == whole.events)
        #expect(whole.events == [Self.event(0, .start), Self.clock(0, 0), Self.clock(1_000, 1), Self.clock(2_000, 2),
                                 Self.clock(3_000, 3), Self.clock(4_000, 4)])
    }

    @Test
    func theSameInputsAlwaysYieldTheSamePlan() throws {
        let pending = try Self.stopPending(atFrame: 2_500)
        let map = try Self.map(for: pending)
        let window = try Self.window(0, 4_096)
        let first = try Self.plan(pending, map, window)
        let second = try Self.plan(pending, map, window)
        #expect(first == second)
        #expect(first.events.count == 5)
    }

    // MARK: - Refusals

    @Test
    func onlyTheInternalLeaderMayEmitAndTheLeaderCheckComesFirst() throws {
        let running = try Self.started()
        let map = try Self.map(for: running)
        let window = try Self.window(0, 2_500)
        let external = MIDIClockLeader.external(MIDIInputID(7))
        #expect(throws: MIDIInternalClockError.notLeader(external)) {
            try MIDIInternalClockPlan.make(transport: running, leader: external, map: map, window: window)
        }
        let staleMap = try Self.map(for: .initial)
        let staleWindow = try Self.window(0, 2_500, sampleGeneration: Generation(2))
        #expect(throws: MIDIInternalClockError.notLeader(external)) {
            try MIDIInternalClockPlan.make(transport: running, leader: external, map: staleMap, window: staleWindow)
        }
    }

    @Test
    func aRefusedPlanLeavesItsInputsAsTheyWereAndTheNextPlanIsExact() throws {
        let running = try Self.started()
        let map = try Self.map(for: running)
        let window = try Self.window(0, 2_500)
        let external = MIDIClockLeader.external(MIDIInputID(3))
        #expect(throws: MIDIInternalClockError.notLeader(external)) {
            try MIDIInternalClockPlan.make(transport: running, leader: external, map: map, window: window)
        }
        let sameTransport = try Self.started()
        let sameMap = try Self.map(for: sameTransport)
        let sameWindow = try Self.window(0, 2_500)
        #expect(running == sameTransport)
        #expect(map == sameMap)
        #expect(window == sameWindow)
        let plan = try Self.plan(running, map, window)
        #expect(plan.events == [Self.event(0, .start), Self.clock(0, 0), Self.clock(1_000, 1), Self.clock(2_000, 2)])
    }

    @Test
    func aMapOfAnotherTransportOrSampleGenerationIsRefused() throws {
        let running = try Self.started()
        let window = try Self.window(0, 2_500)
        let goodMap = try Self.map(for: running)
        let oldMap = try Self.map(for: .initial)
        let newMap = try Self.map(for: running.stopping(atFrame: 2_500, in: goodMap))
        #expect(throws: MIDIInternalClockError.staleTransport) { try Self.plan(running, oldMap, window) }
        #expect(throws: MIDIInternalClockError.staleTransport) { try Self.plan(running, newMap, window) }
        let secondWindow = try Self.window(0, 2_500, sampleGeneration: Generation(2))
        #expect(throws: MIDIInternalClockError.staleSampleGeneration) { try Self.plan(running, goodMap, secondWindow) }
        #expect(throws: MIDIInternalClockError.staleSampleGeneration) { try Self.plan(running, oldMap, secondWindow) }
    }

    @Test
    func theMapMustPlaceTheRunsFirstTickOnTheFrameTheRunBeganAt() throws {
        let running = try Self.started(atFrame: 1_000)
        let anchored = try Self.map(for: running, anchorFrame: 1_000)
        let accepted = try Self.plan(running, anchored, Self.window(0, 3_000))
        #expect(accepted.events == [Self.event(1_000, .start), Self.clock(1_000, 0), Self.clock(2_000, 1)])
        for mapFrame in [Int64(999), 1_001, 0] {
            let shifted = try Self.map(for: running, anchorFrame: mapFrame)
            let refusal = MIDIInternalClockError.runNotAnchored(transportFrame: 1_000, mapFrame: mapFrame)
            #expect(throws: refusal) { try Self.plan(running, shifted, Self.window(0, 3_000)) }
        }
    }

    @Test
    func laterWindowsTrustTheMapBecauseATempoChangeReanchorsIt() throws {
        let running = try Self.started(atFrame: 1_000)
        let reanchored = try Self.map(for: running)
        let plan = try Self.plan(running, reanchored, Self.window(1_001, 1_000))
        #expect(plan.events == [Self.clock(2_000, 2)])
    }

    @Test
    func aPulseFrameBeyondTheFrameRangeIsRefusedAsAClockError() throws {
        let anchorFrame = Int64.max - 100
        let running = try Self.started(atFrame: anchorFrame)
        let map = try Self.map(for: running, anchorFrame: anchorFrame)
        let window = try Self.window(anchorFrame, 100)
        #expect(throws: MIDIInternalClockError.clock(.clockMap(.overflow))) { try Self.plan(running, map, window) }
    }

    @Test
    func aFirstTickBeyondTheFrameRangeIsRefusedAsAClockMapError() throws {
        let frame = Int64.max - 10
        let running = try Self.continued(fromTicks: MIDIClockMath.maximumSongPositionTicks, atFrame: frame)
        let map = try Self.map(for: running, anchorFrame: frame)
        let window = try Self.window(Int64.max - 100, 100)
        #expect(throws: MIDIInternalClockError.clockMap(.overflow)) { try Self.plan(running, map, window) }
    }
}
