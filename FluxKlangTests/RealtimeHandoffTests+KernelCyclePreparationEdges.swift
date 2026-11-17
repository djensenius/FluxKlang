import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RealtimeHandoffTests.CycleOrdering {
    /// Kills: a slot outside the telemetry slots accepted at preparation.
    @Test func telemetrySlotOutOfRangeRefusedAtPreparation() throws {
        let rig = try CycleRig()
        let slots = try kernelCycleTelemetrySlots()
        let gate = try ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 0)
        for slot in [-1, 2, Int.max] {
            let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership,
                                         safety: rig.safety, ramps: rig.ramps,
                                         telemetry: KernelCycleTelemetryOutput(slots: slots, slot: slot,
                                                                               clockGeneration: 0))
            #expect(throws: KernelCycle.PreparationError.telemetrySlotOutOfRange(slot)) {
                try KernelCycle(parts, pulses: gate, blockCapacity: 4, perLaneQuota: 4)
            }
        }
    }

    /// A replacement cycle on the same telemetry slots restarts its epochs at 0; its faulted cycle at epoch 1
    /// approves its own ticket only, never the replaced cycle's epoch-1 ticket. Kills: ignoring the identity.
    @Test func replacementCycleOnTheSameSlotsNeverApprovesAnOldTicket() throws {
        let slots = try kernelCycleTelemetrySlots()
        let output = KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 0)
        let replaced = try CycleRig(telemetry: output)
        #expect(replaced.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
        let oldTicket = try replaced.cycle.ackRequests.request(
            for: try #require(replaced.faults.observe(CycleRig.criticalScope)))
        let replacement = try CycleRig(telemetry: output)
        #expect(replacement.cycle.ackRequests.identity != replaced.cycle.ackRequests.identity)
        #expect(replacement.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
        let newTicket = try replacement.cycle.ackRequests.request(
            for: try #require(replacement.faults.observe(CycleRig.criticalScope)))
        #expect(oldTicket.epoch == newTicket.epoch && oldTicket.cycle != newTicket.cycle)
        #expect(replacement.run(0, 64).0.status == .silenced(.scopeFaulted))
        let sample = try #require(replacement.cycle.latestTelemetry()).value
        #expect(sample.ackCycle == replacement.cycle.ackRequests.identity && sample.lastFaultedAckEpoch == 1)
        #expect(sample.permitsAcknowledgement(newTicket) && !sample.permitsAcknowledgement(oldTicket))
    }

    /// Kills: an epoch that wraps instead of refusing once `UInt64.max` was requested.
    @Test func exhaustedAckEpochRefusesWithoutWrapping() throws {
        let rig = try CycleRig()
        let requests = try #require(KernelAckRequests(
            faults: rig.faults, criticalScope: CycleRig.criticalScope, lastRequestedForTesting: .max - 1))
        #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
        let observation = try #require(rig.faults.observe(CycleRig.criticalScope))
        let last = try requests.request(for: observation)
        #expect(last.epoch == .max)
        #expect(throws: KernelAckRequests.RequestError.epochExhausted) {
            _ = try requests.request(for: observation)
        }
        #expect(requests.lastRequested == .max)
    }
}

