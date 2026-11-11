import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// #364 E5c, slice KCR2: planning rules of the re-admission (`KernelCarryReadmission.init`) that no existing
// re-admission test fully pinned (`readmissionSkipsInvalidRampsAndKeepsTheRest` covers part of the invalid-ramp
// rule): supersede keys, invalid ramps, the overflow bound, the cut by kind and the recorded order on a frame tie.

private func control(_ controller: UInt8, _ value: UInt32 = 9) -> KernelEventPayload {
    .control(channel: 0, controller: controller, value: value)
}

private func program(_ channel: UInt8, _ program: UInt8, bank: UInt16 = 0) -> KernelEventPayload {
    .program(channel: channel, program: program, bank: bank)
}

private func ramp(_ parameter: UInt32, _ value: Float, _ duration: Int64 = 0) -> KernelEventPayload {
    .rampTo(parameter: parameter, value: value, durationFrames: duration)
}

/// A `.replacingCycle` cycle of `blockCapacity` on `rig`'s parts; the caller retires the previous cycle first.
private func replacement(of rig: CycleRig, blockCapacity: Int = 64) throws -> KernelCycle {
    let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership, safety: rig.safety,
                                 ramps: rig.ramps, admissionRefusals: rig.cycle.admissionRefusals)
    return try KernelCycle(parts, pulses: ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48),
                           blockCapacity: blockCapacity, perLaneQuota: 64)
}

