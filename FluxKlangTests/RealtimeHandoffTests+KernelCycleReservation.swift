import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private func reservationParts(_ rig: CycleRig, owner: NoteOwnership? = nil) -> KernelCycleParts {
    KernelCycleParts(events: rig.events, faults: rig.faults, ownership: owner ?? rig.ownership,
                     safety: rig.safety, ramps: rig.ramps, admissionRefusals: rig.cycle.admissionRefusals)
}

private func reserve(_ parts: KernelCycleParts, capacity: Int) throws -> KernelCycleCandidate {
    try KernelCycleCandidate(parts, pulses: ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48),
                             blockCapacity: capacity, perLaneQuota: 64)
}

/// Full-capacity fixtures use the existing claim/release edge; every test binds the actual candidate/cycle.
private func reservationInheritance(_ rig: CycleRig, events: [KernelEvent]) throws -> KernelRetirementLoss {
    _ = rig.cycle.retire()
    let claim = try rig.ownership.claimForCycle(fresh: false, from: rig.ownership.cycleClaimState())
    var carry = KernelRetirementCarry()
    var loss = KernelRetirementLoss()
    for event in events {
        carry.record(event)
        loss.drop(event.payload)
    }
    rig.ownership.releaseCycleClaim(claim, loss: loss, carry: carry)
    return loss
}

extension RealtimeHandoffTests {
    /// New-API extent/reuse evidence. Trivial slots cannot expose per-slot runtime destruction counts;
    /// exact-I teardown and initialize-before-increment require independent source review.
    struct CycleReservation {
        @Test func reservationPreclaimEndpointsAndIndependentLiveBacking() throws {
            let rig = try CycleRig()
            _ = rig.cycle.retire()
            let state = rig.ownership.cycleClaimState()
            for capacity in [1, 256, 4_096] {
                let first = try reserve(reservationParts(rig), capacity: capacity)
                let second = try reserve(reservationParts(rig), capacity: capacity)
                let info = try #require(first.storageInfo)
                let other = try #require(second.storageInfo)
                #expect(info.reservedCapacity == min(256, capacity) && info.initializedCount == 0)
                #expect(other.reservedCapacity == info.reservedCapacity && other.initializedCount == 0)
                #expect(info.fingerprint != other.fingerprint)
                #expect(rig.ownership.cycleClaimState() == state)
                #expect(first.cancel() && first.storageInfo == nil)
                #expect(second.storageInfo == other && rig.ownership.cycleClaimState() == state)
                #expect(second.cancel())
            }
        }