extension RealtimeHandoffTests.CycleOrderingRetirement {
    /// Copilot round 4 (4487174356): a `.freshFanIn` preparation reads the never-claimed claim word, then another
    /// cycle claims, sounds note 9 (set directly: the racer never runs) and retires before it claims. Its claim
    /// from that stale state is `.alreadyUsed` and changes nothing. A `.replacingCycle` claim from the retired
    /// snapshot (taken while the word was free) is `.predecessorNotRetired` once `next` holds the word. `racer`
    /// and `next` share `rig.events` while `rig.cycle` lives. A replacement takes note 9 over; a stale release
    /// of a handed-back claim releases nothing, and its non-empty loss never replaces the one the holder left
    /// (round 2j). Kills: the claim compare-exchanging from a re-read word (check-then-claim); a stale release
    /// releasing any claim; the loss stored without the `== claim.held` guard.
    @Test func freshClaimRacingAClaimRunRetireIsRefused() throws {
        let rig = try CycleRig()
        let ownership = try NoteOwnership(scopes: 2)
        let stale = ownership.cycleClaimState()
        #expect(NoteOwnership.cycleClaimRefusal(stale, fresh: true) == nil)
        let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: ownership,
                                     safety: rig.safety, ramps: rig.ramps,
                                     admissionRefusals: rig.cycle.admissionRefusals)
        let gate = try ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48)
        let racer = try KernelCycle(parts, pulses: gate, blockCapacity: 64, perLaneQuota: 64)
        #expect(ownership.noteOn(scope: 0, channel: 0, note: 9) == .ok)
        racer.retire()
        let retired = ownership.cycleClaimState()
        #expect(throws: NoteOwnership.CycleClaimRefusal.alreadyUsed) {
            try ownership.claimForCycle(fresh: true, from: stale)
        }
        let next = try KernelCycle(parts, pulses: gate, blockCapacity: 64, perLaneQuota: 64)
        #expect(throws: NoteOwnership.CycleClaimRefusal.predecessorNotRetired) {
            try ownership.claimForCycle(fresh: false, from: retired)
        }
        var emitted: [CycleEmission] = []
        _ = next.run(blockStart: 0, frames: 64) { emitted.append(CycleEmission(event: $0, frame: $1)) }
        let release = CycleEmission(event: KernelEvent(frame: 0, scope: 0, sequence: KernelCycle.releaseSequence,
                                                       payload: .noteOff(channel: 0, note: 9)), frame: 0)
        #expect(emitted == [release])
        let direct = try NoteOwnership(scopes: 1)
        let stray = KernelRetirementLoss(noteOns: 0, controls: 0, programs: 1, ramps: 0, clockPulses: 0)
        let left = KernelRetirementLoss(noteOns: 0, controls: 0, programs: 0, ramps: 0, clockPulses: 1)
        let held = try direct.claimForCycle(fresh: true, from: direct.cycleClaimState())
        direct.releaseCycleClaim(held, loss: KernelRetirementLoss())
        let holder = try direct.claimForCycle(fresh: false, from: direct.cycleClaimState())
        direct.releaseCycleClaim(held, loss: stray)
        #expect(throws: NoteOwnership.CycleClaimRefusal.predecessorNotRetired) {
            try direct.claimForCycle(fresh: false, from: direct.cycleClaimState())
        }
        direct.releaseCycleClaim(holder, loss: left)
        direct.releaseCycleClaim(held, loss: stray)
        #expect(try direct.claimForCycle(fresh: false, from: direct.cycleClaimState()).inherited == left)
    }
}

/// Control's `.predecessorNotRetired` refusal count, which render waits on before it retires.
private final class RetryProof: Sendable {
    /// Most spins either side takes: a count, not a clock, so a stuck peer fails the test instead of hanging it.
    static let spinLimit = 1_000_000
    let refusals = Atomic<Int>(0)
}

