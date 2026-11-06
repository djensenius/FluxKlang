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

extension RealtimeHandoffTests {
    /// Round 2i (Copilot round 5, thread PRRT_kwDOS3CuTM60X042): `retire()` drops every pending event but a
    /// `noteOff` (which records its tombstone) and counts it by kind in a `KernelRetirementLoss`, which the
    /// replacement's preparation inherits through the ownership's claim word, so control can reconcile receiver
    /// state. Nothing is carried over (bounded carry-over is E5c).
    struct CycleRetirementLoss {
        /// Copilot's case: a `program` change at 128, drained during [0, 64), is never emitted when the cycle retires.
        /// The retiring cycle reports one stateful (program) drop and stale receiver state; a `.replacingCycle`
        /// replacement over the same ownership inherits the same loss and emits nothing for it. Kills: stateful drops
        /// not counted; the stale flag never set; the loss not handed to the replacement.
        @Test func pendingProgramChangeDroppedAtRetirementIsCountedAndInherited() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(128, programFive), token) == .ok)
            let (before, early) = rig.run(0, 64)
            #expect(early.isEmpty && before.pending == 1)
            let loss = rig.cycle.retire()
            #expect(counts(loss) == [0, 0, 1, 0, 0] && loss.stateful == 1 && loss.receiverStateMayBeStale)
            let replacement = try successor(of: rig)
            #expect(replacement.inheritedRetirementLoss == loss)
            for blockStart in [Int64(64), 128] {
                let (result, emitted) = runBlock(replacement, blockStart)
                #expect(emitted.isEmpty && result.pending == 0)
            }
        }

        /// A `control` change at 100 and a `rampTo` at 110 pending at retirement are stateful drops too; the
        /// replacement inherits them and never emits or applies them. Kills: stateful drops not counted.
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
            #expect(runBlock(replacement, 64).1.isEmpty && runBlock(replacement, 128).1.isEmpty)
            #expect(replacement.parameterValue(1) == 0)
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
            #expect(replacement.inheritedRetirementLoss == loss && runBlock(replacement, 64).1.isEmpty)
            #expect(rig.push(cycleEvent(105, noteOn(60)), first) == .ok)
            let (late, emitted) = runBlock(replacement, 128)
            #expect(emitted.isEmpty && late.discardedSuperseded == 1)
            for note in UInt8(60)...62 { #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: note)) }
        }

        /// A retirement with nothing pending loses nothing: its loss is zero, the receiver state is not stale, and
        /// the next replacement inherits zero, not the earlier retirement's `program` drop. Kills: a zero loss not
        /// handed over (an earlier loss inherited again).
        @Test func retirementWithNothingPendingHandsOverAZeroLoss() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(128, programFive), token) == .ok)
            #expect(rig.run(0, 64).0.pending == 1)
            rig.cycle.retire()
            let middle = try successor(of: rig)
            #expect(middle.inheritedRetirementLoss.programs == 1)
            #expect(runBlock(middle, 64).0.pending == 0)
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
        }

        /// A `.freshFanIn` cycle takes nothing over, so it inherits no loss.
        @Test func freshFanInCycleInheritsNoLoss() throws {
            let rig = try CycleRig()
            #expect(rig.cycle.inheritedRetirementLoss == KernelRetirementLoss())
            #expect(counts(rig.cycle.inheritedRetirementLoss) == [0, 0, 0, 0, 0])
            #expect(!rig.cycle.inheritedRetirementLoss.receiverStateMayBeStale)
        }
    }
}
