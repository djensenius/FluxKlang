import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// #364 E5c, slice KCR1: a `.replacingCycle` replacement re-admits the carry it inherited (`KernelCarryReadmission`).

private let programFive = KernelEventPayload.program(channel: 0, program: 5, bank: 0)

private func control(_ controller: UInt8, _ value: UInt32 = 9, channel: UInt8 = 0) -> KernelEventPayload {
    .control(channel: channel, controller: controller, value: value)
}

private func ramp(_ parameter: UInt32, _ value: Float, _ duration: Int64 = 0) -> KernelEventPayload {
    .rampTo(parameter: parameter, value: value, durationFrames: duration)
}

/// A `.replacingCycle` cycle of `blockCapacity` on `rig`'s parts; the caller retires the previous cycle first.
private func replacement(of rig: CycleRig, blockCapacity: Int = 64, perLaneQuota: Int = 64) throws -> KernelCycle {
    let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership, safety: rig.safety,
                                 ramps: rig.ramps, admissionRefusals: rig.cycle.admissionRefusals)
    return try KernelCycle(parts, pulses: ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48),
                           blockCapacity: blockCapacity, perLaneQuota: perLaneQuota)
}

/// Pushes `pending` through `token`, runs `rig.cycle` over [0, 64) so they stay buffered, and retires it.
@discardableResult
private func retire(_ rig: CycleRig, _ token: ProducerToken, pending: [(Int64, KernelEventPayload)],
                    scope: UInt32 = 0) -> KernelRetirementLoss {
    for (frame, payload) in pending { #expect(rig.push(cycleEvent(frame, payload, scope: scope), token) == .ok) }
    #expect(rig.run(0, 64).0.pending == pending.count)
    return rig.cycle.retire()
}

/// Runs one block of `cycle` and returns its result with every emission and its dispatch frame.
private func block(_ cycle: KernelCycle, _ start: Int64, frames: Int64 = 64) -> (KernelCycleResult, [CycleEmission]) {
    var emitted: [CycleEmission] = []
    let result = cycle.run(blockStart: start, frames: frames) { emitted.append(CycleEmission(event: $0, frame: $1)) }
    return (result, emitted)
}

private func at(_ frame: Int64, _ payload: KernelEventPayload, dispatched: Int64? = nil,
                scope: UInt32 = 0) -> CycleEmission {
    CycleEmission(event: cycleEvent(frame, payload, scope: scope), frame: dispatched ?? frame)
}

private func stateful(_ loss: KernelRetirementLoss) -> [Int] { [loss.controls, loss.programs, loss.ramps] }

extension RealtimeHandoffTests {
    /// Re-admission of the inherited retirement carry: frames, ordering against the replacement's own lanes, capacity
    /// and accounting (`unresolvedRetirementLoss`, `carryReadmissionReport`).
    struct CycleCarryReadmission {
        /// Issue #364 acceptance (a): a `program` at 128 drained during [0, 64) and pending at retirement is emitted
        /// by the replacement at 128, not earlier; it stays unresolved until then. Kills: no re-admission; emission
        /// at the first block; the loss resolved before delivery.
        @Test func readmissionEmitsTheProgramAt128AndThenResolvesIt() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            let loss = retire(rig, token, pending: [(128, programFive)])
            let next = try replacement(of: rig)
            #expect(next.carryReadmissionReport.planned == 1 && next.unresolvedRetirementLoss == loss)
            #expect(next.carryReadmissionReport.pendingCarriedEvents == 1)
            #expect(block(next, 64).1.isEmpty && next.unresolvedRetirementLoss.receiverStateMayBeStale)
            let (result, emitted) = block(next, 128)
            #expect(emitted == [at(128, programFive)] && result.dispatched == 0 && result.pending == 0)
            #expect(next.carryReadmissionReport.delivered == 1 && next.inheritedRetirementLoss == loss)
            #expect(next.carryReadmissionReport.pendingCarriedEvents == 0)
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// Acceptance (a), already due: after a gap of several blocks, a carried `control` (100) and a carried ramp
        /// (110, 128 frames) dispatch at the replacement's first block start, 320; the ramp restarts there with its
        /// full duration (halfway after 64 frames). Kills: a due event kept at its old frame or dropped late.
        @Test func readmissionClampsAlreadyDueEventsToTheFirstBlock() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            retire(rig, token, pending: [(100, control(7)), (110, ramp(1, 1, 128))])
            let next = try replacement(of: rig)
            let (_, emitted) = block(next, 320)
            #expect(emitted == [at(100, control(7), dispatched: 320), at(110, ramp(1, 1, 128), dispatched: 320)])
            #expect(next.parameterValue(1) == 0.5 && !next.unresolvedRetirementLoss.receiverStateMayBeStale)
        }

        /// A smaller replacement (`blockCapacity` 4) re-admits at most 4 of 6 carried `control`s, the earliest; the
        /// cut 2 stay unresolved (stale). A larger one re-admits all 6. Kills: capacity ignored; a cut not counted.
        @Test func readmissionCapacityFollowsTheReplacementsBlockCapacity() throws {
            for (capacity, kept) in [(4, 4), (300, 6)] {
                let rig = try CycleRig(laneCapacity: 32)
                let token = try #require(rig.events.claimProducer())
                let pending = (0..<6).map { (Int64(100 + $0), control(UInt8($0 + 1))) }
                retire(rig, token, pending: pending)
                let next = try replacement(of: rig, blockCapacity: capacity)
                #expect(next.carryReadmissionCapacity == min(capacity, KernelRetirementCarry.capacity))
                let (_, emitted) = block(next, 64)
                #expect(emitted == pending.prefix(kept).map { at($0.0, $0.1) })
                let report = next.carryReadmissionReport
                #expect(report.planned == kept && report.delivered == kept && report.cut.controls == 6 - kept)
                #expect(stateful(next.unresolvedRetirementLoss) == [6 - kept, 0, 0])
                #expect(next.unresolvedRetirementLoss.receiverStateMayBeStale == (kept < 6))
            }
        }

        /// 300 distinct `control`s: the carry keeps 256 (44 never recorded) and a 300-event replacement re-admits all
        /// 256 over five blocks; exactly the 44 stay unresolved. Three writers of one key re-admit as one event that
        /// resolves all three. Kills: droppedAtRecord resolved; superseded carried events left unresolved.
        @Test func readmissionAccountsOverflowAndSupersededCarriedEvents() throws {
            let rig = try CycleRig(laneCapacity: 320, blockCapacity: 300, perLaneQuota: 300)
            let token = try #require(rig.events.claimProducer())
            var pending: [(Int64, KernelEventPayload)] = []
            for index in 0..<300 {
                let controller = UInt8(index % 128)
                let channel = UInt8(index / 128)
                pending.append((1_000 + Int64(index), control(controller, channel: channel)))
            }
            #expect(retire(rig, token, pending: pending).controls == 300)
            let next = try replacement(of: rig, blockCapacity: 300, perLaneQuota: 300)
            var delivered = 0
            for start in stride(from: Int64(960), to: 1_280, by: 64) { delivered += block(next, start).1.count }
            let report = next.carryReadmissionReport
            #expect(delivered == 256 && report.droppedAtRecord == 44 && report.delivered == 256)
            #expect(stateful(next.unresolvedRetirementLoss) == [44, 0, 0])

            let other = try CycleRig()
            let writer = try #require(other.events.claimProducer())
            retire(other, writer, pending: [(100, control(7, 1)), (110, control(7, 2)), (120, control(7, 3))])
            let single = try replacement(of: other)
            #expect(block(single, 64).1 == [at(120, control(7, 3))])
            #expect(single.carryReadmissionReport.superseded == 2 && single.carryReadmissionReport.delivered == 1)
            #expect(single.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// Ordering (timeline): carried and own events apply by original frame, as one cycle would have applied them.
        /// An own `program` on channel 0 at 100 does not supersede the carried one at 128 (later state, emitted after
        /// it); carried and own `control`s interleave by frame and a carried event precedes an own one of the same
        /// frame. Kills: own state discarding later carried state; carried events appended after the block.
        @Test func readmissionMergesInTimelineOrder() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            let programOne = KernelEventPayload.program(channel: 1, program: 3, bank: 0)
            retire(rig, token, pending: [(128, programFive), (140, control(7)), (150, programOne)])
            let next = try replacement(of: rig)
            let programNine = KernelEventPayload.program(channel: 0, program: 9, bank: 0)
            for (frame, payload) in [(Int64(100), programNine), (135, control(8)), (150, control(9))] {
                #expect(rig.push(cycleEvent(frame, payload), token) == .ok)
            }
            #expect(block(next, 64).1 == [at(100, programNine)])
            let (result, emitted) = block(next, 128)
            #expect(emitted == [at(128, programFive), at(135, control(8)), at(140, control(7)), at(150, programOne),
                                at(150, control(9))])
            #expect(result.dispatched == 2)
            let report = next.carryReadmissionReport
            #expect(report.delivered == 3 && report.supersededByReplacement == 0 && report.pendingCarriedEvents == 0)
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// A same-frame tie on one target: the carried `control` 7 (value 1) is emitted first, then the own one
        /// (value 2), which is the state left; nothing is superseded. Kills: the tie broken towards carried state.
        @Test func readmissionSameFrameSameTargetEmitsCarriedThenOwn() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            retire(rig, token, pending: [(150, control(7, 1))])
            let next = try replacement(of: rig)
            #expect(rig.push(cycleEvent(150, control(7, 2)), token) == .ok)
            #expect(block(next, 128).1 == [at(150, control(7, 1)), at(150, control(7, 2))])
            let report = next.carryReadmissionReport
            #expect(report.delivered == 1 && report.supersededByReplacement == 0)
        }

        /// Two carried ramps on parameter 2, scope 0 at 100 (to 1) and scope 1 at 110 (to 0.25), are both re-admitted
        /// in frame order (the carry keys ramps per scope), so the later one is the parameter's state. Kills: a
        /// cross-scope ramp superseded inside the carry; frame order lost.
        @Test func readmissionCrossScopeRampsOnOneParameterApplyInFrameOrder() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(100, ramp(2, 1)), token) == .ok)
            #expect(rig.push(cycleEvent(110, ramp(2, 0.25), scope: 1), token) == .ok)
            #expect(rig.run(0, 64).0.pending == 2)
            #expect(rig.cycle.retire().ramps == 2)
            let next = try replacement(of: rig)
            #expect(block(next, 64).1 == [at(100, ramp(2, 1)), at(110, ramp(2, 0.25), scope: 1)])
            #expect(next.parameterValue(2) == 0.25 && next.carryReadmissionReport.delivered == 2)
        }

        /// Across the retire boundary, by target and timeline: pending at the replacement's `retire()`, an own scope-1
        /// ramp on parameter 2 at 6,000 covers the carried scope-0 one at 5,000 (`RampSlots` is shared), which is
        /// superseded, not carried; an own scope-1 `control` 7 does not cover the carried scope-0 one; an own
        /// `program` at 4,000 does not cover the carried one at 5,000 (later state), so both are carried, own first,
        /// and the next hop keeps the later. Kills: a covered slot carried again; a later carried event superseded.
        @Test func readmissionRetireSupersedesCoveredSlotsAndCarriesTheRestAfterOwn() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            let programSix = KernelEventPayload.program(channel: 0, program: 6, bank: 0)
            retire(rig, token, pending: [(5_000, ramp(2, 1)), (5_000, control(7)), (5_000, programFive)])
            let next = try replacement(of: rig)
            let own = [cycleEvent(4_000, programSix), cycleEvent(6_000, ramp(2, 0.25), scope: 1),
                       cycleEvent(6_000, control(7, 4), scope: 1)]
            for event in own { #expect(rig.push(event, token) == .ok) }
            #expect(block(next, 64).1.isEmpty)
            #expect(stateful(next.retire()) == [2, 2, 1])
            let report = next.carryReadmissionReport
            #expect(report.supersededByReplacement == 1 && report.recarried == 2 && report.pendingCarriedEvents == 0)
            #expect(stateful(next.unresolvedRetirementLoss) == [1, 1, 0])
            let third = try replacement(of: rig)
            #expect(third.inheritedRetirementCarry.events == [own[0], own[2], own[1], cycleEvent(5_000, control(7)),
                                                              cycleEvent(5_000, programFive)])
            #expect(block(third, 4_992).1 == [at(5_000, control(7)), at(5_000, programFive)])
            #expect(third.carryReadmissionReport.superseded == 1)
        }

        /// Overflow at the replacement's `retire()`: 200 own pending `control`s and 256 pending carried ones exceed
        /// the 256-event carry. Own (newer) events are recorded first; the 10 carried ones an own event covers are
        /// superseded; of the other 246, 56 fit and 190 are dropped at record. All 446 are counted in the loss.
        /// Kills: carried events crowding out own ones; a covered slot counted as loss; an unrecorded event uncounted.
        @Test func readmissionRetireOverflowRecordsOwnFirstAndCountsTheRest() throws {
            let rig = try CycleRig(laneCapacity: 320, blockCapacity: 300, perLaneQuota: 300)
            let token = try #require(rig.events.claimProducer())
            var carried: [(Int64, KernelEventPayload)] = []
            for index in 0..<256 {
                carried.append((10_000 + Int64(index), control(UInt8(index % 128), channel: UInt8(index / 128))))
            }
            retire(rig, token, pending: carried)
            let next = try replacement(of: rig, blockCapacity: 300, perLaneQuota: 300)
            #expect(next.carryReadmissionReport.planned == 256)
            for index in 0..<200 {
                let channel = UInt8(index < 10 ? 0 : 2 + index / 128)
                let event = cycleEvent(20_000 + Int64(index), control(UInt8(index % 128), channel: channel))
                #expect(rig.push(event, token) == .ok)
            }
            #expect(block(next, 64).0.pending == 200)
            #expect(next.retire().controls == 446)
            let report = next.carryReadmissionReport
            #expect(report.supersededByReplacement == 10 && report.recarried == 246 && report.pendingCarriedEvents == 0)
            let third = try replacement(of: rig, blockCapacity: 300, perLaneQuota: 300)
            let inherited = third.inheritedRetirementCarry
            #expect(inherited.count == 256 && inherited.droppedForCapacity == 190)
            let events = inherited.events
            try #require(events.count == 256)
            #expect(events[0].frame == 20_000 && events[199].frame == 20_199 && events[200].frame == 10_010)
            #expect(third.inheritedRetirementLoss.controls == 446)
        }

        /// A `.freshFanIn` cycle inherits nothing and re-admits nothing.
        @Test func readmissionFreshFanInInheritsNothing() throws {
            let report = try CycleRig().cycle.carryReadmissionReport
            #expect(report == KernelCarryReadmissionReport(
                planRefusal: nil, planned: 0, invalidRamps: 0, cut: KernelRetirementLoss(), superseded: 0,
                droppedAtRecord: 0, delivered: 0, supersededByReplacement: 0, refused: 0, recarried: 0,
                pendingCarriedEvents: 0))
            #expect(try CycleRig().cycle.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// A silenced replacement re-admits nothing: panic-muted, its carried `program` waits and is emitted (late,
        /// at 192) by the next unmuted block; latched, it is still pending at retirement, so it is counted in that
        /// loss, carried again and re-admitted by the next replacement. Kills: re-admission while silenced; a pending
        /// carried event lost at retirement.
        @Test func readmissionWaitsWhileSilencedAndIsCarriedAgain() throws {
            for faulted in [false, true] {
                let rig = try CycleRig()
                let token = try #require(rig.events.claimProducer())
                retire(rig, token, pending: [(100, programFive)])
                let next = try replacement(of: rig)
                if faulted {
                    #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
                } else {
                    #expect(rig.safety.request(.panic, scope: 0) == .ok)
                }
                let (silenced, quiet) = block(next, 128)
                #expect(silenced.status != .ok && quiet.isEmpty && next.unresolvedRetirementLoss.programs == 1)
                if !faulted {
                    #expect(block(next, 192).1 == [at(100, programFive, dispatched: 192)])
                    continue
                }
                #expect(next.retire().programs == 1 && next.carryReadmissionReport.recarried == 1)
                let third = try replacement(of: rig)
                #expect(third.inheritedRetirementCarry.events == [cycleEvent(100, programFive)])
                #expect(third.carryReadmissionReport.planned == 1)
            }
        }

        /// A repeated `retire()` of a replacement with a carried event pending carries it once: the second returns no
        /// loss, a `run` after it emits nothing, and the next replacement inherits one event. Kills: a double carry.
        @Test func readmissionRepeatedRetireCarriesOnce() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            retire(rig, token, pending: [(5_000, programFive)])
            let next = try replacement(of: rig)
            #expect(block(next, 64).1.isEmpty && next.carryReadmissionReport.pendingCarriedEvents == 1)
            #expect(next.retire().programs == 1 && next.retire() == KernelRetirementLoss())
            let (stray, emitted) = block(next, 4_992)
            #expect(stray.retired && emitted.isEmpty && next.carryReadmissionReport.recarried == 1)
            #expect(next.carryReadmissionReport.pendingCarriedEvents == 0)
            let third = try replacement(of: rig)
            #expect(third.inheritedRetirementCarry.count == 1 && third.inheritedRetirementLoss.programs == 1)
            #expect(block(third, 4_992).1 == [at(5_000, programFive)])
        }

        /// Invalid ramps (a NaN value, a negative duration) are removed before planning, so the carried
        /// `program` is still re-admitted; the two ramps stay unresolved. Kills: one invalid ramp refusing the plan.
        @Test func readmissionSkipsInvalidRampsAndKeepsTheRest() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            retire(rig, token, pending: [(100, ramp(1, .nan)), (110, programFive), (120, ramp(3, 1, -5))])
            let next = try replacement(of: rig)
            #expect(block(next, 64).1 == [at(110, programFive)])
            let report = next.carryReadmissionReport
            #expect(report.invalidRamps == 2 && report.planned == 1 && report.planRefusal == nil)
            #expect(stateful(next.unresolvedRetirementLoss) == [0, 0, 2])
        }

        /// The takeover releases the retired cycle's sounding note at the first block start, before the carried
        /// `program`, which keeps its own frame. Kills: re-admission held back by the takeover.
        @Test func readmissionRunsBehindTheTakeoverRelease() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(10, .noteOn(channel: 0, note: 60, velocity: 90)), token) == .ok)
            retire(rig, token, pending: [(100, programFive)])
            let next = try replacement(of: rig)
            let release = CycleEmission(event: KernelEvent(frame: 64, scope: 0, sequence: KernelCycle.releaseSequence,
                                                           payload: .noteOff(channel: 0, note: 60)), frame: 64)
            #expect(block(next, 64).1 == [release, at(100, programFive)])
        }

        /// A carried ramp on parameter 9 (outside the rig's 4) is planned but `RampSlots` refuses it on apply: never
        /// emitted, counted `refused`, and it stays unresolved. Kills: a refused carried event counted as delivered.
        @Test func readmissionRefusedRampStaysUnresolved() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            retire(rig, token, pending: [(100, ramp(9, 1)), (110, programFive)])
            let next = try replacement(of: rig)
            #expect(block(next, 64).1 == [at(110, programFive)])
            let report = next.carryReadmissionReport
            #expect(report.planned == 2 && report.refused == 1 && report.delivered == 1)
            #expect(stateful(next.unresolvedRetirementLoss) == [0, 0, 1])
        }

        /// A carried ramp whose completion overflows `Int64` makes the plan refuse `.frameOverflow`: nothing is
        /// re-admitted and the whole carry stays unresolved. Kills: a partial plan after a refusal.
        @Test func readmissionPlanRefusalReadmitsNothing() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            retire(rig, token, pending: [(100, programFive), (Int64.max - 10, ramp(1, 1, 100))])
            let next = try replacement(of: rig)
            let report = next.carryReadmissionReport
            #expect(report.planRefusal == .frameOverflow && report.planned == 0 && report.pendingCarriedEvents == 0)
            #expect(block(next, 64).1.isEmpty)
            #expect(stateful(next.unresolvedRetirementLoss) == [0, 1, 1])
        }

        /// Negative frames keep their original value through planning: during a replacement block over [-128, -64)
        /// a carried `control` at -100, the later of two carried `program`s on channel 0 (-90) and a carried ramp at
        /// -70 are emitted at their own frames, before an own same-channel `program` at -80 where earlier, and the
        /// carried `program` at -110 is superseded inside the carry. Kills: carried frames clamped to 0 (emitted late,
        /// after newer own state); the carry's own supersession done on clamped frames.
        @Test func readmissionKeepsNegativeFramesThroughPlanning() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            let programSix = KernelEventPayload.program(channel: 0, program: 6, bank: 0)
            let carried: [(Int64, KernelEventPayload)] = [(-110, programFive), (-100, control(7)), (-90, programSix),
                                                          (-70, ramp(1, 1))]
            for (frame, payload) in carried { #expect(rig.push(cycleEvent(frame, payload), token) == .ok) }
            #expect(rig.cycle.run(blockStart: -256, frames: 64) { _, _ in }.pending == 4)
            #expect(rig.cycle.retire().stateful == 4)
            let next = try replacement(of: rig)
            let programNine = KernelEventPayload.program(channel: 0, program: 9, bank: 0)
            #expect(rig.push(cycleEvent(-80, programNine), token) == .ok)
            #expect(block(next, -128).1 == [at(-100, control(7)), at(-90, programSix), at(-80, programNine),
                                            at(-70, ramp(1, 1))])
            let report = next.carryReadmissionReport
            #expect(report.planned == 3 && report.superseded == 1 && report.delivered == 3)
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss() && next.parameterValue(1) == 1)
        }

        /// Negative frames at the replacement's `retire()`: an own pending `program` at -80 covers the carried one at
        /// -100 (superseded, not carried again). Kills: a carried frame clamped to 0, so no longer covered.
        @Test func readmissionRetireCoversNegativeCarriedFrames() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(-100, programFive), token) == .ok)
            #expect(rig.cycle.run(blockStart: -256, frames: 64) { _, _ in }.pending == 1)
            _ = rig.cycle.retire()
            let next = try replacement(of: rig)
            #expect(rig.push(cycleEvent(-80, .program(channel: 0, program: 9, bank: 0)), token) == .ok)
            #expect(block(next, -256).1.isEmpty)
            #expect(next.retire().programs == 1)
            let report = next.carryReadmissionReport
            #expect(report.supersededByReplacement == 1 && report.recarried == 0)
            #expect(try replacement(of: rig).inheritedRetirementCarry.count == 1)
        }

        /// Same-frame carried ramps on parameter 2 from producer 0 (scope 0, sequence 9, to 1) and producer 1
        /// (scope 1, sequence 0, to 0.25) re-admit in the retiring buffer's order (producer lane before sequence), so
        /// 0.25 is the parameter's state. Kills: ties re-ordered by sequence during planning.
        @Test func readmissionKeepsTheRetiringBuffersTieOrderAcrossProducers() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let first = try #require(rig.events.claimProducer())
            let second = try #require(rig.events.claimProducer())
            let early = cycleEvent(100, ramp(2, 1), sequence: 9)
            let late = cycleEvent(100, ramp(2, 0.25), scope: 1, sequence: 0)
            #expect(rig.push(early, first) == .ok && rig.push(late, second) == .ok)
            #expect(rig.run(0, 64).0.pending == 2)
            #expect(rig.cycle.retire().ramps == 2)
            let next = try replacement(of: rig)
            #expect(next.inheritedRetirementCarry.events == [early, late])
            let emitted = [CycleEmission(event: early, frame: 100), CycleEmission(event: late, frame: 100)]
            #expect(block(next, 64).1 == emitted)
            #expect(next.parameterValue(2) == 0.25)
        }

        /// Capacity selection keeps the retiring buffer's tie order: with `blockCapacity` 1, of two frame-100
        /// `control`s from producer 0 (sequence 9) and producer 1 (sequence 0), producer 0's is kept and producer 1's
        /// is `cut`. Kills: the cut chosen by sequence.
        @Test func readmissionCapacityCutKeepsTheFirstInBufferOrder() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let first = try #require(rig.events.claimProducer())
            let second = try #require(rig.events.claimProducer())
            let kept = cycleEvent(100, control(7), sequence: 9)
            #expect(rig.push(kept, first) == .ok && rig.push(cycleEvent(100, control(8), scope: 1), second) == .ok)
            #expect(rig.run(0, 64).0.pending == 2)
            _ = rig.cycle.retire()
            let next = try replacement(of: rig, blockCapacity: 1, perLaneQuota: 1)
            #expect(block(next, 64).1 == [CycleEmission(event: kept, frame: 100)])
            let report = next.carryReadmissionReport
            #expect(report.planned == 1 && report.cut.controls == 1)
            #expect(stateful(next.unresolvedRetirementLoss) == [1, 0, 0])
        }

        /// A ramp whose completion would overflow `Int64` but is superseded inside the carry (a later ramp on the
        /// same scope and parameter) does not refuse the plan. Kills: the overflow checked before supersession.
        @Test func readmissionSupersededOverflowingRampDoesNotRefuse() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            retire(rig, token, pending: [(Int64.max - 10, ramp(1, 1, 100)), (Int64.max - 5, ramp(1, 0.5))])
            let report = try replacement(of: rig).carryReadmissionReport
            #expect(report.planRefusal == nil && report.planned == 1 && report.superseded == 1)
        }

        /// The overflow check runs before the cut: with `blockCapacity` 2, a ramp whose completion overflows `Int64`
        /// survives supersession inside the carry (it replaces an earlier ramp on parameter 1) and, last in delivery
        /// order, would be cut; the whole plan is still refused (`.frameOverflow`) and nothing is planned or cut.
        /// Kills: the overflow checked only on the kept survivors.
        @Test func readmissionOverflowingRampRefusesThePlanEvenWhenItWouldBeCut() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            retire(rig, token, pending: [(100, control(7)), (110, programFive), (120, ramp(1, 0.5)),
                                         (Int64.max - 10, ramp(1, 1, 100))])
            let next = try replacement(of: rig, blockCapacity: 2, perLaneQuota: 2)
            let report = next.carryReadmissionReport
            #expect(report.planRefusal == .frameOverflow && report.planned == 0 && report.cut == KernelRetirementLoss())
            #expect(block(next, 64).1.isEmpty)
            #expect(stateful(next.unresolvedRetirementLoss) == [1, 1, 2])
        }

        /// Negative frames across two hops: a carried `program` at -100 the replacement (no own events) never reaches
        /// is carried again at -100, as re-carried (`ownCount` 0), and the third cycle emits it there, in a block over
        /// [-128, -64). Kills: a re-carried frame clamped or shifted.
        @Test func readmissionKeepsNegativeFramesAcrossTwoHops() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(-100, programFive), token) == .ok)
            #expect(rig.cycle.run(blockStart: -256, frames: 64) { _, _ in }.pending == 1)
            _ = rig.cycle.retire()
            let next = try replacement(of: rig)
            #expect(block(next, -256).1.isEmpty)
            #expect(next.retire().programs == 1 && next.carryReadmissionReport.recarried == 1)
            let third = try replacement(of: rig)
            #expect(third.inheritedRetirementCarry.events == [cycleEvent(-100, programFive)])
            #expect(third.inheritedRetirementCarry.ownCount == 0)
            #expect(block(third, -128).1 == [at(-100, programFive)])
            #expect(third.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// Cross-hop tie order: a carried CC0 bank select and an own `program` on channel 0, both at 5,000 (different
        /// targets, so neither covers the other), are pending at the replacement's `retire()`, which records the own
        /// one first; the third cycle still emits the bank select first, as the replacement's merge would have
        /// (carried before own on a tie). Kills: re-carried events ordered after own ones by recorded index.
        @Test func readmissionKeepsCarriedBeforeOwnOnATieAcrossTwoHops() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            let bankSelect = control(0, 1)
            retire(rig, token, pending: [(5_000, bankSelect)])
            let next = try replacement(of: rig)
            #expect(rig.push(cycleEvent(5_000, programFive), token) == .ok)
            #expect(block(next, 64).1.isEmpty)
            #expect(next.retire().stateful == 2 && next.carryReadmissionReport.recarried == 1)
            let third = try replacement(of: rig)
            let carry = third.inheritedRetirementCarry
            #expect(carry.events == [cycleEvent(5_000, programFive), cycleEvent(5_000, bankSelect)])
            #expect(carry.ownCount == 1)
            #expect(block(third, 4_992).1 == [at(5_000, bankSelect), at(5_000, programFive)])
            #expect(third.unresolvedRetirementLoss == KernelRetirementLoss())
        }
    }
}