extension RealtimeHandoffTests.CycleOrderingStress {
    /// Round 2h (delta review), #360 MINOR 2: render runs the old cycle (its `noteOff(60)` at 1100 pending), then
    /// waits until control has recorded at least one `.predecessorNotRetired` refusal, and only then retires it,
    /// so the refused-then-claimed path always runs. Both waits are bounded by a spin count (1,000,000, yielding,
    /// no clock) and fail with a recorded note rather than hanging. The replacement then runs, and a late
    /// `noteOn(60)` at 1050 is superseded by the retired cycle's tombstone. A `run` after `retire()` on render
    /// reports `retired`. Kills: a race TSan can see across the hand-back; a retire that never hands the claim
    /// back (control records its refusals, then no claim within the bound).
    /// Round 2i: the `program` pending at 1110 is dropped, counted by render's `retire()` and inherited by
    /// control's replacement across the hand-back.
    @Test func controlRetriesReplacementWhileRenderRetires() throws {
        let rig = try CycleRig()
        let first = try #require(rig.events.claimProducer()), second = try #require(rig.events.claimProducer())
        #expect(rig.push(cycleEvent(1_100, .noteOff(channel: 0, note: 60)), second) == .ok)
        #expect(rig.push(cycleEvent(1_110, .program(channel: 0, program: 5, bank: 0)), second) == .ok)
        let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership,
                                     safety: rig.safety, ramps: rig.ramps,
                                     admissionRefusals: rig.cycle.admissionRefusals)
        let run = CycleStressRun()
        let proof = RetryProof()
        let replaced = CycleSlots<KernelCycle>(1)
        let notes = CycleSlots<[String]>(2)
        let seenBeforeRetire = CycleSlots<Int>(1)
        let workers: [@Sendable (CycleStressRun) -> Void] = [
            { run in
                guard run.arriveAndWait() else { return }
                let pending = rig.cycle.run(blockStart: 1_000, frames: 64) { _, _ in }.pending
                var spins = 0
                while proof.refusals.load(ordering: .acquiring) == 0, spins < RetryProof.spinLimit,
                      !run.shouldStop {
                    spins &+= 1
                    _ = sched_yield()
                }
                let seen = proof.refusals.load(ordering: .acquiring)
                seenBeforeRetire.set(0, seen)
                let loss = rig.cycle.retire()
                let stray = rig.cycle.run(blockStart: 1_064, frames: 64) { _, _ in }
                let held = pending == 2 && stray.retired && loss.programs == 1 && loss.stateful == 1
                let waited = seen > 0 ? [] : ["render: no refusal within \(RetryProof.spinLimit) spins"]
                notes.set(0, held ? waited : ["render: pending \(pending), \(stray), \(loss)"] + waited)
            },
            { run in
                guard run.arriveAndWait() else { return }
                var attempts = 0
                while !run.shouldStop, attempts < RetryProof.spinLimit {
                    attempts &+= 1
                    do {
                        let gate = try ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48)
                        replaced.set(0, try KernelCycle(parts, pulses: gate, blockCapacity: 64, perLaneQuota: 64))
                        break
                    } catch KernelCycle.PreparationError.ownershipClaim(.predecessorNotRetired) {
                        proof.refusals.add(1, ordering: .releasing)
                        _ = sched_yield()
                    } catch {
                        notes.set(1, ["control: \(error)"])
                        return
                    }
                }
                let refused = proof.refusals.load(ordering: .acquiring)
                notes.set(1, replaced.get(0) == nil ? ["control: no claim after \(refused) refusals"] : [])
            }
        ]
        try #require(runCycleWorkers(run, workers))
        #expect(notes.get(0) == [] && notes.get(1) == [])
        #expect(try #require(seenBeforeRetire.get(0)) >= 1 && proof.refusals.load(ordering: .acquiring) >= 1)
        let replacement = try #require(replaced.get(0))
        let inherited = replacement.inheritedRetirementLoss
        #expect(inherited.programs == 1 && inherited.stateful == 1 && inherited.receiverStateMayBeStale)
        let inheritedCarry = replacement.inheritedRetirementCarry
        #expect(inheritedCarry.count == 1 && inheritedCarry.droppedForCapacity == 0)
        #expect(inheritedCarry.event(at: 0) == cycleEvent(1_110, .program(channel: 0, program: 5, bank: 0)))
        var readmitted: [CycleEmission] = []
        let firstRun = replacement.run(blockStart: 1_064, frames: 64) {
            readmitted.append(CycleEmission(event: $0, frame: $1))
        }
        #expect(firstRun.status == .ok && firstRun.dispatched == 0)
        // KCR1: the carried `program` is re-admitted at its own frame and is no longer unresolved.
        #expect(readmitted == [CycleEmission(event: cycleEvent(1_110, .program(channel: 0, program: 5, bank: 0)),
                                             frame: 1_110)])
        #expect(!replacement.unresolvedRetirementLoss.receiverStateMayBeStale)
        #expect(rig.push(cycleEvent(1_050, .noteOn(channel: 0, note: 60, velocity: 90)), first) == .ok)
        var emitted = 0
        let late = replacement.run(blockStart: 1_128, frames: 64) { _, _ in emitted += 1 }
        #expect(emitted == 0 && late.discardedSuperseded == 1)
        #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 60))
    }
}