/// Pushes `pending` through `token`, runs `rig.cycle` over [0, 64) so they stay buffered, and retires it.
private func retire(_ rig: CycleRig, _ token: ProducerToken, pending: [KernelEvent]) {
    for event in pending { #expect(rig.push(event, token) == .ok) }
    #expect(rig.run(0, 64).0.pending == pending.count)
    _ = rig.cycle.retire()
}

/// Every emission of one block of `cycle` over `[start, start + 64)`.
private func block(_ cycle: KernelCycle, _ start: Int64) -> [CycleEmission] {
    var emitted: [CycleEmission] = []
    _ = cycle.run(blockStart: start, frames: 64) { emitted.append(CycleEmission(event: $0, frame: $1)) }
    return emitted
}

/// `events`, each emitted at its own frame.
private func emissions(_ events: [KernelEvent]) -> [CycleEmission] {
    events.map { CycleEmission(event: $0, frame: $0.frame) }
}

private func stateful(_ loss: KernelRetirementLoss) -> [Int] { [loss.controls, loss.programs, loss.ramps] }

extension RealtimeHandoffTests {
    /// How a replacement plans the carry it inherited, before render drains it (the preparation rules on
    /// `KernelCarryReadmission`).
    struct CycleCarryReadmissionPlan {
        /// Programs supersede per (scope, channel), whatever the program and bank: the scope-0 channel-0 `program`
        /// at 100 is replaced by the one at 120 (program 7, bank 8), while the channel-1 one and the scope-1
        /// channel-0 one are kept; the replaced one resolves with its survivor. Kills: the program or bank in the
        /// key; the scope or channel left out of it.
        @Test func readmissionSupersedesProgramsPerScopeAndChannel() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            let pending = [cycleEvent(100, program(0, 1, bank: 1)), cycleEvent(110, program(1, 9, bank: 9)),
                           cycleEvent(120, program(0, 7, bank: 8)), cycleEvent(125, program(0, 2, bank: 2), scope: 1)]
            retire(rig, token, pending: pending)
            let next = try replacement(of: rig)
            let report = next.carryReadmissionReport
            #expect(report.planned == 3 && report.superseded == 1)
            #expect(block(next, 64) == emissions(Array(pending.dropFirst())))
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// Ramps supersede per parameter, whatever the value and duration, and no kind supersedes another: all in
        /// scope 0, the ramp on parameter 1 at 110 replaces the one at 100, while the ramp on parameter 2, a CC0 and a
        /// channel-0 `program` and a ramp on parameter 0 (each keyed by number 0 where it has one) are all kept.
        /// The scope half of the (scope, parameter) key is pinned by
        /// `readmissionCrossScopeRampsOnOneParameterApplyInFrameOrder`, not here.
        /// Kills: the parameter left out of a ramp's key; keys of different kinds colliding.
        @Test func readmissionSupersedesRampsPerParameterAndNeverAcrossKinds() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            let pending = [cycleEvent(100, ramp(1, 1, 5)), cycleEvent(105, ramp(2, 0.5, 6)),
                           cycleEvent(110, ramp(1, 0.25, 7)), cycleEvent(115, control(0)),
                           cycleEvent(120, program(0, 5)), cycleEvent(125, ramp(0, 0.75))]
            retire(rig, token, pending: pending)
            let next = try replacement(of: rig)
            let report = next.carryReadmissionReport
            #expect(report.planned == 5 && report.superseded == 1)
            #expect(block(next, 64) == emissions(Array(pending.dropFirst())))
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// Every invalid carried ramp (NaN, ±infinity, a negative duration down to `Int64.min`) is removed before
        /// supersession and the overflow check: a later invalid ramp does not replace a valid one (parameters 0 and
        /// 2), an earlier one adds no weight to the valid one after it (parameter 1, so it stays unresolved), and an
        /// invalid ramp whose completion would overflow `Int64` does not refuse the plan. The largest finite values
        /// and a zero duration are valid. Kills: only NaN or one negative duration treated as invalid; invalid ramps
        /// superseding or superseded; the overflow checked before the removal.
        @Test func readmissionRemovesEveryInvalidRampBeforePlanning() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            let valid = [cycleEvent(100, ramp(0, 0.5)), cycleEvent(115, ramp(1, 0.25)),
                         cycleEvent(120, ramp(2, .greatestFiniteMagnitude, 1)),
                         cycleEvent(124, ramp(3, -.greatestFiniteMagnitude, 1))]
            let pending = [valid[0], cycleEvent(105, ramp(0, .infinity)), cycleEvent(110, ramp(1, .nan)), valid[1],
                           valid[2], cycleEvent(122, ramp(3, 1, Int64.min)), valid[3],
                           cycleEvent(126, ramp(2, -.infinity)), cycleEvent(Int64.max - 10, ramp(2, .nan, 100))]
            retire(rig, token, pending: pending)
            let next = try replacement(of: rig)
            let report = next.carryReadmissionReport
            #expect(report.planRefusal == nil && report.invalidRamps == 5)
            #expect(report.planned == 4 && report.superseded == 0)
            #expect(block(next, 64) == emissions(valid))
            #expect(next.carryReadmissionReport.refused == 0)
            #expect(stateful(next.unresolvedRetirementLoss) == [0, 0, 5])
        }

        /// The overflow refusal is exact: a carried ramp at `Int64.max - 10` lasting 10 frames completes at
        /// `Int64.max` and is planned; lasting 11 frames it refuses the plan (`.frameOverflow`), so nothing is
        /// planned. Kills: an off-by-one completion bound.
        @Test func readmissionRefusesOnlyARampCompletionPastInt64Max() throws {
            for (duration, refused) in [(Int64(10), false), (11, true)] {
                let rig = try CycleRig()
                let token = try #require(rig.events.claimProducer())
                retire(rig, token, pending: [cycleEvent(Int64.max - 10, ramp(1, 1, duration))])
                let report = try replacement(of: rig).carryReadmissionReport
                let expected: KernelCarryRefusal? = refused ? .frameOverflow : nil
                #expect(report.planRefusal == expected && report.planned == (refused ? 0 : 1), "duration \(duration)")
            }
        }

        /// The capacity cut keeps the earliest survivors and counts the rest by kind: a `control`, a `program` and
        /// two ramps fit a 4-event replacement exactly (nothing cut); a 2-event one keeps the `control` and the
        /// `program` and cuts both ramps, which stay unresolved. Kills: an off-by-one capacity; a cut counted as the
        /// wrong kind.
        @Test func readmissionCapacityCutCountsEachKind() throws {
            let pending = [cycleEvent(100, control(7)), cycleEvent(110, program(0, 5)), cycleEvent(120, ramp(1, 1)),
                           cycleEvent(125, ramp(2, 0.5))]
            for capacity in [4, 2] {
                let rig = try CycleRig()
                let token = try #require(rig.events.claimProducer())
                retire(rig, token, pending: pending)
                let next = try replacement(of: rig, blockCapacity: capacity)
                let report = next.carryReadmissionReport
                #expect(report.planned == capacity && stateful(report.cut) == [0, 0, 4 - capacity])
                #expect(report.cut.stateful == 4 - capacity)
                #expect(block(next, 64) == emissions(Array(pending.prefix(capacity))))
                #expect(stateful(next.unresolvedRetirementLoss) == [0, 0, 4 - capacity])
            }
        }

        /// On a frame tie the re-admission preserves the order the retiring cycle recorded; it does not sort by lane
        /// itself. A `control` (state lane, sequence 9) and a ramp (content lane, sequence 1) at 100, pushed in
        /// either order, are recorded `control` first because that is the retiring buffer's (frame, lane, producer
        /// lane, sequence) order; the re-admission then keeps that recorded order. Kills: ties re-ordered by
        /// sequence; the recorded order reversed on a tie.
        @Test func readmissionKeepsTheRetiringBuffersLaneOrderOnATie() throws {
            let state = cycleEvent(100, control(7), sequence: 9)
            let content = cycleEvent(100, ramp(1, 1), sequence: 1)
            for pending in [[content, state], [state, content]] {
                let rig = try CycleRig()
                let token = try #require(rig.events.claimProducer())
                retire(rig, token, pending: pending)
                let next = try replacement(of: rig)
                #expect(next.inheritedRetirementCarry.events == [state, content])
                #expect(block(next, 64) == emissions([state, content]))
            }
        }
    }
}
