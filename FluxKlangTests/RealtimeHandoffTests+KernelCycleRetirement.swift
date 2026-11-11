import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private func noteOn(_ note: UInt8) -> KernelEventPayload { .noteOn(channel: 0, note: note, velocity: 100) }
private func noteOff(_ note: UInt8) -> KernelEventPayload { .noteOff(channel: 0, note: note) }
private let programFive = KernelEventPayload.program(channel: 0, program: 5, bank: 0)

/// A `.replacingCycle` cycle on `rig`'s parts (sharing its fan-in's refusal table); the caller retires first.
private func successor(of rig: CycleRig) throws -> KernelCycle {
    let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership, safety: rig.safety,
                                 ramps: rig.ramps, admissionRefusals: rig.cycle.admissionRefusals)
    return try KernelCycle(parts, pulses: ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48),
                           blockCapacity: 64, perLaneQuota: 64)
}

/// Runs one 64-frame block of `cycle` and returns its result with the payloads it emitted.
private func runBlock(_ cycle: KernelCycle, _ blockStart: Int64) -> (KernelCycleResult, [KernelEventPayload]) {
    var emitted: [KernelEventPayload] = []
    let result = cycle.run(blockStart: blockStart, frames: 64) { event, _ in emitted.append(event.payload) }
    return (result, emitted)
}

/// The loss's per-kind counts: `noteOns`, `controls`, `programs`, `ramps`, `clockPulses`.
private func counts(_ loss: KernelRetirementLoss) -> [Int] {
    [loss.noteOns, loss.controls, loss.programs, loss.ramps, loss.clockPulses]
}

private let controlNine = KernelEventPayload.control(channel: 0, controller: 7, value: 9)

private func oneEventCarry(_ frame: Int64, _ payload: KernelEventPayload) -> KernelRetirementCarry {
    var carry = KernelRetirementCarry()
    carry.record(cycleEvent(frame, payload))
    return carry
}

/// Runs one 64-frame block of `cycle` and returns its result with every emission and its dispatch frame.
private func emissions(_ cycle: KernelCycle, _ blockStart: Int64) -> (KernelCycleResult, [CycleEmission]) {
    var emitted: [CycleEmission] = []
    let result = cycle.run(blockStart: blockStart, frames: 64) { emitted.append(CycleEmission(event: $0, frame: $1)) }
    return (result, emitted)
}

