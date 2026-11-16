import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// #715 (E5d): the takeover gap between a cycle's `retire()` and its replacement's install stays (see `KernelCycle`'s
// Takeover gap). These pin what the gap delays, and that the cycle drops none of it.

private let programFive = KernelEventPayload.program(channel: 0, program: 5, bank: 0)
private let controlNine = KernelEventPayload.control(channel: 0, controller: 7, value: 9)

private func noteOn(_ note: UInt8) -> KernelEventPayload { .noteOn(channel: 0, note: note, velocity: 100) }

/// `payload` stamped `frame` in `scope`, emitted at `dispatch`.
private func emission(_ frame: Int64, _ payload: KernelEventPayload, at dispatch: Int64, scope: UInt32 = 0,
                      sequence: UInt64 = 0) -> CycleEmission {
    CycleEmission(event: cycleEvent(frame, payload, scope: scope, sequence: sequence), frame: dispatch)
}

/// The synthesized release of channel 0's `note` in `scope` at `blockStart`.
private func release(_ note: UInt8, scope: UInt32, at blockStart: Int64) -> CycleEmission {
    emission(blockStart, .noteOff(channel: 0, note: note), at: blockStart, scope: scope,
             sequence: KernelCycle.releaseSequence)
}

/// A `.replacingCycle` cycle on `rig`'s parts; the caller retires the previous cycle first.
private func replacement(of rig: CycleRig, blockCapacity: Int = 64, perLaneQuota: Int = 64) throws -> KernelCycle {
    let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership, safety: rig.safety,
                                 ramps: rig.ramps, admissionRefusals: rig.cycle.admissionRefusals)
    return try KernelCycle(parts, pulses: ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48),
                           blockCapacity: blockCapacity, perLaneQuota: perLaneQuota)
}

/// One 64-frame block of `cycle` from `start`: its result and every emission.
private func runBlock(_ cycle: KernelCycle, _ start: Int64) -> (KernelCycleResult, [CycleEmission]) {
    var emitted: [CycleEmission] = []
    let result = cycle.run(blockStart: start, frames: 64) { emitted.append(CycleEmission(event: $0, frame: $1)) }
    return (result, emitted)
}

/// Queues a `program` at 128 and a `control` at 140, runs `rig.cycle`'s last block, [64, 128), where both stay
/// pending, and retires it: the replacement inherits both as its carry.
private func retireWithCarry(_ rig: CycleRig, _ token: ProducerToken) -> KernelRetirementLoss {
    #expect(rig.push(cycleEvent(128, programFive), token) == .ok)
    #expect(rig.push(cycleEvent(140, controlNine), token) == .ok)
    #expect(runBlock(rig.cycle, 64).0.pending == 2)
    return rig.cycle.retire()
}

