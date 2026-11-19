import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private func candidateParts(_ rig: CycleRig, ownership: NoteOwnership? = nil) -> KernelCycleParts {
    KernelCycleParts(events: rig.events, faults: rig.faults, ownership: ownership ?? rig.ownership,
                     safety: rig.safety, ramps: rig.ramps, admissionRefusals: rig.cycle.admissionRefusals)
}

private func candidate(_ parts: KernelCycleParts, capacity: Int = 64) throws -> KernelCycleCandidate {
    try KernelCycleCandidate(parts, pulses: ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48),
                             blockCapacity: capacity, perLaneQuota: 64)
}

extension RealtimeHandoffTests {
    /// New one-shot API coverage, not a reproduction of a duplicate-adoption bug in the legacy constructor.
    /// Same-candidate aliases are used synchronously on control, never concurrently.
    struct CycleCandidate {
        @Test(arguments: [1, 256, 4096])
        func candidateBlockPreparationLeavesOwnershipAndQueuedEventsUntouched(capacity: Int) throws {
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let rig = try CycleRig()
            let token = try RefusalCalling.claim(rig.events, &caller!)
            let queued = cycleEvent(200, .control(channel: 0, controller: 7, value: 9))
            #expect(rig.push(queued, token, caller: &caller!) == .ok)
            _ = rig.cycle.retire()
            let state = rig.ownership.cycleClaimState()
            let parts = candidateParts(rig)
            let prepared = try candidate(parts, capacity: capacity)
            let cancelled = try candidate(parts, capacity: capacity)
            #expect(cancelled.cancel())
            weak var abandoned: KernelCycleCandidate?
            do {
                let privateCandidate = try candidate(parts, capacity: capacity)
                abandoned = privateCandidate
                withExtendedLifetime(privateCandidate) { #expect(abandoned != nil) }
            }
            #expect(abandoned == nil)
            #expect(rig.ownership.cycleClaimState() == state)
            let cycle = try KernelCycle(binding: prepared)
            #expect(cycle.blockCapacity == capacity && cycle.bufferedCount == 0)
            let empty = cycle.run(blockStart: 0, frames: 0) { _, _ in Issue.record("empty block emitted") }
            #expect(empty.drained == 0 && empty.pending == 0)
            let early = cycle.run(blockStart: 0, frames: 64) { _, _ in Issue.record("future event emitted") }
            #expect(early.drained == 1 && early.pending == 1 && cycle.bufferedCount == 1)
            var emitted: [KernelEvent] = []
            let due = cycle.run(blockStart: 192, frames: 64) { event, _ in emitted.append(event) }
            #expect(due.drained == 0 && due.pending == 0 && emitted == [queued])
            _ = cycle.retire()
        }

        @Test(arguments: [1, 256, 4096])
        func candidateConsumedCancellationAndDestructionPreserveBufferedEvent(capacity: Int) throws {
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let rig = try CycleRig()
            let token = try RefusalCalling.claim(rig.events, &caller!)
            _ = rig.cycle.retire()
            let queued = cycleEvent(200, .program(channel: 0, program: 5, bank: 0))
            #expect(rig.push(queued, token, caller: &caller!) == .ok)
            weak var observed: KernelCycleCandidate?
            let winner: KernelCycle
            do {
                let prepared = try candidate(candidateParts(rig), capacity: capacity)
                let alias = prepared
                observed = prepared
                winner = try KernelCycle(binding: prepared)
                #expect(winner.bufferedCount == 0)
                #expect(winner.run(blockStart: 0, frames: 64) { _, _ in
                    Issue.record("future event emitted")
                }.pending == 1)
                let state = rig.ownership.cycleClaimState()
                #expect(!alias.cancel())
                #expect(throws: KernelCycle.PreparationError.candidateConsumed) {
                    _ = try KernelCycle(binding: alias)
                }
                #expect(winner.bufferedCount == 1 && rig.ownership.cycleClaimState() == state)
            }
            #expect(observed == nil && winner.bufferedCount == 1)
            var emitted: [KernelEvent] = []
            let due = winner.run(blockStart: 192, frames: 64) { event, _ in emitted.append(event) }
            #expect(due.drained == 0 && due.pending == 0 && emitted == [queued])
            _ = winner.retire()
        }

        @Test func candidateCapturesPartsPulsesCapacitiesAndOwner() throws {
            let rig = try CycleRig()
            let owner = try NoteOwnership(scopes: 2)
            let otherOwner = try NoteOwnership(scopes: 2)
            let slots = try kernelCycleTelemetrySlots()
            var parts = candidateParts(rig, ownership: owner)
            parts.telemetry = KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 7)
            parts.start = .freshFanIn
            let table = try #require(parts.admissionRefusals)
            var pulses = try ClockPulseGate(maximumPulsesPerBlock: 2, staleTolerance: 11)
            let capturedPulses = pulses
            let prepared = try KernelCycleCandidate(parts, pulses: pulses, blockCapacity: 3, perLaneQuota: 1)
            let other = try candidate(candidateParts(rig, ownership: otherOwner))
            let free = owner.cycleClaimState()
            let otherFree = otherOwner.cycleClaimState()
            parts.telemetry = nil
            parts.admissionRefusals = nil
            parts.start = .replacingCycle
            _ = pulses.admit(pulseFrame: 0, blockStart: 100)
            #expect(owner.cycleClaimState() == free && otherOwner.cycleClaimState() == otherFree)
            let cycle = try KernelCycle(binding: prepared)
            #expect(cycle.blockCapacity == 3 && cycle.perLaneQuota == 1)
            #expect(cycle.pulses == capturedPulses && cycle.pulses != pulses)
            #expect(cycle.admissionRefusals === table)
            #expect(otherOwner.cycleClaimState() == otherFree && owner.cycleClaimState() != free)
            let result = cycle.run(blockStart: 0, frames: 0) { _, _ in Issue.record("unexpected emission") }
            #expect(!result.flushing) // Captured fresh mode, not caller's later replacement mode.
            #expect(cycle.latestTelemetry()?.value.ackCycle == cycle.ackRequests.identity)
            let otherCycle = try KernelCycle(binding: other)
            #expect(otherOwner.cycleClaimState() != otherFree)
            #expect(otherCycle.ackRequests.identity != cycle.ackRequests.identity)
            #expect(cycle.inheritedRetirementCarry == KernelRetirementCarry())
            #expect(cycle.carryReadmissionReport.planned == 0)
            #expect(!cycle.unresolvedRetirementLoss.receiverStateMayBeStale)
            _ = cycle.retire()
            _ = otherCycle.retire()
        }

        @Test func candidateAliasesCancelWithoutClaimingOrCancellingIndependentPreparation() throws {
            let rig = try CycleRig()
            _ = rig.cycle.retire()
            let parts = candidateParts(rig)
            let prepared = try candidate(parts)
            let alias = prepared
            let independent = try candidate(parts)
            #expect(prepared === alias && prepared !== independent)
            let state = rig.ownership.cycleClaimState()
            let report = rig.cycle.carryReadmissionReport
            let telemetry = rig.cycle.telemetry
            #expect(alias.cancel())
            #expect(!prepared.cancel())
            #expect(throws: KernelCycle.PreparationError.candidateCancelled) {
                _ = try KernelCycle(binding: alias)
            }
            #expect(rig.ownership.cycleClaimState() == state)
            #expect(rig.cycle.carryReadmissionReport == report && rig.cycle.telemetry == telemetry)
            let winner = try KernelCycle(binding: independent)
            #expect(winner.inheritedRetirementLoss == KernelRetirementLoss())
            #expect(winner.carryReadmissionReport.planned == 0)
            #expect(!independent.cancel())
            _ = winner.retire()
        }

        @Test func candidateConsumedAliasesCannotResetPartialCarryRetirementOrSuccessor() throws {
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let rig = try CycleRig()
            let token = try RefusalCalling.claim(rig.events, &caller!)
            let pending = [cycleEvent(100, .control(channel: 0, controller: 7, value: 9)),
                           cycleEvent(200, .program(channel: 0, program: 5, bank: 0))]
            for event in pending { #expect(rig.push(event, token, caller: &caller!) == .ok) }
            #expect(rig.run(0, 64).0.pending == 2)
            let loss = rig.cycle.retire()
            let parts = candidateParts(rig)
            let prepared = try candidate(parts)
            let alias = prepared
            let winner = try KernelCycle(binding: prepared)
            let inherited = winner.inheritedRetirementCarry
            #expect(inherited.count == 2 && winner.inheritedRetirementLoss == loss)
            func rejectWithoutChanges() {
                let state = rig.ownership.cycleClaimState()
                let report = winner.carryReadmissionReport
                let unresolved = winner.unresolvedRetirementLoss
                let telemetry = winner.telemetry
                #expect(throws: KernelCycle.PreparationError.candidateConsumed) {
                    _ = try KernelCycle(binding: alias)
                }
                #expect(!alias.cancel())
                #expect(rig.ownership.cycleClaimState() == state)
                #expect(winner.carryReadmissionReport == report && winner.unresolvedRetirementLoss == unresolved)
                #expect(winner.telemetry == telemetry && winner.inheritedRetirementCarry == inherited)
                #expect(winner.inheritedRetirementLoss == loss)
            }
            rejectWithoutChanges()
            var emitted: [KernelEvent] = []
            _ = winner.run(blockStart: 64, frames: 64) { event, _ in emitted.append(event) }
            #expect(emitted == [pending[0]])
            #expect(winner.carryReadmissionReport.delivered == 1)
            #expect(winner.carryReadmissionReport.pendingCarriedEvents == 1)
            rejectWithoutChanges()
            _ = winner.retire()
            rejectWithoutChanges()
            let successor = try KernelCycle(binding: candidate(parts))
            let successorReport = successor.carryReadmissionReport
            #expect(successorReport.planned == 1)
            rejectWithoutChanges()
            #expect(successor.carryReadmissionReport == successorReport)
            emitted.removeAll()
            _ = successor.run(blockStart: 192, frames: 64) { event, _ in emitted.append(event) }
            #expect(emitted == [pending[1]] && successor.carryReadmissionReport.delivered == 1)
            _ = successor.retire()
        }

        @Test(arguments: [1, 256, 4096])
        func candidateReplacementLosersAreTerminalOnBothSidesOfRetirement(capacity: Int) throws {
            for retireBeforeBind in [false, true] {
                let rig = try CycleRig()
                _ = rig.cycle.retire()
                let parts = candidateParts(rig)
                let winnerCandidate = try candidate(parts, capacity: capacity)
                let loser = try candidate(parts, capacity: capacity)
                let alias = loser
                let winner = try KernelCycle(binding: winnerCandidate)
                if retireBeforeBind { _ = winner.retire() }
                let state = rig.ownership.cycleClaimState()
                let report = winner.carryReadmissionReport
                let refusal: NoteOwnership.CycleClaimRefusal =
                    retireBeforeBind ? .claimRaced : .predecessorNotRetired
                #expect(throws: KernelCycle.PreparationError.ownershipClaim(refusal)) {
                    _ = try KernelCycle(binding: loser)
                }
                #expect(rig.ownership.cycleClaimState() == state && winner.carryReadmissionReport == report)
                #expect(!alias.cancel())
                _ = winner.retire()
                #expect(throws: KernelCycle.PreparationError.candidateConsumed) {
                    _ = try KernelCycle(binding: alias)
                }
                let next = try KernelCycle(binding: candidate(parts))
                #expect(throws: KernelCycle.PreparationError.candidateConsumed) {
                    _ = try KernelCycle(binding: loser)
                }
                #expect(next.carryReadmissionReport.planned == 0)
                _ = next.retire()
            }
        }

        @Test func candidateFreshStaleSnapshotPreservesAlreadyUsedAndHeldPreparationRefuses() throws {
            let rig = try CycleRig()
            let owner = try NoteOwnership(scopes: 2)
            var parts = candidateParts(rig, ownership: owner)
            parts.start = .freshFanIn
            let stale = try candidate(parts)
            let winner = try KernelCycle(binding: candidate(parts))
            for retireBeforeBind in [false, true] {
                if retireBeforeBind { _ = winner.retire() }
                #expect(throws: KernelCycle.PreparationError.ownershipClaim(.alreadyUsed)) {
                    _ = try candidate(parts)
                }
            }
            #expect(throws: KernelCycle.PreparationError.ownershipClaim(.alreadyUsed)) {
                _ = try KernelCycle(binding: stale)
            }
            #expect(throws: KernelCycle.PreparationError.candidateConsumed) {
                _ = try KernelCycle(binding: stale)
            }
            parts.start = .replacingCycle
            let next = try KernelCycle(binding: candidate(parts))
            #expect(throws: KernelCycle.PreparationError.ownershipClaim(.predecessorNotRetired)) {
                _ = try candidate(parts)
            }
            _ = next.retire()
        }

        @Test func candidateRefusedPlanStillBindsAReadyClaimAndReport() throws {
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let rig = try CycleRig()
            let token = try RefusalCalling.claim(rig.events, &caller!)
            let overflow = cycleEvent(.max - 1, .rampTo(parameter: 0, value: 1, durationFrames: 4))
            #expect(rig.push(overflow, token, caller: &caller!) == .ok)
            #expect(rig.run(0, 64).0.pending == 1)
            let loss = rig.cycle.retire()
            let prepared = try candidate(candidateParts(rig), capacity: 1)
            let cycle = try KernelCycle(binding: prepared)
            #expect(cycle.carryReadmissionReport.planRefusal == .frameOverflow)
            #expect(cycle.carryReadmissionReport.planned == 0)
            #expect(cycle.carryReadmissionReport.pendingCarriedEvents == 0)
            #expect(cycle.inheritedRetirementCarry.count == 1 && cycle.unresolvedRetirementLoss == loss)
            #expect(cycle.unresolvedRetirementLoss.receiverStateMayBeStale)
            #expect(!prepared.cancel())
            #expect(throws: KernelCycle.PreparationError.candidateConsumed) {
                _ = try KernelCycle(binding: prepared)
            }
            #expect(cycle.run(blockStart: 64, frames: 64) { _, _ in
                Issue.record("refused plan emitted")
            }.status == .ok)
            _ = cycle.retire()
        }

        @Test(arguments: [1, 256, 4096])
        func candidatePendingCancelAndAbandonReleasePayloadOnControl(capacity: Int) throws {
            for cancel in [false, true] {
                weak var owner: NoteOwnership?
                weak var slots: TelemetrySlots<KernelCycleTelemetry>?
                weak var table: KernelAdmissionRefusals?
                var prepared: KernelCycleCandidate?
                do {
                    let rig = try CycleRig()
                    _ = rig.cycle.retire()
                    var parts = candidateParts(rig)
                    let output = try kernelCycleTelemetrySlots()
                    parts.telemetry = KernelCycleTelemetryOutput(slots: output, slot: 0, clockGeneration: 0)
                    owner = rig.ownership
                    slots = output
                    table = parts.admissionRefusals
                    prepared = try candidate(parts, capacity: capacity)
                }
                withExtendedLifetime(prepared) {
                    #expect(owner != nil && slots != nil && table != nil)
                }
                if cancel {
                    let alias = try #require(prepared)
                    #expect(alias.cancel())
                    withExtendedLifetime(alias) { #expect(owner == nil && slots == nil && table == nil) }
                    #expect(!alias.cancel())
                }
                prepared = nil
                #expect(owner == nil && slots == nil && table == nil)
            }
        }

        @Test(arguments: [1, 256, 4096])
        func candidateRefusedBindClearsPayloadEvenWhileTerminalAliasesLive(capacity: Int) throws {
            weak var owner: NoteOwnership?
            weak var slots: TelemetrySlots<KernelCycleTelemetry>?
            var loser: KernelCycleCandidate?
            do {
                let rig = try CycleRig()
                _ = rig.cycle.retire()
                var parts = candidateParts(rig)
                let output = try kernelCycleTelemetrySlots()
                parts.telemetry = KernelCycleTelemetryOutput(slots: output, slot: 0, clockGeneration: 0)
                slots = output
                owner = rig.ownership
                loser = try candidate(parts, capacity: capacity)
                let winner = try KernelCycle(binding: candidate(parts, capacity: capacity))
                _ = winner.retire()
            }
            let alias = try #require(loser)
            #expect(owner != nil && slots != nil)
            #expect(throws: KernelCycle.PreparationError.ownershipClaim(.claimRaced)) {
                _ = try KernelCycle(binding: alias)
            }
            withExtendedLifetime(loser) { #expect(owner == nil && slots == nil) }
            #expect(!alias.cancel())
            loser = nil
            #expect(throws: KernelCycle.PreparationError.candidateConsumed) {
                _ = try KernelCycle(binding: alias)
            }
        }

        @Test(arguments: [1, 256, 4096])
        func candidateTerminalAliasesDoNotRetainCycleOrRevokeItsClaim(capacity: Int) throws {
            weak var owner: NoteOwnership?
            weak var observedCycle: KernelCycle?
            var cycle: KernelCycle?
            var prepared: KernelCycleCandidate?
            do {
                let rig = try CycleRig()
                _ = rig.cycle.retire()
                owner = rig.ownership
                prepared = try candidate(candidateParts(rig), capacity: capacity)
                cycle = try KernelCycle(binding: #require(prepared))
                observedCycle = cycle
            }
            let alias = try #require(prepared)
            #expect(!alias.cancel())
            prepared = nil
            // Cancelling/dropping the consumed candidate cannot release a successful claim.
            #expect(NoteOwnership.cycleClaimRefusal(try #require(owner).cycleClaimState(), fresh: false)
                    == .predecessorNotRetired)
            #expect(cycle?.retire() == KernelRetirementLoss())
            #expect(cycle?.inheritedRetirementLoss == KernelRetirementLoss())
            withExtendedLifetime(cycle) { #expect(owner != nil && observedCycle != nil) }
            cycle = nil
            withExtendedLifetime(alias) { #expect(owner == nil && observedCycle == nil) }
            #expect(!alias.cancel())
            #expect(throws: KernelCycle.PreparationError.candidateConsumed) {
                _ = try KernelCycle(binding: alias)
            }
        }

        @Test func candidateLastAliasDestructionCannotReleaseSuccessfulClaim() throws {
            let rig = try CycleRig()
            _ = rig.cycle.retire()
            weak var observed: KernelCycleCandidate?
            let cycle: KernelCycle
            do {
                let prepared = try candidate(candidateParts(rig))
                let alias = prepared
                observed = prepared
                cycle = try KernelCycle(binding: alias)
                #expect(!prepared.cancel())
            }
            #expect(observed == nil)
            #expect(NoteOwnership.cycleClaimRefusal(rig.ownership.cycleClaimState(), fresh: false)
                    == .predecessorNotRetired)
            #expect(cycle.run(blockStart: 0, frames: 64) { _, _ in
                Issue.record("empty inheritance emitted")
            }.status == .ok)
            #expect(cycle.retire() == KernelRetirementLoss())
            let next = try KernelCycle(binding: candidate(candidateParts(rig)))
            _ = next.retire()
        }
    }
}
