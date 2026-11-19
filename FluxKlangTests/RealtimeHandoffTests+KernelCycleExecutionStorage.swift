import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private func executionParts(_ rig: CycleRig) -> KernelCycleParts {
    KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership,
                     safety: rig.safety, ramps: rig.ramps, admissionRefusals: rig.cycle.admissionRefusals)
}

private func executionCandidate(_ parts: KernelCycleParts, capacity: Int = 64) throws -> KernelCycleCandidate {
    try KernelCycleCandidate(parts, pulses: ClockPulseGate(maximumPulsesPerBlock: 1, staleTolerance: 8),
                             blockCapacity: capacity, perLaneQuota: 64)
}

private func executionRun(_ cycle: KernelCycle, _ start: Int64, _ frames: Int64 = 64)
    -> (KernelCycleResult, [KernelEvent]) {
    var emitted: [KernelEvent] = []
    let result = cycle.run(blockStart: start, frames: frames) { event, _ in emitted.append(event) }
    return (result, emitted)
}

/// Uses the existing exact-claim retirement fixture edge, not a second cycle binding or publication path.
private func executionInheritance(_ rig: CycleRig, _ events: [KernelEvent]) throws -> KernelRetirementLoss {
    _ = rig.cycle.retire()
    let claim = try rig.ownership.claimForCycle(fresh: false, from: rig.ownership.cycleClaimState())
    var loss = KernelRetirementLoss()
    var carry = KernelRetirementCarry()
    for event in events {
        loss.drop(event.payload)
        carry.record(event)
    }
    rig.ownership.releaseCycleClaim(claim, loss: loss, carry: carry)
    return loss
}

extension RealtimeHandoffTests {
    /// Behavioral evidence for cohesive preclaim preparation. Private placement, exclusive movement and raw
    /// cleanup still require source review; weak references observe retained objects, not allocation counts.
    struct CycleExecutionStorage {
        @Test func executionPreparationCapturesInputsWithoutExecutingSharedState() throws {
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let slots = try kernelCycleTelemetrySlots()
            let output = KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 7)
            let rig = try CycleRig(telemetry: output)
            let token = try RefusalCalling.claim(rig.events, &caller!)
            _ = rig.run(0, 0)
            let published = try #require(rig.cycle.latestTelemetry())
            _ = rig.cycle.retire()
            #expect(rig.ownership.noteOn(scope: 1, channel: 15, note: 127) == .ok)
            #expect(rig.ramps.set(parameter: 3, target: 1, durationFrames: 64, current: 0) == .ok)
            #expect(rig.ramps.advance(parameter: 3, frames: 16) == 0.25)
            let oldOn = cycleEvent(10, .noteOn(channel: 0, note: 9, velocity: 100))
            rig.ownership.tombstones.release(cycleEvent(20, .noteOff(channel: 0, note: 9)))
            #expect(rig.safety.request(.panic, scope: 0) == .ok)
            let queued = cycleEvent(80, .program(channel: 0, program: 9, bank: 0))
            #expect(rig.push(queued, token, caller: &caller!) == .ok)
            var parts = executionParts(rig)
            parts.telemetry = output
            var gate = try ClockPulseGate(maximumPulsesPerBlock: 1, staleTolerance: 8)
            #expect(gate.admit(pulseFrame: 0, blockStart: 20) == .skipStale)
            let capturedGate = gate
            let state = rig.ownership.cycleClaimState()
            let prepared = try KernelCycleCandidate(parts, pulses: gate, blockCapacity: 3, perLaneQuota: 1)
            let cancelled = try executionCandidate(parts)
            #expect(cancelled.cancel())
            parts.start = .freshFanIn
            parts.admissionRefusals = nil
            parts.telemetry = nil
            let tookResync = gate.takeResync()
            #expect(tookResync)
            #expect(rig.ownership.cycleClaimState() == state)
            #expect(rig.ownership.isOwned(scope: 1, channel: 15, note: 127))
            #expect(rig.ramps.activeCount == 1 && rig.ramps.value(parameter: 3) == 0.25)
            #expect(rig.ramps.lastValue(parameter: 3) == 0.25)
            #expect(rig.ownership.tombstones.supersedes(oldOn, blockStart: 32, lateTolerance: 480))
            #expect(!rig.faults.isLatched(CycleRig.criticalScope))
            #expect(rig.cycle.latestTelemetry()?.value == published.value)
            let cycle = try KernelCycle(binding: prepared)
            #expect(cycle.blockCapacity == 3 && cycle.perLaneQuota == 1)
            #expect(cycle.pulses == capturedGate && cycle.pulses != gate)
            #expect(cycle.admissionRefusals === rig.cycle.admissionRefusals)
            #expect(cycle.telemetry == KernelCycleTelemetry(ackCycle: cycle.ackRequests.identity))
            #expect(cycle.latestTelemetry()?.value == published.value) // No publication during bind either.
            let (empty, releases) = executionRun(cycle, 32, 0)
            #expect(empty.status == .silenced(.safetyMute) && empty.flushing && empty.drained == 0)
            #expect(empty.releasedNotes == 1 && releases.count == 1)
            #expect(cycle.parameterValue(3) == 0.25 && cycle.pulses == capturedGate)
            let (first, emitted) = executionRun(cycle, 64, 32)
            #expect(first.drained == 1 && first.resync && emitted == [queued])
            #expect(cycle.parameterValue(3) == 0.75)
            #expect(cycle.latestTelemetry()?.value.ackCycle == cycle.ackRequests.identity)
            #expect(cycle.latestTelemetry()?.stamp.clockGeneration == 7)
            #expect(rig.ownership.tombstones.supersedes(oldOn, blockStart: 96, lateTolerance: 480))
            _ = cycle.retire()
        }