extension RealtimeHandoffTests {
    /// #715: what the takeover gap delays, one rule at a time (see `KernelCycle`'s Takeover gap).
    struct CycleTakeoverGap {
        /// The old cycle's last block is [64, 128); the replacement's first block starts `gap` event-free callbacks
        /// later, at 128 + 64 × `gap`. It delivers the carried `program` (128) and `control` (140) each at
        /// max(frame, `blockStart`): on time with no gap, and at `blockStart` after any gap, even 1,000 callbacks
        /// (64,000 frames, far past the 480-frame late tolerance). Kills: a carried event dispatched at its original
        /// frame; a late carried event dropped.
        @Test(arguments: [Int64(0), 1, 8, 1_000])
        func carriedEventsDispatchLateAfterAnyGap(gap: Int64) throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            let loss = retireWithCarry(rig, token)
            #expect(loss.programs == 1 && loss.controls == 1 && loss.receiverStateMayBeStale)
            let next = try replacement(of: rig)
            let start = 128 + 64 * gap
            let (result, emitted) = runBlock(next, start)
            #expect(result.status == .ok && result.pending == 0)
            #expect(emitted == [emission(128, programFive, at: max(128, start)),
                                emission(140, controlNine, at: max(140, start))])
            if gap > 0 { #expect(emitted.allSatisfy { $0.frame == start }) }
            #expect(next.carryReadmissionReport.delivered == 2)
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// #715 acceptance, carry against the flush watermark. The replacement (`perLaneQuota` 1) drains one of the
        /// two `noteOn`s in its lane, so that lane is not proved empty and the block reports `flushing`. The flushed
        /// `noteOn` is discarded (`discardedWhileSilenced`), yet the carried `program` and `control` are emitted in
        /// that same block, at `blockStart` (192, after a one-callback gap). Kills: re-admission gated by the
        /// watermark.
        @Test func carryDeliveredWhileReplacementFlushes() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            _ = retireWithCarry(rig, token)
            let next = try replacement(of: rig, perLaneQuota: 1)
            #expect(rig.push(cycleEvent(200, noteOn(60)), token) == .ok)
            #expect(rig.push(cycleEvent(210, noteOn(61)), token) == .ok)
            let (result, emitted) = runBlock(next, 192)
            #expect(result.flushing && result.drained == 1 && result.discardedWhileSilenced == 1)
            #expect(result.status == .ok && result.dispatched == 0 && result.pending == 0)
            #expect(emitted == [emission(128, programFive, at: 192), emission(140, controlNine, at: 192)])
            #expect(next.carryReadmissionReport.delivered == 2)
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 60))
        }

        /// The old cycle is itself a replacement still flushing (`perLaneQuota` 1, two events queued in one lane): it
        /// drains the `control` (200), marked flushed, which is still pending at its retire. The carry keeps it (the
        /// watermark discards only `noteOn`s), and the next replacement delivers it on time at 200 while it discards
        /// the lane's flushed `noteOn` (210). Kills: flushed entries left out of the carry.
        @Test func carriedStatefulEventFromFlushedLaneIsStillCarried() throws {
            let rig = try CycleRig()
            rig.cycle.retire()
            let middle = try replacement(of: rig, perLaneQuota: 1)
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(200, controlNine), token) == .ok)
            #expect(rig.push(cycleEvent(210, noteOn(60)), token) == .ok)
            let (flushed, early) = runBlock(middle, 64)
            #expect(flushed.flushing && flushed.drained == 1 && flushed.pending == 1 && early.isEmpty)
            let loss = middle.retire()
            #expect(loss.controls == 1 && loss.noteOns == 0 && loss.receiverStateMayBeStale)
            let last = try replacement(of: rig)
            #expect(last.inheritedRetirementCarry.events == [cycleEvent(200, controlNine)])
            let (result, emitted) = runBlock(last, 192)
            #expect(emitted == [emission(200, controlNine, at: 200)])
            #expect(result.drained == 1 && result.discardedWhileSilenced == 1 && result.pending == 0)
            #expect(last.carryReadmissionReport.delivered == 1)
            #expect(last.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// A panic requested in the gap silences the replacement's first block (`.safetyMute`): it re-admits nothing,
        /// so the carry stays pending and unresolved, and the next block delivers both carried events at its
        /// `blockStart`. Kills: re-admission in a silenced block; a carry dropped by a silenced block.
        @Test func carryWaitsOutSilencedReplacement() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            _ = retireWithCarry(rig, token)
            #expect(rig.safety.request(.panic, scope: 0) == .ok)
            let next = try replacement(of: rig)
            let (muted, silent) = runBlock(next, 192)
            #expect(muted.status == .silenced(.safetyMute) && silent.isEmpty)
            let waiting = next.carryReadmissionReport
            #expect(waiting.delivered == 0 && waiting.pendingCarriedEvents == 2)
            #expect(next.unresolvedRetirementLoss.stateful == 2)
            let (result, emitted) = runBlock(next, 256)
            #expect(result.status == .ok)
            #expect(emitted == [emission(128, programFive, at: 256), emission(140, controlNine, at: 256)])
            #expect(next.carryReadmissionReport.delivered == 2)
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// The old cycle owns note 60 in scope 0 and note 61 in scope 1 at its retire; a panic is requested in scope 0
        /// during an eight-callback gap. Render's calls to the retired cycle in the gap do nothing (`retired`, no
        /// emission), so both notes stay owned and the panic stays requested. The replacement's first block releases
        /// both notes at its `blockStart` (the takeover) and applies the panic (`.safetyMute`); the next block runs
        /// `.ok`. Kills: the takeover skipped in the first block; safety requests not taken there.
        @Test func gapDefersTakeoverReleasesAndPanic() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(10, noteOn(60)), token) == .ok)
            #expect(rig.push(cycleEvent(20, noteOn(61), scope: 1), token) == .ok)
            #expect(runBlock(rig.cycle, 0).0.dispatched == 2)
            #expect(rig.cycle.retire() == KernelRetirementLoss())
            #expect(rig.safety.request(.panic, scope: 0) == .ok)
            var start: Int64 = 64
            for _ in 0..<8 {
                let (idle, emitted) = runBlock(rig.cycle, start)
                #expect(idle.retired && idle.status == .refused(.notOwner) && emitted.isEmpty)
                start += 64
            }
            #expect(rig.ownership.ownedCount(scope: 0) == 1 && rig.ownership.ownedCount(scope: 1) == 1)
            let next = try replacement(of: rig)
            let (first, emitted) = runBlock(next, start)
            #expect(first.status == .silenced(.safetyMute) && first.releasedNotes == 2)
            #expect(emitted == [release(60, scope: 0, at: start), release(61, scope: 1, at: start)])
            #expect(rig.ownership.ownedCount(scope: 0) == 0 && rig.ownership.ownedCount(scope: 1) == 0)
            let (after, quiet) = runBlock(next, start + 64)
            #expect(after.status == .ok && after.releasedNotes == 0 && quiet.isEmpty)
        }

        /// Nothing drains the fan-in during the gap: with a gap callback (the retired cycle's `run`, draining nothing)
        /// after each push, the lane still takes only `laneCapacity` `noteOff`s and refuses the next with
        /// `.criticalExhausted`, which latches the critical scope, so the replacement's first block is
        /// `.silenced(.scopeFaulted)` and is the first to drain the lane. Kills: a refused `noteOff` that does not
        /// latch; a replacement that skips the latch check in its first block; a gap callback that drains.
        @Test func gapOverflowRefusesNoteOffAndFaultsReplacement() throws {
            let laneCapacity = 20
            let rig = try CycleRig(laneCapacity: laneCapacity)
            let token = try #require(rig.events.claimProducer())
            rig.cycle.retire()
            var start: Int64 = 0
            for index in 0..<laneCapacity {
                #expect(rig.push(cycleEvent(start, .noteOff(channel: 0, note: UInt8(index))), token) == .ok)
                let (idle, emitted) = runBlock(rig.cycle, start)
                #expect(idle.retired && idle.drained == 0 && emitted.isEmpty)
                start += 64
            }
            #expect(!rig.faults.isLatched(CycleRig.criticalScope))
            let refused = cycleEvent(start, .noteOff(channel: 0, note: 60))
            #expect(rig.push(refused, token) == .refused(.criticalExhausted))
            #expect(rig.faults.isLatched(CycleRig.criticalScope))
            let next = try replacement(of: rig)
            let (first, _) = runBlock(next, start)
            #expect(first.status == .silenced(.scopeFaulted) && first.drained == laneCapacity)
        }
    }

    /// #715 acceptance: the gap across a real thread hand-over, for Thread Sanitizer.
    @Suite(.serialized) struct CycleTakeoverGapStress {
        /// 16 rounds on dedicated threads. Render retires a cycle that owns ten notes (60–64 in both scopes) and holds
        /// a pending `program` and `control`, then makes one event-free callback per spin (a `run` of the retired
        /// cycle, which does nothing) until control's replacement appears. Control retries its preparation while
        /// refused `.predecessorNotRetired` (render retires only after the first refusal), then hands it over. Every
        /// wait spins until a `ContinuousClock` deadline `CycleStressRun.waitLimit` away.
        /// The replacement (`blockCapacity` 4) releases the ten notes 4, 4 and 2 per block, each at its block's
        /// `blockStart`, and delivers both carried events in its first block. Between its first two blocks render
        /// queues a `noteOn` in scope 0 (released, so it sounds) and one in scope 1 (still held, so it is
        /// `discardedDuringTakeover`). The gap's length is counted, never asserted. Kills: a lost or repeated carried
        /// event or release; a gap callback doing event work; the takeover skipped in the first block; a race TSan
        /// can see.
        @Test(.timeLimit(.minutes(1))) func renderCountsGapBlocksUntilInstall() throws {
            for round in 0..<16 { try gapRound(Int64(round)) }
        }

        private func gapRound(_ round: Int64) throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            let base = 1_000 + round
            for (index, held) in heldNotes.enumerated() {
                #expect(rig.push(cycleEvent(base + Int64(index), noteOn(held.note), scope: held.scope), token) == .ok)
            }
            let carried = [cycleEvent(base + 100, programFive), cycleEvent(base + 110, controlNine)]
            for event in carried { #expect(rig.push(event, token) == .ok) }
            let last = rig.cycle.run(blockStart: base, frames: 64) { _, _ in }
            #expect(last.dispatched == heldNotes.count && last.pending == 2)
            let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership,
                                         safety: rig.safety, ramps: rig.ramps,
                                         admissionRefusals: rig.cycle.admissionRefusals)
            let run = CycleStressRun()
            let handOff = GapHandOff()
            let traces = CycleSlots<GapTrace>(1)
            let notes = CycleSlots<[String]>(1)
            let workers: [@Sendable (CycleStressRun) -> Void] = [
                { traces.set(0, gapRender(rig, token, $0, handOff, from: base + 64)) },
                { notes.set(0, gapControl(parts, $0, handOff)) }
            ]
            try #require(runCycleWorkers(run, workers))
            #expect(notes.get(0) == [])
            let trace = try #require(traces.get(0))
            #expect(trace.violations.isEmpty, "\(trace.violations.prefix(5))")
            #expect(handOff.refused.load(ordering: .acquiring) > 0)
            let next = try #require(handOff.replacement.get(0))
            try checkReplacement(trace, next, rig, carried)
        }

        /// Releases 4, 4, 2 and 0, each a synthesized release at its block's start and every held note exactly once;
        /// both carried events in the first block at max(frame, start); the scope 0 `noteOn` sounds and the scope 1
        /// one is discarded during the takeover; nothing pending, and only note 70 in scope 0 owned at the end.
        private func checkReplacement(_ trace: GapTrace, _ next: KernelCycle, _ rig: CycleRig,
                                      _ carried: [KernelEvent]) throws {
            try #require(trace.results.count == 4 && trace.emissions.count == 4)
            #expect(trace.results.map(\.releasedNotes) == [4, 4, 2, 0])
            #expect(trace.results.map(\.discardedDuringTakeover) == [0, 1, 0, 0])
            #expect(trace.results.map(\.dispatched) == [0, 1, 0, 0])
            #expect(trace.results.allSatisfy { $0.status == .ok && $0.pending == 0 })
            let first = trace.firstStart
            let isRelease = { (emitted: CycleEmission) in emitted.event.sequence == KernelCycle.releaseSequence }
            let expected = heldNotes.enumerated().map { index, held in
                release(held.note, scope: held.scope, at: first + 64 * Int64(index / 4))
            }
            #expect(trace.emissions.flatMap { $0.filter(isRelease) } == expected)
            let carriedOut = trace.emissions[0].filter { !isRelease($0) }
            #expect(carriedOut == carried.map { CycleEmission(event: $0, frame: max($0.frame, first)) })
            #expect(trace.emissions[1].filter { !isRelease($0) } == [emission(first + 72, noteOn(70), at: first + 72)])
            #expect(trace.emissions[2...].allSatisfy { $0.allSatisfy(isRelease) })
            #expect(next.carryReadmissionReport.delivered == 2)
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
            #expect(rig.ownership.ownedCount(scope: 0) == 1 && rig.ownership.ownedCount(scope: 1) == 0)
            #expect(rig.ownership.isOwned(scope: 0, channel: 0, note: 70))
        }
    }
}

