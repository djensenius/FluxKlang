import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private func noteOn(_ note: UInt8) -> KernelEventPayload { .noteOn(channel: 0, note: note, velocity: 100) }
private func control(_ value: UInt32) -> KernelEventPayload { .control(channel: 0, controller: 7, value: value) }

/// `acknowledgeCritical` as a value, so a refusal can be compared and the ticket is consumed outside `#expect`.
private func acknowledging(_ cycle: KernelCycle, _ observation: FaultObservation,
                           _ ticket: consuming KernelAckTicket) -> Result<FaultRecord, KernelCycle.AcknowledgeRefusal> {
    do {
        return .success(try cycle.acknowledgeCritical(observation, ticket))
    } catch {
        return .failure(error)
    }
}

/// Everything a refused acknowledgement must leave unchanged.
private struct AcknowledgeState: Equatable {
    let latched: Bool
    let record: FaultRecord?
    let lastRequested: UInt64
    let telemetry: KernelCycleTelemetry

    init(_ rig: CycleRig) {
        latched = rig.faults.isLatched(CycleRig.criticalScope)
        record = rig.faults.observe(CycleRig.criticalScope)?.record
        lastRequested = rig.cycle.ackRequests.lastRequested
        telemetry = rig.cycle.telemetry
    }
}

extension RealtimeHandoffTests {
    struct CycleOrderingAcknowledge {
        /// Round 2c M1, step by step: control observes O1 and requests t; a faulted cycle approves t; a producer
        /// queues `noteOn(X)` and its refused `noteOff` raises; acknowledging O1 fails; control observes O2 and
        /// presents t again. The reuse is refused and changes nothing; a fresh request for O2 waits for a faulted
        /// cycle, which discards X, and X never sounds. Kills: the binding check skipped; it comparing the
        /// acknowledge epoch (equal for O1 and O2) instead of the tally.
        @Test func reusedTicketAfterReRaiseIsRefusedAndQueuedNoteOnNeverSounds() throws {
            let slots = try kernelCycleTelemetrySlots()
            let rig = try CycleRig(telemetry: KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 0))
            let token = try #require(rig.events.claimProducer())
            #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
            let first = try #require(rig.faults.observe(CycleRig.criticalScope))
            let reused = try rig.cycle.ackRequests.request(for: first)
            #expect(rig.run(0, 64).0.status == .silenced(.scopeFaulted))
            let approving = try #require(rig.cycle.latestTelemetry()).value
            let approved = approving.permitsAcknowledgement(reused)
            #expect(approved && !approving.flushing)
            #expect(rig.push(cycleEvent(64, noteOn(9)), token) == .ok)
            #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 64) == .ok)
            #expect(rig.faults.acknowledge(first) == nil)
            let second = try #require(rig.faults.observe(CycleRig.criticalScope))
            #expect(second.epoch == first.epoch && second.tally != first.tally)
            let before = AcknowledgeState(rig)
            let reuse = acknowledging(rig.cycle, second, reused)
            #expect(reuse == .failure(.ticketObservationMismatch))
            #expect(AcknowledgeState(rig) == before && before.latched && before.record == second.record)