extension RealtimeHandoffTests {
    /// Round 2i (Copilot round 5, thread PRRT_kwDOS3CuTM60X042): `retire()` drops every pending event but a
    /// `noteOff` (which records its tombstone) and counts it by kind in a `KernelRetirementLoss`, which the
    /// replacement's preparation inherits through the ownership's claim word, so control can reconcile receiver
    /// state. Pending stateful events are carried and re-admitted by the replacement (#364 KCR1); see
    /// `CycleRetirementCarryHandoff` and `CycleCarryReadmission`.
    struct CycleRetirementLoss {
        /// Copilot's case: a `program` change at 128, drained during [0, 64), is pending when the cycle retires.
        /// The retiring cycle reports one stateful (program) drop and stale receiver state; a `.replacingCycle`
        /// replacement over the same ownership inherits the same loss and (KCR1) re-admits the program at 128, after
        /// which its unresolved loss is empty. Kills: stateful drops not counted; the stale flag never set; the loss
        /// not handed to the replacement.
        @Test func pendingProgramChangeDroppedAtRetirementIsCountedAndInherited() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(128, programFive), token) == .ok)
            let (before, early) = rig.run(0, 64)
            #expect(early.isEmpty && before.pending == 1)
            let loss = rig.cycle.retire()
            #expect(counts(loss) == [0, 0, 1, 0, 0] && loss.stateful == 1 && loss.receiverStateMayBeStale)
            let replacement = try successor(of: rig)
            #expect(replacement.inheritedRetirementLoss == loss && replacement.unresolvedRetirementLoss == loss)
            #expect(runBlock(replacement, 64).1.isEmpty)
            let (result, emitted) = emissions(replacement, 128)
            #expect(emitted == [CycleEmission(event: cycleEvent(128, programFive), frame: 128)] && result.pending == 0)
            #expect(replacement.inheritedRetirementLoss == loss)
            #expect(!replacement.unresolvedRetirementLoss.receiverStateMayBeStale)
        }

        /// A `control` change at 100 and a `rampTo` at 110 pending at retirement are stateful drops too; the
        /// replacement inherits them and (KCR1) re-admits both in its first block. Kills: stateful drops not counted.
        @Test func pendingControlAndRampDroppedAtRetirementAreStateful() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(100, .control(channel: 0, controller: 7, value: 9)), token) == .ok)
            #expect(rig.push(cycleEvent(110, .rampTo(parameter: 1, value: 1, durationFrames: 0)), token) == .ok)
            #expect(rig.run(0, 64).0.pending == 2)
            let loss = rig.cycle.retire()
            #expect(counts(loss) == [0, 1, 0, 1, 0] && loss.stateful == 2 && loss.receiverStateMayBeStale)
            let replacement = try successor(of: rig)
            #expect(replacement.inheritedRetirementLoss == loss)
            let rampOne = KernelEventPayload.rampTo(parameter: 1, value: 1, durationFrames: 0)
            #expect(runBlock(replacement, 64).1 == [.control(channel: 0, controller: 7, value: 9), rampOne])
            #expect(replacement.parameterValue(1) == 1)
            #expect(replacement.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// A mix pending at retirement: `noteOn(61)` at 100, `noteOff(60)` 110, `noteOn(62)` 115, `control` 120,
        /// `program` 125, `rampTo` 130, a clock pulse 140 and `noteOff(61)` 150. The counts are exact per kind; the
        /// two `noteOff`s are not drops but still record their tombstones, so a `noteOn(60)` at 105 arriving later at
        /// the replacement is superseded. Kills: a `noteOff` counted as a drop; `retire()` recording no tombstone.
        @Test func mixedPendingEventsGiveExactCountsAndNoteOffsStillRecordTombstones() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let first = try #require(rig.events.claimProducer()), second = try #require(rig.events.claimProducer())
            let pending: [(Int64, KernelEventPayload)] = [
                (100, noteOn(61)), (110, noteOff(60)), (115, noteOn(62)),
                (120, .control(channel: 0, controller: 1, value: 3)), (125, programFive),
                (130, .rampTo(parameter: 2, value: 1, durationFrames: 64)), (140, .clockPulse), (150, noteOff(61))
            ]
            for (frame, payload) in pending { #expect(rig.push(cycleEvent(frame, payload), second) == .ok) }
            #expect(rig.run(0, 64).0.pending == 8)
            let loss = rig.cycle.retire()
            #expect(counts(loss) == [2, 1, 1, 1, 1] && loss.stateful == 3 && loss.receiverStateMayBeStale)
            let replacement = try successor(of: rig)
            #expect(replacement.inheritedRetirementLoss == loss)
            #expect(runBlock(replacement, 64).1 == [.control(channel: 0, controller: 1, value: 3), programFive])
            #expect(rig.push(cycleEvent(105, noteOn(60)), first) == .ok)
            let (late, emitted) = runBlock(replacement, 128)
            #expect(emitted == [.rampTo(parameter: 2, value: 1, durationFrames: 64)] && late.discardedSuperseded == 1)
            for note in UInt8(60)...62 { #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: note)) }
        }

        /// A retirement with nothing pending loses nothing: its loss is zero, the receiver state is not stale, and
        /// the next replacement inherits zero, not the earlier retirement's `program` drop (which the middle cycle
        /// re-admitted at 128). Kills: a zero loss not handed over (an earlier loss inherited again).
        @Test func retirementWithNothingPendingHandsOverAZeroLoss() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(128, programFive), token) == .ok)
            #expect(rig.run(0, 64).0.pending == 1)
            rig.cycle.retire()
            let middle = try successor(of: rig)
            #expect(middle.inheritedRetirementLoss.programs == 1)
            #expect(runBlock(middle, 64).0.pending == 0 && runBlock(middle, 128).1 == [programFive])
            let loss = middle.retire()
            #expect(loss == KernelRetirementLoss() && counts(loss) == [0, 0, 0, 0, 0] && !loss.receiverStateMayBeStale)
            let last = try successor(of: rig)
            #expect(last.inheritedRetirementLoss == KernelRetirementLoss())
            #expect(!last.inheritedRetirementLoss.receiverStateMayBeStale)
        }

        /// A pending `noteOn` and clock pulse: the first `retire()` counts them (neither is stateful, so the receiver
        /// state is not stale); a second does nothing and returns no loss, and the replacement inherits the first
        /// loss, not a double count. Kills: a repeated `retire()` counting again.
        @Test func secondRetireCountsNothingAgain() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(100, noteOn(64)), token) == .ok)
            #expect(rig.push(cycleEvent(120, .clockPulse), token) == .ok)
            #expect(rig.run(0, 64).0.pending == 2)
            let loss = rig.cycle.retire()
            #expect(counts(loss) == [1, 0, 0, 0, 1] && loss.stateful == 0 && !loss.receiverStateMayBeStale)
            #expect(rig.cycle.retire() == KernelRetirementLoss())
            let replacement = try successor(of: rig)
            #expect(replacement.inheritedRetirementLoss == loss)
            #expect(runBlock(replacement, 64).1.isEmpty && runBlock(replacement, 128).1.isEmpty)
        }

        /// Round 2j: a silenced cycle, latched (`.scopeFaulted`) or muted by a panic (`.safetyMute`), consumes its
        /// due note events undecided (the `noteOn` discarded, the unowned `noteOff` consumed) but keeps `control`,
        /// `program`, `rampTo` and clock events buffered; retired, it drops and counts exactly those, with stale
        /// receiver state, and the replacement inherits them. Kills: stateful drops not counted; the stale flag
        /// never set; the loss not handed to the replacement.
        @Test func silencedCycleRetiringDropsTheStateEventsItKept() throws {
            let due: [KernelEventPayload] = [noteOn(61), .control(channel: 0, controller: 7, value: 9), programFive,
                                             .rampTo(parameter: 1, value: 1, durationFrames: 0), .clockPulse,
                                             noteOff(60)]
            for faulted in [true, false] {
                let rig = try CycleRig(laneCapacity: 32)
                let token = try #require(rig.events.claimProducer())
                for (index, payload) in due.enumerated() {
                    #expect(rig.push(cycleEvent(Int64(10 * index + 5), payload), token) == .ok)
                }
                if faulted {
                    #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
                } else {
                    #expect(rig.safety.request(.panic, scope: 0) == .ok)
                }
                let (silenced, emitted) = rig.run(0, 64)
                #expect(silenced.status == (faulted ? .silenced(.scopeFaulted) : .silenced(.safetyMute)))
                #expect(emitted.isEmpty && silenced.pending == 4 && silenced.discardedWhileSilenced == 2)
                let loss = rig.cycle.retire()
                #expect(counts(loss) == [0, 1, 1, 1, 1] && loss.stateful == 3 && loss.receiverStateMayBeStale)
                #expect(try successor(of: rig).inheritedRetirementLoss == loss)
                #expect(rig.cycle.parameterValue(1) == 0)
            }
        }

        /// Round 2j: a replacement starts with every lane flushing, so `noteOn`s it drains before their lane is
        /// proved empty are marked flushed: the one decided is discarded, never sounded; the one still pending at
        /// retirement is counted under `noteOns`, not stateful.
        @Test func flushedNoteOnPendingAtRetirementCountsAsANoteOn() throws {
            let rig = try CycleRig()
            rig.cycle.retire()
            let replacement = try successor(of: rig)
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(100, noteOn(70)), token) == .ok)
            #expect(rig.push(cycleEvent(140, noteOn(71)), token) == .ok)
            #expect(runBlock(replacement, 0).0.pending == 2)
            let (decided, emitted) = runBlock(replacement, 64)
            #expect(emitted.isEmpty && decided.discardedWhileSilenced == 1 && decided.pending == 1)
            let loss = replacement.retire()
            #expect(counts(loss) == [1, 0, 0, 0, 0] && !loss.receiverStateMayBeStale)
            #expect(try successor(of: rig).inheritedRetirementLoss == loss)
        }

        /// Round 2l (Copilot, thread PRRT_kwDOS3CuTM60f7vt): the last known parameter values live in the shared
        /// `RampSlots`, so a `.replacingCycle` replacement keeps what its predecessor completed. Parameter 1 jumps to
        /// 1, parameter 2 ramps to 1 within the block and parameter 3 is halfway to 1; the cycle retires with an empty
        /// buffer (no loss, nothing to reconcile). The replacement reports 1, 1 and 0.5 before any run, its new ramp
        /// on parameter 1 (to 0 over 128 frames) starts from 1, not 0, and parameter 3 completes. A `.freshFanIn`
        /// cycle on new slots still starts at 0. Kills: the replacement resetting the shared values; values written
        /// only to a per-cycle cache; a completed ramp's target not kept.
        @Test func completedRampValueSurvivesReplacementAndSeedsTheNextRamp() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            for (frame, parameter, duration) in [(Int64(0), UInt32(3), Int64(128)), (10, 1, 0), (20, 2, 20)] {
                let ramp = KernelEventPayload.rampTo(parameter: parameter, value: 1, durationFrames: duration)
                #expect(rig.push(cycleEvent(frame, ramp), token) == .ok)
            }
            let (first, _) = runBlock(rig.cycle, 0)
            #expect(first.dispatched == 3 && first.pending == 0 && rig.ramps.activeCount == 1)
            #expect([1, 2, 3].map { rig.cycle.parameterValue($0) } == [1, 1, 0.5])
            #expect(rig.cycle.retire() == KernelRetirementLoss())
            let replacement = try successor(of: rig)
            #expect([0, 1, 2, 3].map { replacement.parameterValue($0) } == [0, 1, 1, 0.5])
            #expect(rig.push(cycleEvent(64, .rampTo(parameter: 1, value: 0, durationFrames: 128)), token) == .ok)
            let (next, _) = runBlock(replacement, 64)
            #expect(next.dispatched == 1 && next.refused == 0)
            #expect([1, 2, 3].map { replacement.parameterValue($0) } == [0.5, 1, 1])
            #expect(runBlock(replacement, 128).0.status == .ok && replacement.parameterValue(1) == 0)
            #expect(try CycleRig().cycle.parameterValue(1) == 0)
        }

        /// A `.freshFanIn` cycle takes nothing over, so it inherits no loss.
        @Test func freshFanInCycleInheritsNoLoss() throws {
            let rig = try CycleRig()
            #expect(rig.cycle.inheritedRetirementLoss == KernelRetirementLoss())
            #expect(counts(rig.cycle.inheritedRetirementLoss) == [0, 0, 0, 0, 0])
            #expect(!rig.cycle.inheritedRetirementLoss.receiverStateMayBeStale)
        }
    }

    /// #364 E5c, slice KCW1: `retire()` records the stateful events still pending in the retired block buffer into a
    /// `KernelRetirementCarry` that the next claim inherits with the loss (`inheritedRetirementCarry`); since KCR1
    /// the replacement re-admits it itself (see `CycleCarryReadmission`).
    struct CycleRetirementCarryHandoff {
        /// The #364 example: a `program` at 128 drained during [0, 64) and pending at retirement is inherited and
        /// re-admitted by the replacement at frame 128; the inherited loss is unchanged. Kills: no event recorded;
        /// the carry not handed over; the loss changed.
        @Test func retirementCarryHandoffProgramPendingAtRetirementIsEmittedByTheReplacementAtItsFrame() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(128, programFive), token) == .ok)
            let (before, early) = rig.run(0, 64)
            #expect(early.isEmpty && before.pending == 1)
            let loss = rig.cycle.retire()
            #expect(counts(loss) == [0, 0, 1, 0, 0] && loss.receiverStateMayBeStale)
            let replacement = try successor(of: rig)
            let carry = replacement.inheritedRetirementCarry
            #expect(carry.count == 1 && carry.droppedForCapacity == 0)
            #expect(carry.event(at: 0) == cycleEvent(128, programFive))
            #expect(runBlock(replacement, 64).1.isEmpty)
            let (result, emitted) = emissions(replacement, 128)
            #expect(emitted == [CycleEmission(event: cycleEvent(128, programFive), frame: 128)])
            #expect(result.pending == 0 && replacement.inheritedRetirementLoss == loss)
        }

        /// An event already due when the replacement starts (a `control` stamped 100, replacement first frame 192
        /// after a one-block gap) is dispatched at 192, not at 100. Kills: the event not carried.
        @Test func retirementCarryHandoffAlreadyDueEventIsEmittedAtTheReplacementsFirstFrame() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(100, controlNine), token) == .ok)
            #expect(rig.run(0, 64).0.pending == 1)
            _ = rig.cycle.retire()
            let replacement = try successor(of: rig)
            let (result, emitted) = emissions(replacement, 192)
            #expect(emitted == [CycleEmission(event: cycleEvent(100, controlNine), frame: 192)])
            #expect(result.pending == 0)
        }

        /// The mixed fixture of `mixedPendingEventsGiveExactCountsAndNoteOffsStillRecordTombstones`: the carry holds
        /// only the `control` (120), `program` (125) and `rampTo` (130), in buffer order; the loss counts and the
        /// `noteOff` tombstones are as before. Kills: a `noteOn`, `noteOff` or clock pulse recorded; the buffer
        /// visited in reverse; loss counting skipped for recorded events.
        @Test func retirementCarryHandoffMixedPendingKeepsOnlyStatefulEventsInBufferOrder() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let first = try #require(rig.events.claimProducer()), second = try #require(rig.events.claimProducer())
            let ramp = KernelEventPayload.rampTo(parameter: 2, value: 1, durationFrames: 64)
            let stateChange = KernelEventPayload.control(channel: 0, controller: 1, value: 3)
            let pending: [(Int64, KernelEventPayload)] = [
                (100, noteOn(61)), (110, noteOff(60)), (115, noteOn(62)), (125, programFive),
                (130, ramp), (140, .clockPulse), (145, noteOff(61)), (150, stateChange)
            ]
            for (frame, payload) in pending { #expect(rig.push(cycleEvent(frame, payload), second) == .ok) }
            #expect(rig.run(0, 64).0.pending == 8)
            let loss = rig.cycle.retire()
            #expect(counts(loss) == [2, 1, 1, 1, 1] && loss.stateful == 3)
            let replacement = try successor(of: rig)
            let carry = replacement.inheritedRetirementCarry
            let expected = [cycleEvent(125, programFive), cycleEvent(130, ramp), cycleEvent(150, stateChange)]
            #expect(carry.count == 3 && carry.events == expected)
            #expect(runBlock(replacement, 64).1 == [programFive])
            #expect(rig.push(cycleEvent(105, noteOn(60)), first) == .ok)
            let (late, emitted) = runBlock(replacement, 128)
            #expect(emitted == [ramp, stateChange] && late.discardedSuperseded == 1)
        }

        /// Retirement overwrites: A leaves a program, B inherits it, re-admits it and retires empty, so C inherits an
        /// empty carry and loss. A second `retire()` of A returns no loss and changes nothing B inherited. A
        /// `.freshFanIn` cycle inherits an empty carry. Kills: the carry not overwritten when empty; a repeated
        /// `retire()` recording.
        @Test func retirementCarryHandoffAnEmptyRetirementOverwritesAnEarlierCarry() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(128, programFive), token) == .ok)
            #expect(rig.run(0, 64).0.pending == 1)
            _ = rig.cycle.retire()
            let middle = try successor(of: rig)
            let inherited = middle.inheritedRetirementCarry
            #expect(inherited.count == 1)
            #expect(runBlock(middle, 64).0.pending == 0 && runBlock(middle, 128).1 == [programFive])
            #expect(rig.cycle.retire() == KernelRetirementLoss())
            #expect(middle.inheritedRetirementCarry == inherited)
            _ = middle.retire()
            let last = try successor(of: rig)
            #expect(last.inheritedRetirementCarry == KernelRetirementCarry())
            #expect(last.inheritedRetirementCarry.count == 0 && last.inheritedRetirementLoss == KernelRetirementLoss())
            #expect(try CycleRig().cycle.inheritedRetirementCarry == KernelRetirementCarry())
        }

        /// 300 `control`s pending against the carry capacity: the first `KernelRetirementCarry.capacity` are kept in
        /// order, the rest are counted in `droppedForCapacity` and nothing is overwritten; the loss still counts all
        /// 300. Kills: overwrite of the oldest; a drop not counted; recording stopping early.
        @Test func retirementCarryHandoffOverflowCountsDroppedForCapacityAndKeepsTheFirstEvents() throws {
            let rig = try CycleRig(laneCapacity: 320, blockCapacity: 300, perLaneQuota: 300)
            let token = try #require(rig.events.claimProducer())
            let total = KernelRetirementCarry.capacity + 44
            var expected = KernelRetirementCarry()
            for index in 0..<total {
                let event = cycleEvent(1_000 + Int64(index), .control(channel: 0, controller: 7, value: UInt32(index)))
                #expect(rig.push(event, token) == .ok)
                expected.record(event)
            }
            #expect(rig.run(0, 64).0.pending == total)
            let loss = rig.cycle.retire()
            #expect(loss.controls == total)
            let carry = try successor(of: rig).inheritedRetirementCarry
            #expect(carry.count == KernelRetirementCarry.capacity && carry.droppedForCapacity == 44)
            #expect(carry.event(at: 0)?.frame == 1_000)
            #expect(carry.event(at: KernelRetirementCarry.capacity - 1)?.frame == 1_255)
            #expect(carry == expected)
        }

        /// A pending `noteOn` and clock pulse are counted as before and never carried. Kills: the carry's
        /// stateful filter bypassed.
        @Test func retirementCarryHandoffNoteOnsAndTimingPulsesAreNeverCarried() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(100, noteOn(64)), token) == .ok)
            #expect(rig.push(cycleEvent(120, .clockPulse), token) == .ok)
            #expect(rig.run(0, 64).0.pending == 2)
            let loss = rig.cycle.retire()
            #expect(counts(loss) == [1, 0, 0, 0, 1])
            let carry = try successor(of: rig).inheritedRetirementCarry
            #expect(carry.count == 0 && carry.droppedForCapacity == 0)
        }

        /// A silenced cycle (latched, or muted by a panic) keeps its stateful events buffered and carries exactly
        /// those at retirement, as many as the loss counts. Kills: capture skipped on the silenced path.
        @Test func retirementCarryHandoffSilencedCycleCarriesTheStateEventsItKept() throws {
            let ramp = KernelEventPayload.rampTo(parameter: 1, value: 1, durationFrames: 0)
            let due: [KernelEventPayload] = [noteOn(61), controlNine, programFive, ramp, .clockPulse, noteOff(60)]
            for faulted in [true, false] {
                let rig = try CycleRig(laneCapacity: 32)
                let token = try #require(rig.events.claimProducer())
                for (index, payload) in due.enumerated() {
                    #expect(rig.push(cycleEvent(Int64(10 * index + 5), payload), token) == .ok)
                }
                if faulted {
                    #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
                } else {
                    #expect(rig.safety.request(.panic, scope: 0) == .ok)
                }
                #expect(rig.run(0, 64).0.pending == 4)
                let loss = rig.cycle.retire()
                let carry = try successor(of: rig).inheritedRetirementCarry
                let expected = [cycleEvent(15, controlNine), cycleEvent(25, programFive), cycleEvent(35, ramp)]
                #expect(carry.events == expected)
                #expect(carry.count == loss.stateful)
            }
        }

        /// The release writes the carry only while its claim is held: a stale release with another carry changes
        /// nothing and the next claim inherits the holder's carry. Each carry is a one-event temporary read through
        /// `event(at:)` so the test keeps few 12 KB values alive. Kills: the carry written before the held check.
        @Test func retirementCarryHandoffStaleReleaseNeverOverwritesTheCarry() throws {
            let direct = try NoteOwnership(scopes: 1)
            let none = KernelRetirementLoss()
            let held = try direct.claimForCycle(fresh: true, from: direct.cycleClaimState())
            direct.releaseCycleClaim(held, loss: none, carry: oneEventCarry(10, programFive))
            let holder = try direct.claimForCycle(fresh: false, from: direct.cycleClaimState())
            let seenByHolder = holder.inheritedCarry.event(at: 0)
            #expect(seenByHolder == cycleEvent(10, programFive))
            direct.releaseCycleClaim(held, loss: none, carry: oneEventCarry(20, controlNine))
            #expect(throws: NoteOwnership.CycleClaimRefusal.predecessorNotRetired) {
                try direct.claimForCycle(fresh: false, from: direct.cycleClaimState())
            }
            direct.releaseCycleClaim(holder, loss: none, carry: oneEventCarry(30, controlNine))
            direct.releaseCycleClaim(held, loss: none, carry: oneEventCarry(20, controlNine))
            let third = try direct.claimForCycle(fresh: false, from: direct.cycleClaimState())
            let seenByThird = third.inheritedCarry.event(at: 0)
            #expect(seenByThird == cycleEvent(30, controlNine))
            #expect(third.inheritedCarry.count == 1)
        }

        /// The two-argument release hands over an empty carry, replacing the one stored earlier. Kills: the
        /// two-argument release leaving or forwarding the old carry.
        @Test func retirementCarryHandoffTwoArgumentReleaseClearsTheCarry() throws {
            let direct = try NoteOwnership(scopes: 1)
            let none = KernelRetirementLoss()
            let held = try direct.claimForCycle(fresh: true, from: direct.cycleClaimState())
            direct.releaseCycleClaim(held, loss: none, carry: oneEventCarry(10, programFive))
            let holder = try direct.claimForCycle(fresh: false, from: direct.cycleClaimState())
            #expect(holder.inheritedCarry.count == 1)
            direct.releaseCycleClaim(holder, loss: none)
            let next = try direct.claimForCycle(fresh: false, from: direct.cycleClaimState())
            #expect(next.inheritedCarry.count == 0)
        }

        /// The body of `func retire(` in `KernelCycle.swift` records through `carry.record(` and mentions no array
        /// growth, `events` getter, planner or lock token. A source scan, not an allocation proof.
        @Test(.enabled(if: Self.sourcesAreReachable, "the kernel sources are not next to the tests"))
        func retirementCarryHandoffRetireSourceHasNoArrayOrLockToken() throws {
            let directory = try #require(Self.eventsDirectory())
            let text = try String(contentsOf: directory.appendingPathComponent("KernelCycle.swift"), encoding: .utf8)
            let body = try #require(KernelRetirementCarryTests.functionBody("func retire(", in: text))
            #expect(body.contains("carry.record("))
            #expect(KernelRetirementCarryTests.arrayMutations(in: body).isEmpty)
            let banned = [".events", "Mutex", ".lock", "lock()", "plan("]
            #expect(banned.filter { body.contains($0) }.isEmpty)
        }

        private static func eventsDirectory(from path: String = #filePath) -> URL? {
            let here = URL(fileURLWithPath: path).deletingLastPathComponent()
            let candidates = ["../Shared/Audio/Kernel/Events", "../../Sources/FluxKlang/Shared/Audio/Kernel/Events"]
            return candidates
                .map { here.appendingPathComponent($0).standardizedFileURL }
                .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("KernelCycle.swift").path) }
        }

        private static let sourcesAreReachable = eventsDirectory() != nil
    }
}