/// The notes the retiring cycle owns, in takeover (scope, channel, note) order: 60–64 on channel 0 in both scopes.
private let heldNotes: [(scope: UInt32, note: UInt8)] = (0..<10).map { (UInt32($0 / 5), UInt8(60 + $0 % 5)) }

/// Control's refused preparations, then its replacement; render retires only after the first refusal, so every
/// round retries.
private final class GapHandOff: Sendable {
    let refused = Atomic<Int>(0)
    let replacement = CycleSlots<KernelCycle>(1)
}

/// What render saw in one round: its event-free callbacks, then each replacement block's result and emissions.
private struct GapTrace: Sendable {
    var gapCallbacks = 0
    var firstStart: Int64 = 0
    var results: [KernelCycleResult] = []
    var emissions: [[CycleEmission]] = []
    var violations: [String] = []
}

/// Render: retires `rig.cycle` once control was refused, runs the retired cycle as one event-free callback per spin
/// from `first` until the replacement appears, then four replacement blocks, queueing `noteOn(70)` in scope 0 and
/// `noteOn(71)` in scope 1 for the second. Each wait ends at most `CycleStressRun.waitLimit` after it starts.
@Sendable private func gapRender(_ rig: CycleRig, _ token: ProducerToken, _ run: CycleStressRun,
                                 _ handOff: GapHandOff, from first: Int64) -> GapTrace {
    var trace = GapTrace()
    guard run.arriveAndWait() else { return trace }
    let refusalDeadline = ContinuousClock.now + CycleStressRun.waitLimit
    while handOff.refused.load(ordering: .acquiring) == 0, ContinuousClock.now < refusalDeadline, !run.shouldStop {
        _ = sched_yield()
    }
    rig.cycle.retire()
    var start = first
    let installDeadline = ContinuousClock.now + CycleStressRun.waitLimit
    while handOff.replacement.get(0) == nil, ContinuousClock.now < installDeadline, !run.shouldStop {
        var worked = false
        let idle = rig.cycle.run(blockStart: start, frames: 64) { _, _ in worked = true }
        if !idle.retired || worked { trace.violations.append("gap callback \(trace.gapCallbacks) did event work") }
        trace.gapCallbacks &+= 1
        start &+= 64
        _ = sched_yield()
    }
    guard let next = handOff.replacement.get(0) else {
        trace.violations.append("render: no replacement after \(trace.gapCallbacks) gap callbacks")
        return trace
    }
    trace.firstStart = start
    for block in 0..<4 {
        for scope in UInt32(0)..<2 where block == 1 {
            let event = cycleEvent(start + 8, noteOn(70 + UInt8(scope)), scope: scope, sequence: UInt64(scope))
            if rig.push(event, token) != .ok { trace.violations.append("noteOn in scope \(scope) refused") }
        }
        var emitted: [CycleEmission] = []
        let result = next.run(blockStart: start, frames: 64) { emitted.append(CycleEmission(event: $0, frame: $1)) }
        trace.results.append(result)
        trace.emissions.append(emitted)
        start &+= 64
    }
    return trace
}

/// Control: prepares the replacement (`blockCapacity` 4), counting each `.predecessorNotRetired` refusal and
/// retrying until `CycleStressRun.waitLimit` passes, then hands it to render. Returns failures.
@Sendable private func gapControl(_ parts: KernelCycleParts, _ run: CycleStressRun,
                                  _ handOff: GapHandOff) -> [String] {
    guard run.arriveAndWait() else { return ["control: not started"] }
    let deadline = ContinuousClock.now + CycleStressRun.waitLimit
    var attempts = 0
    while ContinuousClock.now < deadline, !run.shouldStop {
        attempts &+= 1
        do {
            let gate = try ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48)
            handOff.replacement.set(0, try KernelCycle(parts, pulses: gate, blockCapacity: 4, perLaneQuota: 64))
            return []
        } catch KernelCycle.PreparationError.ownershipClaim(.predecessorNotRetired) {
            handOff.refused.add(1, ordering: .releasing)
            _ = sched_yield()
        } catch {
            return ["control: \(error)"]
        }
    }
    return ["control: no claim within \(CycleStressRun.waitLimit) after \(attempts) attempts"]
}