        @Test func reservationBindingReusesBackingForEmptyFullCutAndOverflow() throws {
            let full = (0..<256).map {
                cycleEvent(Int64($0), .control(channel: 0, controller: 96, value: UInt32($0)))
            }
            let overflow = cycleEvent(.max - 1, .rampTo(parameter: 0, value: 1, durationFrames: 2))
            let invalid = cycleEvent(.max, .rampTo(parameter: 1, value: .nan, durationFrames: 1))
            // The overflowing survivor is beyond the cut, but must still refuse the entire plan.
            let fixtures = [[], full, full + [full[0]], [full[0], overflow, invalid]]
            for capacity in [1, 256, 4_096] {
                for (index, input) in fixtures.enumerated() {
                    let rig = try CycleRig()
                    let loss = try reservationInheritance(rig, events: input)
                    let prepared = try reserve(reservationParts(rig), capacity: capacity)
                    let pending = try #require(prepared.storageInfo)
                    let state = rig.ownership.cycleClaimState()
                    #expect(pending.initializedCount == 0)
                    let cycle = try KernelCycle(binding: prepared)
                    let ready = cycle.carryReadmissionStorageInfo
                    let count = index == 0 || index == 3 ? 0 : min(256, capacity)
                    let report = cycle.carryReadmissionReport
                    #expect(prepared.storageInfo == nil)
                    #expect(ready.fingerprint == pending.fingerprint) // All three allocations still live.
                    #expect(ready.reservedCapacity == pending.reservedCapacity && ready.initializedCount == count)
                    #expect(report.planned == count && report.pendingCarriedEvents == count)
                    #expect(report.planRefusal == (index == 3 ? .frameOverflow : nil))
                    #expect(report.invalidRamps == (index == 3 ? 1 : 0))
                    #expect(report.droppedAtRecord == (index == 2 ? 1 : 0) && report.superseded == 0)
                    #expect(report.cut == KernelRetirementLoss(
                        controls: index == 1 || index == 2 ? 256 - count : 0))
                    #expect(report.delivered == 0 && report.refused == 0 && report.recarried == 0)
                    #expect(report.supersededByReplacement == 0)
                    #expect(cycle.inheritedRetirementLoss == loss && cycle.unresolvedRetirementLoss == loss)
                    #expect(rig.ownership.cycleClaimState() != state)
                    // Full report equivalence through the delegating standalone compatibility path.
                    let standalone = KernelCarryReadmission(carry: cycle.inheritedRetirementCarry,
                                                           blockCapacity: capacity)
                    #expect(standalone.report == report && standalone.storageInfo.initializedCount == count)
                    #expect(standalone.storageInfo.fingerprint != ready.fingerprint)
                    _ = cycle.retire()
                    #expect(cycle.carryReadmissionStorageInfo == ready)
                }
            }
        }

        @Test func reservationStandaloneClampAndSealedExtent() {
            let event = cycleEvent(20, .program(channel: 0, program: 3, bank: 0))
            for capacity in [Int.min, 0, 1, 256, 4_096, Int.max] {
                for input in [[], [event]] {
                    let readmission = KernelCarryReadmission(
                        carry: KernelRetirementCarryTests.carry(input), blockCapacity: capacity)
                    let info = readmission.storageInfo
                    #expect(info.reservedCapacity == min(256, max(1, capacity)))
                    #expect(info.initializedCount == input.count && readmission.report.planned == input.count)
                    readmission.consumeNext(delivered: true)
                    #expect(readmission.next == nil && readmission.report.pendingCarriedEvents == 0)
                    #expect(readmission.storageInfo == info)
                }
            }
        }

        @Test func reservationClaimLosersStayTerminalAndCannotTouchWinner() throws {
            for retireBeforeBind in [false, true] {
                let rig = try CycleRig()
                let event = cycleEvent(100, .program(channel: 0, program: 2, bank: 0))
                _ = try reservationInheritance(rig, events: [event])
                let parts = reservationParts(rig)
                let prepared = try reserve(parts, capacity: 1)
                let loser = try reserve(parts, capacity: 256)
                let alias = loser
                let pending = try #require(prepared.storageInfo)
                let losing = try #require(loser.storageInfo)
                #expect(losing.initializedCount == 0 && pending.fingerprint != losing.fingerprint)
                let winner = try KernelCycle(binding: prepared)
                #expect(winner.carryReadmissionStorageInfo.fingerprint == pending.fingerprint)
                if retireBeforeBind { _ = winner.retire() }
                let info = winner.carryReadmissionStorageInfo
                let report = winner.carryReadmissionReport
                let state = rig.ownership.cycleClaimState()
                let refusal: NoteOwnership.CycleClaimRefusal =
                    retireBeforeBind ? .claimRaced : .predecessorNotRetired
                #expect(throws: KernelCycle.PreparationError.ownershipClaim(refusal)) {
                    _ = try KernelCycle(binding: loser)
                }
                #expect(alias.storageInfo == nil && !alias.cancel())
                #expect(winner.carryReadmissionStorageInfo == info && winner.carryReadmissionReport == report)
                #expect(rig.ownership.cycleClaimState() == state)
                _ = winner.retire()
                let next = try KernelCycle(binding: reserve(parts, capacity: 1))
                let nextInfo = next.carryReadmissionStorageInfo
                withExtendedLifetime(winner) {
                    #expect(nextInfo.fingerprint != info.fingerprint) // Retired winner remains live.
                }
                #expect(throws: KernelCycle.PreparationError.candidateConsumed) {
                    _ = try KernelCycle(binding: alias)
                }
                #expect(next.carryReadmissionStorageInfo == nextInfo && nextInfo.initializedCount == 1)
                _ = next.retire()
            }
        }

        @Test func reservationCancelAndAbandonReleasePendingPayload() throws {
            for cancel in [false, true] {
                weak var owner: NoteOwnership?
                weak var observed: KernelCycleCandidate?
                var pending: KernelCycleCandidate?
                do {
                    let rig = try CycleRig()
                    _ = rig.cycle.retire()
                    owner = rig.ownership
                    pending = try reserve(reservationParts(rig), capacity: 4_096)
                    observed = pending
                }
                #expect(pending?.storageInfo?.initializedCount == 0 && owner != nil)
                if cancel {
                    let alias = try #require(pending)
                    #expect(alias.cancel() && alias.storageInfo == nil)
                    withExtendedLifetime(alias) { #expect(owner == nil) }
                    #expect(throws: KernelCycle.PreparationError.candidateCancelled) {
                        _ = try KernelCycle(binding: alias)
                    }
                }
                pending = nil
                #expect(owner == nil && observed == nil)
            }
        }

        @Test func reservationExtentSurvivesPartialFullConsumptionAndRetirement() throws {
            for consumeAll in [false, true] {
                let rig = try CycleRig()
                let first = cycleEvent(100, .control(channel: 0, controller: 7, value: 3))
                let last = cycleEvent(200, .program(channel: 0, program: 2, bank: 0))
                _ = try reservationInheritance(rig, events: [first, last])
                var candidate: KernelCycleCandidate? = try reserve(reservationParts(rig), capacity: 256)
                var cycle: KernelCycle? = try KernelCycle(binding: #require(candidate))
                weak var observed: KernelCycle?
                observed = cycle
                candidate = nil
                let info = try #require(cycle).carryReadmissionStorageInfo
                #expect(info.initializedCount == 2)
                var emitted: [KernelEvent] = []
                _ = cycle?.run(blockStart: 64, frames: 64) { event, _ in emitted.append(event) }
                #expect(emitted == [first] && cycle?.carryReadmissionReport.pendingCarriedEvents == 1)
                #expect(cycle?.carryReadmissionStorageInfo == info)
                if consumeAll {
                    _ = cycle?.run(blockStart: 128, frames: 128) { event, _ in emitted.append(event) }
                    #expect(emitted == [first, last] && cycle?.carryReadmissionReport.pendingCarriedEvents == 0)
                }
                _ = cycle?.retire()
                #expect(cycle?.carryReadmissionReport.recarried == (consumeAll ? 0 : 1))
                #expect(cycle?.carryReadmissionStorageInfo == info && observed != nil)
                cycle = nil
                #expect(observed == nil) // Control-owned lifetime, not a per-slot destructor observation.
            }
        }

        @Test func reservationSupersessionAndRefusalDoNotShrinkInitializedExtent() {
            let first = cycleEvent(10, .control(channel: 0, controller: 7, value: 3))
            let last = cycleEvent(20, .program(channel: 0, program: 2, bank: 0))
            let readmission = KernelCarryReadmission(
                carry: KernelRetirementCarryTests.carry([first, last]), blockCapacity: 256)
            let info = readmission.storageInfo
            readmission.supersede(by: first)
            #expect(readmission.report.supersededByReplacement == 1)
            #expect(readmission.next == last && readmission.storageInfo == info)
            readmission.consumeNext(delivered: false)
            #expect(readmission.report.refused == 1 && readmission.report.pendingCarriedEvents == 0)
            readmission.retire(coveredBy: KernelBlockBuffer(capacity: 1)) { _ in Issue.record("unexpected carry") }
            #expect(readmission.storageInfo == info && info.initializedCount == 2)
        }
    }
}