            let fresh = try rig.cycle.ackRequests.request(for: second)
            let (silenced, released) = rig.run(64, 64)
            #expect(silenced.status == .silenced(.scopeFaulted) && silenced.discardedWhileSilenced == 1)
            #expect(released.isEmpty)
            let acknowledged = acknowledging(rig.cycle, second, fresh)
            #expect(acknowledged == .success(second.record) && !rig.faults.isLatched(CycleRig.criticalScope))
            for block in Int64(2)...4 {
                let (result, emitted) = rig.run(block * 64, 64)
                #expect(result.status == .ok && emitted.isEmpty)
            }
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 9) && rig.cycle.bufferedCount == 0)
        }

        /// Each refusal is typed, comes in the documented order and leaves the latch, the epoch and the cycle
        /// unchanged. Kills: the issuing-cycle, critical-scope, approval or latch check skipped; the binding checked
        /// before the issuing cycle (the foreign ticket is also bound to another observation).
        @Test func acknowledgeRefusalsChangeNothing() throws {
            let slots = try kernelCycleTelemetrySlots()
            let rig = try CycleRig(telemetry: KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 0))
            let other = try CycleRig()
            #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
            #expect(rig.faults.raise(CycleRig.slotsScope, .producerSlotsExhausted, frame: 0) == .ok)
            for frame in Int64(0)..<2 {
                #expect(other.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: frame) == .ok)
            }
            let observation = try #require(rig.faults.observe(CycleRig.criticalScope))
            let slotsObservation = try #require(rig.faults.observe(CycleRig.slotsScope))
            let otherObservation = try #require(other.faults.observe(CycleRig.criticalScope))
            #expect(otherObservation.tally != observation.tally)
            let unpublished = try rig.cycle.ackRequests.request(for: observation)
            let foreign = try other.cycle.ackRequests.request(for: otherObservation)
            let wrongScope = try rig.cycle.ackRequests.request(for: observation)
            let beforeRace = try rig.cycle.ackRequests.request(for: observation)
            var before = AcknowledgeState(rig)
            #expect(before.lastRequested == 3)
            let notYet = acknowledging(rig.cycle, observation, unpublished)
            #expect(notYet == .failure(.notApproved) && AcknowledgeState(rig) == before)

            #expect(rig.run(0, 64).0.status == .silenced(.scopeFaulted))
            #expect(try #require(rig.cycle.latestTelemetry()).value.lastFaultedAckEpoch == 3)
            before = AcknowledgeState(rig)
            let foreignOutcome = acknowledging(rig.cycle, observation, foreign)
            let scopeOutcome = acknowledging(rig.cycle, slotsObservation, wrongScope)
            #expect(foreignOutcome == .failure(.foreignTicket) && scopeOutcome == .failure(.notCriticalScope))
            #expect(AcknowledgeState(rig) == before && rig.faults.isLatched(CycleRig.slotsScope))
            #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 64) == .ok)
            before = AcknowledgeState(rig)
            let raced = acknowledging(rig.cycle, observation, beforeRace)
            #expect(raced == .failure(.latchRefused) && AcknowledgeState(rig) == before && before.latched)
        }

        /// Round 2d: no caller-supplied sample is trusted. A forged sample would approve, but `acknowledgeCritical`
        /// reads only its own slot: before a faulted cycle, after a replacement cycle (another identity) published
        /// a faulted sample on that slot, and with no telemetry at all (fail-closed), it refuses. Kills: approval
        /// ignored; identity ignored.
        @Test func forgedOrForeignSampleNeverApproves() throws {
            let slots = try kernelCycleTelemetrySlots()
            let output = KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 0)
            let rig = try CycleRig(telemetry: output)
            #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
            let observation = try #require(rig.faults.observe(CycleRig.criticalScope))
            let early = try rig.cycle.ackRequests.request(for: observation)
            let forged = KernelCycleTelemetry(lastFaultedAckEpoch: .max, ackCycle: rig.cycle.ackRequests.identity)
            let forgedApproves = forged.permitsAcknowledgement(early)
            var before = AcknowledgeState(rig)
            let earlyOutcome = acknowledging(rig.cycle, observation, early)
            #expect(forgedApproves && earlyOutcome == .failure(.notApproved))
            #expect(AcknowledgeState(rig) == before)

            let ticket = try rig.cycle.ackRequests.request(for: observation)
            let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership,
                                         safety: rig.safety, ramps: rig.ramps, telemetry: output)
            let replacement = try KernelCycle(parts, pulses: ClockPulseGate(maximumPulsesPerBlock: 4,
                                                                             staleTolerance: 48),
                                              blockCapacity: 64, perLaneQuota: 64)
            #expect(replacement.run(blockStart: 0, frames: 64) { _, _ in }.status == .silenced(.scopeFaulted))
            let foreignSample = try #require(replacement.latestTelemetry()).value
            #expect(foreignSample.lastFaultedAckEpoch == 0 && foreignSample.ackCycle != rig.cycle.ackRequests.identity)
            before = AcknowledgeState(rig)
            let foreignOutcome = acknowledging(rig.cycle, observation, ticket)
            #expect(foreignOutcome == .failure(.notApproved))
            #expect(AcknowledgeState(rig) == before)

            let silent = try CycleRig()
            #expect(silent.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
            let silentObservation = try #require(silent.faults.observe(CycleRig.criticalScope))
            let silentTicket = try silent.cycle.ackRequests.request(for: silentObservation)
            #expect(silent.run(0, 64).0.status == .silenced(.scopeFaulted))
            let silentOutcome = acknowledging(silent.cycle, silentObservation, silentTicket)
            #expect(silentOutcome == .failure(.notApproved))
            #expect(silent.faults.isLatched(CycleRig.criticalScope))
        }

        /// Round 2e: a twin latch's observation with the same words is refused as `.foreignObservation` before the
        /// slot is read (no faulted cycle yet, where reading it would give `.notApproved`) and after an approving
        /// cycle (where the latch would give `.latchRefused`), changing nothing; the own observation then succeeds.
        /// Kills: the latch-identity guard skipped.
        @Test func acknowledgeRefusesATwinLatchObservation() throws {
            let slots = try kernelCycleTelemetrySlots()
            let rig = try CycleRig(telemetry: KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 0))
            let twin = try FaultLatch(scopes: [CycleRig.criticalScope, CycleRig.slotsScope, CycleRig.sysexScope])
            for latch in [rig.faults, twin] {
                #expect(latch.raise(CycleRig.criticalScope, .criticalExhausted, frame: 7) == .ok)
            }
            let own = try #require(rig.faults.observe(CycleRig.criticalScope))
            let foreign = try #require(twin.observe(CycleRig.criticalScope))
            #expect(foreign.record == own.record && foreign.tally == own.tally && foreign.epoch == own.epoch)
            let unread = try rig.cycle.ackRequests.request(for: own)
            let approved = try rig.cycle.ackRequests.request(for: own)
            let ticket = try rig.cycle.ackRequests.request(for: own)
            var before = AcknowledgeState(rig)
            let early = acknowledging(rig.cycle, foreign, unread)
            #expect(early == .failure(.foreignObservation) && AcknowledgeState(rig) == before)
            #expect(rig.cycle.latestTelemetry() == nil)
            #expect(rig.run(0, 64).0.status == .silenced(.scopeFaulted))
            before = AcknowledgeState(rig)
            let late = acknowledging(rig.cycle, foreign, approved)
            #expect(late == .failure(.foreignObservation) && AcknowledgeState(rig) == before)
            #expect(twin.isLatched(CycleRig.criticalScope))
            #expect(acknowledging(rig.cycle, own, ticket) == .success(own.record))
            #expect(!rig.faults.isLatched(CycleRig.criticalScope) && twin.isLatched(CycleRig.criticalScope))
        }

        /// Round 2d: `request(for:)` takes only an observation of its cycle's own latch and critical scope. A
        /// foreign latch's observation with the same words, and the same latch's other scope, are refused before
        /// the epoch moves. Kills: the latch or the scope check skipped.
        @Test func requestRefusesAForeignLatchOrScopeObservation() throws {
            let rig = try CycleRig()
            let twin = try FaultLatch(scopes: [CycleRig.criticalScope, CycleRig.slotsScope, CycleRig.sysexScope])
            for latch in [rig.faults, twin] {
                #expect(latch.raise(CycleRig.criticalScope, .criticalExhausted, frame: 7) == .ok)
            }
            #expect(rig.faults.raise(CycleRig.slotsScope, .producerSlotsExhausted, frame: 7) == .ok)
            let own = try #require(rig.faults.observe(CycleRig.criticalScope))
            let foreign = try #require(twin.observe(CycleRig.criticalScope))
            let slotsObservation = try #require(rig.faults.observe(CycleRig.slotsScope))
            #expect(foreign.record == own.record && foreign.tally == own.tally && foreign.epoch == own.epoch)
            for observation in [foreign, slotsObservation] {
                #expect(throws: KernelAckRequests.RequestError.foreignObservation) {
                    _ = try rig.cycle.ackRequests.request(for: observation)
                }
                #expect(rig.cycle.ackRequests.lastRequested == 0)
            }
            let ticket = try rig.cycle.ackRequests.request(for: own)
            #expect(ticket.epoch == 1 && ticket.isBound(to: own))
        }

        /// Round 2c L1: the old cycle is acknowledged while its lane is still flushing (the quota cut it short, so
        /// `noteOn(9)` is still queued behind its controls); a replacement (quota 1) on the same fan-in drains it. A
        /// `.freshFanIn` start lets it sound and stick; the default `.replacingCycle` start reports flushing at once,
        /// discards it, and once the lane is proved empty a later `noteOn` sounds (liveness). Kills: a replacement
        /// starting unarmed, with no flushing count, or `.freshFanIn` as the default.
        @Test func replacementCycleStartsFlushingSoAQueuedNoteOnNeverSounds() throws {
            for fresh in [true, false] {
                let slots = try kernelCycleTelemetrySlots()
                let rig = try CycleRig(lanes: 1, perLaneQuota: 2,
                                       telemetry: KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 0))
                let token = try #require(rig.events.claimProducer())
                for value in UInt32(0)..<2 { #expect(rig.push(cycleEvent(0, control(value)), token) == .ok) }
                #expect(rig.push(cycleEvent(0, noteOn(9)), token) == .ok)
                #expect(rig.push(cycleEvent(0, control(2)), token) == .ok)
                #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
                let observation = try #require(rig.faults.observe(CycleRig.criticalScope))
                let ticket = try rig.cycle.ackRequests.request(for: observation)
                let faulted = rig.run(0, 64).0
                #expect(faulted.status == .silenced(.scopeFaulted) && faulted.flushing && faulted.drained == 2)
                let acknowledged = acknowledging(rig.cycle, observation, ticket)
                #expect(acknowledged == .success(observation.record))

                var parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership,
                                             safety: rig.safety, ramps: rig.ramps)
                if fresh { parts.start = .freshFanIn }
                let replacement = try KernelCycle(parts, pulses: ClockPulseGate(maximumPulsesPerBlock: 4,
                                                                                 staleTolerance: 48),
                                                  blockCapacity: 64, perLaneQuota: 1)
                var sounded = false
                var flushing: [Bool] = []
                for block in Int64(1)...4 {
                    let result = replacement.run(blockStart: block * 64, frames: 64) { event, _ in
                        sounded = sounded || event.payload == noteOn(9)
                    }
                    flushing.append(result.flushing)
                }
                #expect(sounded == fresh && rig.ownership.isOwned(scope: 0, channel: 0, note: 9) == fresh)
                #expect(flushing == (fresh ? [false, false, false, false] : [true, true, false, false]))
                #expect(rig.push(cycleEvent(320, noteOn(10)), token) == .ok)
                var later = false
                let result = replacement.run(blockStart: 320, frames: 64) { event, _ in
                    later = later || event.payload == noteOn(10)
                }
                #expect(result.status == .ok && later && replacement.bufferedCount == 0)
            }
        }
    }
}
