import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private func noteOn(_ note: UInt8) -> KernelEventPayload { .noteOn(channel: 0, note: note, velocity: 100) }
private func control(_ value: UInt32) -> KernelEventPayload { .control(channel: 0, controller: 7, value: value) }

/// `acknowledgeCritical` as a value, so a refusal can be compared and the ticket is consumed outside `#expect`.
private func acknowledging(_ cycle: KernelCycle, _ observation: FaultObservation, _ ticket: consuming KernelAckTicket,
                           _ sample: KernelCycleTelemetry?) -> Result<FaultRecord, KernelCycle.AcknowledgeRefusal> {
    do {
        return .success(try cycle.acknowledgeCritical(observation, ticket, sample: sample))
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
            let approving = try #require(latestKernelCycleSample(slots)).value
            let approved = approving.permitsAcknowledgement(reused)
            #expect(approved && !approving.flushing)
            #expect(rig.push(cycleEvent(64, noteOn(9)), token) == .ok)
            #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 64) == .ok)
            #expect(rig.faults.acknowledge(first) == nil)
            let second = try #require(rig.faults.observe(CycleRig.criticalScope))
            #expect(second.epoch == first.epoch && second.tally != first.tally)
            let before = AcknowledgeState(rig)
            let reuse = acknowledging(rig.cycle, second, reused, approving)
            #expect(reuse == .failure(.ticketObservationMismatch))
            #expect(AcknowledgeState(rig) == before && before.latched && before.record == second.record)

            let fresh = try rig.cycle.ackRequests.request(for: second)
            let (silenced, released) = rig.run(64, 64)
            #expect(silenced.status == .silenced(.scopeFaulted) && silenced.discardedWhileSilenced == 1)
            #expect(released.isEmpty)
            let approval = try #require(latestKernelCycleSample(slots)).value
            let acknowledged = acknowledging(rig.cycle, second, fresh, approval)
            #expect(acknowledged == .success(second.record) && !rig.faults.isLatched(CycleRig.criticalScope))
            for block in Int64(2)...4 {
                let (result, emitted) = rig.run(block * 64, 64)
                #expect(result.status == .ok && emitted.isEmpty)
            }
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 9) && rig.cycle.bufferedCount == 0)
        }

        /// Each refusal is typed and leaves the latch, the epoch and the cycle unchanged. Kills: the issuing-cycle,
        /// critical-scope or approval check skipped.
        @Test func acknowledgeRefusalsChangeNothing() throws {
            let slots = try kernelCycleTelemetrySlots()
            let rig = try CycleRig(telemetry: KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 0))
            let other = try CycleRig()
            #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
            #expect(rig.faults.raise(CycleRig.slotsScope, .producerSlotsExhausted, frame: 0) == .ok)
            let observation = try #require(rig.faults.observe(CycleRig.criticalScope))
            let slotsObservation = try #require(rig.faults.observe(CycleRig.slotsScope))
            var before = AcknowledgeState(rig)
            let unpublished = try rig.cycle.ackRequests.request(for: observation)
            let early = try rig.cycle.ackRequests.request(for: observation)
            let foreign = try other.cycle.ackRequests.request(for: observation)
            let wrongScope = try rig.cycle.ackRequests.request(for: slotsObservation)
            let beforeRace = try rig.cycle.ackRequests.request(for: observation)
            before = AcknowledgeState(rig)
            #expect(before.lastRequested == 4)
            let noSample = acknowledging(rig.cycle, observation, unpublished, nil)
            let notYet = acknowledging(rig.cycle, observation, early, rig.cycle.telemetry)
            #expect(noSample == .failure(.notApproved) && notYet == .failure(.notApproved))
            #expect(AcknowledgeState(rig) == before)

            #expect(rig.run(0, 64).0.status == .silenced(.scopeFaulted))
            let approving = try #require(latestKernelCycleSample(slots)).value
            #expect(approving.lastFaultedAckEpoch == 4)
            before = AcknowledgeState(rig)
            let foreignOutcome = acknowledging(rig.cycle, observation, foreign, approving)
            let scopeOutcome = acknowledging(rig.cycle, slotsObservation, wrongScope, approving)
            #expect(foreignOutcome == .failure(.foreignTicket) && scopeOutcome == .failure(.notCriticalScope))
            #expect(AcknowledgeState(rig) == before && rig.faults.isLatched(CycleRig.slotsScope))
            #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 64) == .ok)
            before = AcknowledgeState(rig)
            let raced = acknowledging(rig.cycle, observation, beforeRace, approving)
            #expect(raced == .failure(.latchRefused) && AcknowledgeState(rig) == before && before.latched)
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
                let sample = try #require(latestKernelCycleSample(slots)).value
                let acknowledged = acknowledging(rig.cycle, observation, ticket, sample)
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