        @Test func executionDefaultTableIsFreshAndSuppliedTableKeepsProducerProgress() throws {
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            for supplied in [false, true] {
                let rig = try CycleRig()
                let token = try RefusalCalling.claim(rig.events, &caller!)
                let table = rig.cycle.admissionRefusals
                table.record(.refused(.nonFinite), token: token, caller: &caller!)
                _ = rig.cycle.retire()
                let owner = try NoteOwnership(scopes: 2)
                var parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: owner,
                                             safety: rig.safety, ramps: rig.ramps,
                                             admissionRefusals: supplied ? table : nil, start: .freshFanIn)
                let prepared = try executionCandidate(parts)
                parts.admissionRefusals = supplied ? nil : table
                table.record(.refused(.nonFinite), token: token, caller: &caller!)
                let cycle = try KernelCycle(binding: prepared)
                #expect((cycle.admissionRefusals === table) == supplied)
                #expect(cycle.admissionRefusals.handoff == rig.events.identity)
                #expect(cycle.admissionRefusals.laneCount == rig.events.laneCount)
                #expect(cycle.admissionRefusals.total(.nonFinite) == (supplied ? 2 : 0))
                #expect(cycle.admissionRefusals.unattributed == 0)
                #expect(cycle.admissionRefusals.count(lane: -1, .nonFinite) == nil)
                #expect(cycle.admissionRefusals.count(lane: rig.events.laneCount, .nonFinite) == nil)
                let (result, emitted) = executionRun(cycle, 0, 0)
                #expect(!result.flushing && emitted.isEmpty)
                #expect(cycle.telemetry.refusedNonFinite == (supplied ? 2 : 0))
                cycle.admissionRefusals.record(.refused(.nonMonotonic), token: token, caller: &caller!)
                _ = executionRun(cycle, 1, 0)
                #expect(cycle.telemetry.cycle == 2 && cycle.telemetry.refusedNonMonotonic == 1)
                #expect(table.total(.nonFinite) == 2)
                _ = cycle.retire()
            }
        }

        @Test func executionCancelAndAbandonReleaseRetainedComponentsOnControl() throws {
            for cancel in [false, true] {
                weak var owner: NoteOwnership?
                weak var ramps: RampSlots?
                weak var table: KernelAdmissionRefusals?
                weak var observed: KernelCycleCandidate?
                var pending: KernelCycleCandidate?
                do {
                    let rig = try CycleRig()
                    _ = rig.cycle.retire()
                    owner = rig.ownership
                    ramps = rig.ramps
                    table = rig.cycle.admissionRefusals
                    pending = try executionCandidate(executionParts(rig), capacity: 4_096)
                    observed = pending
                }
                #expect(owner != nil && ramps != nil && table != nil)
                if cancel {
                    let alias = try #require(pending)
                    #expect(alias.cancel() && alias.storageInfo == nil)
                    #expect(owner == nil && ramps == nil && table == nil)
                    #expect(!alias.cancel())
                    #expect(throws: KernelCycle.PreparationError.candidateCancelled) {
                        _ = try KernelCycle(binding: alias)
                    }
                }
                pending = nil
                #expect(observed == nil && owner == nil && ramps == nil && table == nil)
            }
        }

        @Test func executionClaimLosersCannotResetWinnerBeforeOrAfterRetirement() throws {
            for fresh in [false, true] {
                for retireBeforeBind in [false, true] {
                    let rig = try CycleRig()
                    _ = rig.cycle.retire()
                    let owner = try NoteOwnership(scopes: 2)
                    let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: owner,
                                                 safety: rig.safety, ramps: rig.ramps,
                                                 admissionRefusals: rig.cycle.admissionRefusals,
                                                 start: fresh ? .freshFanIn : .replacingCycle)
                    let prepared = try executionCandidate(parts)
                    weak var losingRamps: RampSlots?
                    let loser: KernelCycleCandidate
                    do {
                        let privateRamps = try RampSlots(parameterCount: 1)
                        losingRamps = privateRamps
                        let losingParts = KernelCycleParts(
                            events: rig.events, faults: rig.faults, ownership: owner,
                            safety: rig.safety, ramps: privateRamps,
                            admissionRefusals: rig.cycle.admissionRefusals, start: parts.start)
                        loser = try executionCandidate(losingParts, capacity: 4_096)
                    }
                    #expect(losingRamps != nil)
                    let winner = try KernelCycle(binding: prepared)
                    _ = executionRun(winner, 0, 0)
                    if retireBeforeBind { _ = winner.retire() }
                    let state = owner.cycleClaimState()
                    let telemetry = winner.telemetry
                    let report = winner.carryReadmissionReport
                    let refusal: NoteOwnership.CycleClaimRefusal = fresh ? .alreadyUsed :
                        (retireBeforeBind ? .claimRaced : .predecessorNotRetired)
                    #expect(throws: KernelCycle.PreparationError.ownershipClaim(refusal)) {
                        _ = try KernelCycle(binding: loser)
                    }
                    #expect(loser.storageInfo == nil && !loser.cancel() && losingRamps == nil)
                    #expect(throws: KernelCycle.PreparationError.candidateConsumed) {
                        _ = try KernelCycle(binding: loser)
                    }
                    #expect(owner.cycleClaimState() == state && winner.telemetry == telemetry)
                    #expect(winner.carryReadmissionReport == report)
                    _ = winner.retire()
                }
            }
        }

        @Test func executionConsumedAliasesPreserveTakeoverGateRampsAndTelemetryProgress() throws {
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let rig = try CycleRig()
            let token = try RefusalCalling.claim(rig.events, &caller!)
            _ = rig.cycle.retire()
            for note in [UInt8(1), UInt8(2)] {
                #expect(rig.ownership.noteOn(scope: 0, channel: 0, note: note) == .ok)
            }
            #expect(rig.ramps.set(parameter: 3, target: 1, durationFrames: 64, current: 0) == .ok)
            let parts = executionParts(rig)
            var prepared: KernelCycleCandidate? = try executionCandidate(parts, capacity: 1)
            weak var observed: KernelCycleCandidate?
            observed = prepared
            // An independent pending competitor can be destroyed after execution has changed every component.
            var loser: KernelCycleCandidate? = try executionCandidate(parts, capacity: 1)
            let cycle = try KernelCycle(binding: #require(prepared))
            let (first, firstEmitted) = executionRun(cycle, 0, 16)
            #expect(first.releasedNotes == 1 && firstEmitted.map(\.payload) == [.noteOff(channel: 0, note: 1)])
            #expect(cycle.parameterValue(3) == 0.25)
            let telemetry = cycle.telemetry
            let state = rig.ownership.cycleClaimState()
            do {
                let alias = try #require(prepared)
                #expect(!alias.cancel())
                #expect(throws: KernelCycle.PreparationError.candidateConsumed) {
                    _ = try KernelCycle(binding: alias)
                }
                #expect(cycle.telemetry == telemetry && rig.ownership.cycleClaimState() == state)
            }
            prepared = nil
            #expect(observed == nil)
            // The first takeover bit must survive candidate destruction; the second release remains pending.
            #expect(rig.push(cycleEvent(16, .noteOff(channel: 0, note: 1)), token, caller: &caller!) == .ok)
            let (second, secondEmitted) = executionRun(cycle, 16, 16)
            #expect(second.releasedNotes == 1 && second.discardedWhileSilenced == 1)
            #expect(secondEmitted.map(\.payload) == [.noteOff(channel: 0, note: 2)])
            #expect(cycle.parameterValue(3) == 0.5 && cycle.telemetry.cycle == 2)
            #expect(rig.push(cycleEvent(0, .clockPulse), token, caller: &caller!) == .ok)
            let (stale, _) = executionRun(cycle, 32, 16)
            #expect(stale.skippedPulses == 1 && stale.resync && cycle.pulses.skippedStale == 1)
            #expect(cycle.parameterValue(3) == 0.75 && cycle.telemetry.resyncs == 1)
            let progressed = cycle.telemetry
            let pulses = cycle.pulses
            #expect(try #require(loser).cancel())
            loser = nil
            #expect(cycle.telemetry == progressed && cycle.pulses == pulses)
            #expect(cycle.parameterValue(3) == 0.75)
            _ = cycle.retire()
            let successorCandidate = try executionCandidate(parts, capacity: 1)
            let successor = try KernelCycle(binding: successorCandidate)
            #expect(successor.telemetry.cycle == 0 && successor.pulses.skippedStale == 0)
            let oldTelemetry = cycle.telemetry
            #expect(executionRun(cycle, 48).0.retired)
            #expect(!successorCandidate.cancel() && cycle.telemetry == oldTelemetry)
            _ = executionRun(successor, 48, 16)
            #expect(successor.parameterValue(3) == 1 && successor.telemetry.cycle == 1)
            _ = successor.retire()
        }

        @Test func executionUsesOwningCyclesCompletedEmptyNonemptyAndRefusedReadmission() throws {
            let first = cycleEvent(100, .control(channel: 0, controller: 7, value: 3))
            let last = cycleEvent(200, .program(channel: 0, program: 5, bank: 0))
            let overflow = cycleEvent(.max - 1, .rampTo(parameter: 3, value: 1, durationFrames: 2))
            for input in [[], [first, last], [first, overflow]] {
                let rig = try CycleRig()
                let loss = try executionInheritance(rig, input)
                let prepared = try executionCandidate(executionParts(rig))
                let reserved = try #require(prepared.storageInfo)
                let cycle = try KernelCycle(binding: prepared)
                let refused = input.contains(overflow)
                let count = refused ? 0 : input.count
                let info = cycle.carryReadmissionStorageInfo
                #expect(info.fingerprint == reserved.fingerprint && info.initializedCount == count)
                #expect(cycle.carryReadmissionReport.planRefusal == (refused ? .frameOverflow : nil))
                #expect(cycle.carryReadmissionReport.planned == count)
                #expect(cycle.carryReadmissionReport.pendingCarriedEvents == count)
                #expect(cycle.inheritedRetirementLoss == loss && cycle.unresolvedRetirementLoss == loss)
                #expect(cycle.telemetry.ackCycle == cycle.ackRequests.identity)
                let (early, emitted) = executionRun(cycle, 64)
                #expect(early.status == .ok && emitted == (count == 0 ? [] : [first]))
                #expect(cycle.carryReadmissionReport.delivered == (count == 0 ? 0 : 1))
                #expect(cycle.carryReadmissionReport.pendingCarriedEvents == (count == 0 ? 0 : 1))
                #expect(cycle.carryReadmissionStorageInfo == info)
                #expect(!prepared.cancel())
                #expect(throws: KernelCycle.PreparationError.candidateConsumed) {
                    _ = try KernelCycle(binding: prepared)
                }
                let (_, later) = executionRun(cycle, 192)
                #expect(later == (count == 0 ? [] : [last]))
                #expect(cycle.carryReadmissionReport.delivered == count)
                #expect(cycle.unresolvedRetirementLoss == (refused ? loss : KernelRetirementLoss()))
                #expect(cycle.telemetry.cycle == 2 && cycle.carryReadmissionStorageInfo == info)
                _ = cycle.retire()
            }
        }

        @Test(arguments: [false, true])
        func executionDimensionsExerciseLastLaneScopeNoteAndRamp(maximum: Bool) throws {
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let lanes = maximum ? KernelLimits.maximumProducers : 1
            let scopes = maximum ? NoteOwnership.maximumScopes : 1
            let parameters = maximum ? RampSlots.maximumParameters : 1
            let rig = try CycleRig(lanes: lanes)
            _ = rig.cycle.retire()
            var tokens: [ProducerToken] = []
            for _ in 0..<lanes { tokens.append(try RefusalCalling.claim(rig.events, &caller!)) }
            let token = try #require(tokens.last)
            #expect(Int(token.lane) == lanes - 1)
            let owner = try NoteOwnership(scopes: scopes)
            let ramps = try RampSlots(parameterCount: parameters)
            let safety = try SafetyFlags(scopes: scopes)
            let scope = UInt32(scopes - 1)
            let parameter = UInt32(parameters - 1)
            #expect(owner.noteOn(scope: scope, channel: 15, note: 127) == .ok)
            let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: owner,
                                         safety: safety, ramps: ramps)
            let prepared = try executionCandidate(parts, capacity: maximum ? 4_096 : 1)
            let cycle = try KernelCycle(binding: prepared)
            let (empty, releases) = executionRun(cycle, 0, 0)
            #expect(empty.flushing && empty.releasedNotes == 1 && releases.count == 1)
            #expect(!owner.isOwned(scope: scope, channel: 15, note: 127))
            #expect(rig.push(cycleEvent(1, .noteOff(channel: 15, note: 127), scope: scope),
                             token, caller: &caller!) == .ok)
            let (off, emitted) = executionRun(cycle, 1, 1)
            #expect(off.discardedWhileSilenced == 1 && emitted.isEmpty)
            let ramp = cycleEvent(2, .rampTo(parameter: parameter, value: 1, durationFrames: 4), scope: scope)
            #expect(rig.push(ramp, token, caller: &caller!) == .ok)
            let (started, rampEvents) = executionRun(cycle, 2, 2)
            #expect(started.dispatched == 1 && rampEvents == [ramp])
            #expect(cycle.parameterValue(parameter) == 0.5)
            _ = executionRun(cycle, 4, 2)
            #expect(cycle.parameterValue(parameter) == 1 && ramps.activeCount == 0)
            #expect(cycle.parameterValue(UInt32(parameters)) == nil)
            cycle.admissionRefusals.record(.refused(.beyondLookahead), token: token, caller: &caller!)
            _ = executionRun(cycle, 6, 1)
            #expect(cycle.admissionRefusals.count(lane: lanes - 1, .beyondLookahead) == 1)
            #expect(cycle.telemetry.refusedBeyondLookahead == 1 && !cycle.telemetry.flushing)
            #expect(cycle.telemetry.blockAppendRefused == 0)
            _ = cycle.retire()
        }

        @Test func executionReadyRetiredLifetimeEndsOnlyAtFinalControlRelease() throws {
            weak var owner: NoteOwnership?
            weak var ramps: RampSlots?
            weak var table: KernelAdmissionRefusals?
            weak var observed: KernelCycle?
            var ready: KernelCycle?
            do {
                let rig = try CycleRig()
                _ = rig.cycle.retire()
                let prepared = try executionCandidate(executionParts(rig))
                ready = try KernelCycle(binding: prepared)
                observed = ready
                owner = rig.ownership
                ramps = rig.ramps
                table = rig.cycle.admissionRefusals
                #expect(!prepared.cancel())
            }
            #expect(owner != nil && ramps != nil && table != nil)
            do {
                let cycle = try #require(ready)
                _ = executionRun(cycle, 0)
                _ = cycle.retire()
                #expect(owner != nil && ramps != nil && table != nil)
                #expect(cycle.telemetry.cycle == 1 && cycle.carryReadmissionReport.planned == 0)
            }
            ready = nil
            #expect(observed == nil && owner == nil && ramps == nil && table == nil)
        }
    }
}
