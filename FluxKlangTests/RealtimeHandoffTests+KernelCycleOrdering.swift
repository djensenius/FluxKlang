import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Root = RealtimeHandoffTests

private func noteOn(_ note: UInt8) -> KernelEventPayload { .noteOn(channel: 0, note: note, velocity: 100) }
private func noteOff(_ note: UInt8) -> KernelEventPayload { .noteOff(channel: 0, note: note) }
private func control(_ value: UInt32) -> KernelEventPayload { .control(channel: 0, controller: 7, value: value) }

/// Render → control telemetry slots for one `KernelCycle`. Shared with
/// `RealtimeHandoffTests+KernelCycleOrderingStress.swift`.
func kernelCycleTelemetrySlots() throws -> TelemetrySlots<KernelCycleTelemetry> {
    try TelemetrySlots(policy: Root.policy(purpose: .telemetry, producer: .render, consumer: .control, capacity: 2,
                                           ordering: .latestOnly, deadline: .none, overflow: .overwriteLatest),
                       slotCount: 2)
}

/// Thrown when a ticket the test expected was never requested.
private struct CycleOrderingTicketMissing: Error {}

extension RealtimeHandoffTests {
    struct CycleOrdering {
        /// Each pair differs in one key component, which must decide it against every later component and the
        /// drain order. Kills: dropping or reversing frame, lane, producer lane or sequence; lane before frame;
        /// sequence before producer.
        @Test func eachOrderKeyComponentDecidesItsTie() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let first = try #require(rig.events.claimProducer())
            let second = try #require(rig.events.claimProducer())
            for (event, token) in [
                (cycleEvent(11, noteOff(2), sequence: 0), first), (cycleEvent(10, noteOn(1), sequence: 9), second),
                (cycleEvent(20, control(20), sequence: 0), first), (cycleEvent(20, noteOff(3), sequence: 9), second),
                (cycleEvent(30, control(32), sequence: 0), second), (cycleEvent(30, control(31), sequence: 9), first),
                (cycleEvent(40, control(42), sequence: 2), first), (cycleEvent(40, control(41), sequence: 1), first)
            ] {
                #expect(rig.push(event, token) == .ok)
            }
            let (result, emitted) = rig.run(0, 64)
            #expect(emitted.map(\.event.payload) == [noteOn(1), noteOff(2), noteOff(3), control(20), control(31),
                                                     control(32), control(41), control(42)])
            #expect(emitted.map(\.frame) == [10, 11, 20, 20, 30, 30, 40, 40] && result.dispatched == 8)
        }

        /// Equal full keys (a producer reusing a sequence). Kills: an unstable merge sort of the new run; the run
        /// merged ahead of the kept prefix on a tie.
        @Test func equalKeysKeepDrainOrderBehindThePrefix() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(1_000, control(1), sequence: 5), token) == .ok)
            #expect(rig.run(0, 64).0.pending == 1)
            for value in UInt32(2)...6 {
                #expect(rig.push(cycleEvent(1_000, control(value), sequence: 5), token) == .ok)
            }
            #expect(rig.push(cycleEvent(900, control(0), sequence: 5), token) == .ok)
            #expect(rig.push(cycleEvent(1_000, control(7), sequence: 5), token) == .ok)
            #expect(rig.run(64, 64).0.pending == 8)
            let (result, emitted) = rig.run(1_000, 64)
            #expect(emitted.map(\.event.payload) == (0...7).map { control(UInt32($0)) } && result.pending == 0)
        }

        /// E2 review P2-3 across three lanes and the kept prefix. Kills: re-sorting by decided frame (all collapse
        /// onto `blockStart`, where lane order would put the `noteOff` first and leave the note stuck).
        @Test func lateBacklogNeverReSortedByDecidedFrame() throws {
            let rig = try CycleRig(lanes: 3, laneCapacity: 32)
            let tokens = try (0..<3).map { _ in try #require(rig.events.claimProducer()) }
            #expect(rig.push(cycleEvent(995, noteOff(60)), tokens[0]) == .ok)
            #expect(rig.push(cycleEvent(990, noteOn(60)), tokens[1]) == .ok)
            #expect(rig.push(cycleEvent(900, control(1)), tokens[2]) == .ok)
            #expect(rig.push(cycleEvent(1_000, .clockPulse), tokens[2]) == .ok)
            let (result, emitted) = rig.run(1_000, 64)
            #expect(emitted.map(\.event.frame) == [900, 990, 995, 1_000] && emitted.allSatisfy { $0.frame == 1_000 })
            #expect(result.dispatched == 4 && !rig.ownership.isOwned(scope: 0, channel: 0, note: 60))
        }

        /// Kills: an empty cycle that drains, decides a late buffered event, admits a stale pulse or skips fault
        /// recovery; telemetry not counting empty or faulted cycles.
        @Test func emptyCyclesRunSafetyAndFaultsButLeaveTimedEventsQueued() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            for event in [cycleEvent(0, noteOn(60)), cycleEvent(100, control(1)), cycleEvent(101, .clockPulse)] {
                #expect(rig.push(event, token) == .ok)
            }
            #expect(rig.run(0, 64).0.pending == 2)
            let (idle, nothing) = rig.run(500, 0)
            #expect(idle.status == .ok && idle.dispatched == 0 && idle.skippedPulses == 0 && idle.pending == 2)
            #expect(nothing.isEmpty)
            #expect(rig.push(cycleEvent(110, control(2)), token) == .ok)
            #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
            for frames in [0, -1, Int64.min] {
                let (result, emitted) = rig.run(500, frames)
                #expect(result.status == .silenced(.scopeFaulted) && result.drained == 0 && result.dispatched == 0)
                #expect(result.pending == 2 && result.skippedPulses == 0 && result.flushing && !result.resync)
                #expect(emitted.allSatisfy { $0.event.sequence == KernelCycle.releaseSequence })
            }
            #expect(rig.ownership.ownedCount(scope: 0) == 0 && rig.cycle.pulses.skippedStale == 0)
            #expect(rig.cycle.telemetry.cycle == 5 && rig.cycle.telemetry.lastFaultedCycle == 5)
            #expect(rig.cycle.telemetry.flushing && rig.cycle.telemetry.pending == 2)
            #expect(rig.faults.acknowledge(try #require(rig.faults.observe(CycleRig.criticalScope))) != nil)
            let (resumed, emitted) = rig.run(500, 64)
            #expect(resumed.status == .ok && resumed.drained == 1 && !resumed.flushing && resumed.skippedPulses == 1)
            #expect(emitted.map(\.event.payload) == [control(1), control(2)] && resumed.resync)
            #expect(!rig.cycle.telemetry.flushing && rig.cycle.telemetry.pending == 0)
        }

        /// Kills: telemetry not published, published with the wrong stamp, or counters that are per cycle rather
        /// than cumulative or that disagree with the results and the gate; a `.safetyMute` cycle counted as faulted.
        @Test func telemetryPublishesCumulativeCountersEveryCycle() throws {
            let slots = try kernelCycleTelemetrySlots()
            let output = KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 7)
            let rig = try CycleRig(laneCapacity: 32, pulsesPerBlock: 1, telemetry: output)
            let token = try #require(rig.events.claimProducer())
            #expect(rig.cycle.latestTelemetry() == nil)
            for event in [cycleEvent(0, noteOn(1)), cycleEvent(1, .clockPulse), cycleEvent(400, .clockPulse),
                          cycleEvent(401, .clockPulse), cycleEvent(402, .clockPulse), cycleEvent(5_000, noteOn(2)),
                          cycleEvent(1_070, .clockPulse), cycleEvent(1_071, .clockPulse)] {
                #expect(rig.push(event, token) == .ok)
            }
            var results: [KernelCycleResult] = []
            for (blockStart, frames) in [(Int64(1_000), Int64(64)), (1_064, 0), (1_064, 64)] {
                results.append(rig.run(blockStart, frames).0)
            }
            let sample = try #require(rig.cycle.latestTelemetry())
            #expect(sample.stamp == TelemetryStamp(clockGeneration: 7, frame: 1_064) && sample.sequence == 3)
            #expect(sample.value == rig.cycle.telemetry)
            let expected = KernelCycleTelemetry(cycle: 3, lastFaultedCycle: 0, droppedLate: 1, resyncs: 1,
                                                skippedStale: 4, rateLimited: 1, pending: 1, flushing: false,
                                                ackCycle: rig.cycle.ackRequests.identity)
            #expect(sample.value == expected)
            #expect(results.map(\.droppedLate) == [1, 0, 0])
            #expect(results.map(\.resync) == [true, false, false])
            #expect(slots.latest(slot: 0) == .unavailable(.neverPublished))
            #expect(KernelCycleTelemetry.saturatingAdd(.max - 1, 5) == .max)
            #expect(KernelCycleTelemetry.saturatingAdd(3, -2) == 3)
            _ = rig.safety.request(.panic, scope: 0)
            #expect(rig.run(1_128, 64).0.status == .silenced(.safetyMute))
            let muted = rig.cycle.telemetry
            #expect(muted.cycle == 4 && muted.lastFaultedCycle == 0 && muted.lastFaultedAckEpoch == 0)
        }

        /// Ruling (E5b round 1): `.staleClock` stays off the `FaultLatch`. Kills: a stale pulse raising any fault
        /// (which would also silence the next cycle); the stale pulse not counted; the next valid pulse blocked.
        @Test func staleClockCountsWithoutLatchingAndNextPulseProceeds() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(100, .clockPulse), token) == .ok)
            #expect(rig.push(cycleEvent(1_010, .clockPulse), token) == .ok)
            let (stale, emitted) = rig.run(1_000, 64)
            #expect(stale.status == .ok && stale.skippedPulses == 1 && stale.dispatched == 1)
            #expect(emitted == [CycleEmission(event: cycleEvent(1_010, .clockPulse), frame: 1_010)])
            #expect(rig.cycle.pulses.skippedStale == 1 && rig.cycle.telemetry.skippedStale == 1)
            for scope in [CycleRig.criticalScope, CycleRig.slotsScope, CycleRig.sysexScope] {
                #expect(!rig.faults.isLatched(scope) && rig.faults.observe(scope) == nil)
            }
            #expect(rig.push(cycleEvent(1_070, .clockPulse), token) == .ok)
            let (next, pulse) = rig.run(1_064, 64)
            #expect(next.status == .ok && next.skippedPulses == 0 && next.dispatched == 1 && !next.flushing)
            #expect(pulse.map(\.frame) == [1_070] && rig.cycle.telemetry.lastFaultedCycle == 0)
        }

        /// Flush watermark: the drain that proves a flushing lane empty clears its bit, yet the `noteOn` it just
        /// drained stays marked. Kills: entries losing the flush mark (the `noteOn` would sound after the latch).
        @Test func noteOnDrainedAsLaneEmptiesStaysFlushed() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
            // An idle latched cycle arms every bit without draining, so no drain has proved a lane empty yet.
            let (faulted, _) = rig.run(0, 0)
            #expect(faulted.status == .silenced(.scopeFaulted) && faulted.drained == 0 && faulted.flushing)
            #expect(rig.faults.acknowledge(try #require(rig.faults.observe(CycleRig.criticalScope))) != nil)
            #expect(rig.push(cycleEvent(80, noteOn(70)), token) == .ok)
            #expect(rig.push(cycleEvent(90, control(3)), token) == .ok)
            let (result, emitted) = rig.run(0, 128)
            #expect(result.status == .ok && result.drained == 2 && !result.flushing && result.pending == 0)
            #expect(result.discardedWhileSilenced == 1 && result.dispatched == 1)
            #expect(emitted.map(\.event.payload) == [control(3)])
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 70))
            #expect(rig.cycle.telemetry.discardedWhileSilenced == 1)
        }

        /// Ruling (E5b round 2): one latch arms both lanes; lane 0 is proved empty, then drained again, while the
        /// quota keeps cutting lane 1 short. Kills: an already clear bit cleared again (the count falls to 0 while
        /// lane 1 is set); a `noteOn` from a cleared lane decided while another lane still flushes.
        @Test func clearedLaneNoteOnDiscardedWhileAnotherLaneFlushes() throws {
            let slots = try kernelCycleTelemetrySlots()
            let rig = try CycleRig(laneCapacity: 24, perLaneQuota: 2,
                                   telemetry: KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 0))
            let cleared = try #require(rig.events.claimProducer())
            let cut = try #require(rig.events.claimProducer())
            for value in UInt32(0)..<5 { #expect(rig.push(cycleEvent(10, control(value)), cut) == .ok) }
            #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
            #expect(rig.run(0, 0).0.flushing)
            #expect(rig.faults.acknowledge(try #require(rig.faults.observe(CycleRig.criticalScope))) != nil)
            let (first, _) = rig.run(0, 64)
            #expect(first.status == .ok && first.drained == 2 && first.flushing)
            #expect(rig.push(cycleEvent(70, noteOn(60)), cleared) == .ok)
            let (second, emitted) = rig.run(64, 64)
            #expect(second.drained == 3 && second.flushing && second.discardedWhileSilenced == 1)
            #expect(emitted.map(\.event.payload) == [control(2), control(3)])
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 60))
            #expect(rig.cycle.latestTelemetry()?.value.flushing == true && rig.cycle.telemetry.flushing)
            let (third, _) = rig.run(128, 64)
            #expect(third.drained == 1 && !third.flushing && rig.cycle.latestTelemetry()?.value.flushing == false)
        }

        /// Ruling (E5b round 3): a drain never pops what the block cannot hold. Kills: a `limit` past the room
        /// popping events the block refuses (lost; a lost `noteOff` sticks its note); a cycle draining past room.
        @Test func drainLimitPastRoomLeavesExcessQueuedInOrder() throws {
            let rig = try CycleRig(laneCapacity: 24, blockCapacity: 2)
            let token = try #require(rig.events.claimProducer())
            for value in UInt32(0)..<3 { #expect(rig.push(cycleEvent(500, control(value)), token) == .ok) }
            for event in [cycleEvent(501, noteOff(61)), cycleEvent(502, control(4))] {
                #expect(rig.push(event, token) == .ok)
            }
            #expect(rig.run(0, 64).0.drained == 2 && rig.run(64, 64).0.drained == 0)
            let block = KernelBlockBuffer(capacity: 2)
            let watermark = KernelFlushWatermark(laneCount: rig.events.laneCount, armed: false)
            #expect(watermark.drain(rig.events, perLaneQuota: 4, limit: 1, into: block) == 1)
            #expect(watermark.drain(rig.events, perLaneQuota: 4, limit: 3, into: block) == 1)
            #expect(block.count == 2 && block[0].event.payload == control(2) && block[1].event.payload == noteOff(61))
            let next = KernelBlockBuffer(capacity: 4)
            #expect(watermark.drain(rig.events, perLaneQuota: 4, limit: 4, into: next) == 1)
            #expect(next.count == 1 && next[0].event.payload == control(4))
            #expect(watermark.appendRefused == 0 && rig.cycle.telemetry.blockAppendRefused == 0)
        }

        /// Kills: the discard counters missing from telemetry, or per cycle rather than cumulative.
        @Test func discardCountersAccumulateInTelemetry() throws {
            let rig = try CycleRig(blockCapacity: 1)
            let first = try #require(rig.events.claimProducer())
            let second = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(999, noteOff(60)), first) == .ok)
            #expect(rig.push(cycleEvent(990, noteOn(60)), second) == .ok)
            #expect(rig.run(1_000, 64).0.drained == 1 && rig.run(1_064, 64).0.discardedSuperseded == 1)
            #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
            for blockStart in [Int64(1_128), 1_192] {
                #expect(rig.push(cycleEvent(blockStart &+ 2, noteOn(62)), first) == .ok)
                #expect(rig.run(blockStart, 64).0.discardedWhileSilenced == 1)
            }
            #expect(rig.cycle.telemetry.discardedSuperseded == 1 && rig.cycle.telemetry.discardedWhileSilenced == 2)
        }

        /// Ruling 4 (E5b round 2): admission refusals, on a `noteOff` too, are returned typed, never latch, and
        /// are counted per lane and kind, then published as totals. Kills: a refusal uncounted, counted on the
        /// wrong lane or kind, or counted for another status; another handoff's token counted on a lane; totals
        /// not published.
        @Test func admissionRefusalsCountedPerLaneWithoutLatching() throws {
            let rig = try CycleRig()
            let first = try #require(rig.events.claimProducer())
            let second = try #require(rig.events.claimProducer())
            let refusals = rig.cycle.admissionRefusals
            var one = ProducerAdmission(deadline: rig.cycle.deadline, refusals: refusals)
            var two = ProducerAdmission(deadline: rig.cycle.deadline, refusals: refusals)
            #expect(one.push(cycleEvent(100, noteOn(60)), now: 0, into: rig.events, token: first) == .ok)
            #expect(one.push(cycleEvent(99, noteOff(60)), now: 0, into: rig.events, token: first)
                    == .refused(.nonMonotonic))
            #expect(one.push(cycleEvent(98, control(1)), now: 0, into: rig.events, token: first)
                    == .refused(.nonMonotonic))
            #expect(two.push(cycleEvent(96_001, noteOff(61)), now: 0, into: rig.events, token: second)
                    == .refused(.beyondLookahead))
            let other = try CycleRig()
            refusals.record(.refused(.nonMonotonic), token: try #require(other.events.claimProducer()))
            refusals.record(.refused(.full), token: first)
            #expect(refusals.count(lane: 0, .nonMonotonic) == 2 && refusals.count(lane: 0, .beyondLookahead) == 0)
            #expect(refusals.count(lane: 1, .nonMonotonic) == 0 && refusals.count(lane: 1, .beyondLookahead) == 1)
            #expect(refusals.count(lane: 2, .nonMonotonic) == nil && refusals.count(lane: -1, .nonMonotonic) == nil)
            #expect(refusals.unattributed == 1)
            for scope in [CycleRig.criticalScope, CycleRig.slotsScope, CycleRig.sysexScope] {
                #expect(!rig.faults.isLatched(scope))
            }
            let (result, emitted) = rig.run(0, 200)
            #expect(result.status == .ok && emitted.map(\.event.payload) == [noteOn(60)])
            #expect(rig.cycle.telemetry.refusedNonMonotonic == 2 && rig.cycle.telemetry.refusedBeyondLookahead == 1)
        }

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

        /// (a) A stale sample never approves: neither a never-published read nor a cached front sample (no publish
        /// since, so `latest` keeps it on its relaxed path) with many faulted cycles. (c) Liveness: the next faulted
        /// cycle publishes the requested epoch and approves. Kills: acknowledging on cycle counts, on the epoch of
        /// any cycle rather than a faulted one, `>` for `>=`, render never loading the epoch.
        @Test func staleSampleDelaysAcknowledgementAndFreshFaultedEpochApproves() throws {
            let slots = try kernelCycleTelemetrySlots()
            let rig = try CycleRig(telemetry: KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 0))
            #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
            let observation = try #require(rig.faults.observe(CycleRig.criticalScope))
            let ticket = try rig.cycle.ackRequests.request(for: observation)
            #expect(ticket.epoch == 1 && rig.cycle.ackRequests.lastRequested == 1)
            #expect(rig.cycle.latestTelemetry() == nil && !KernelCycleTelemetry().permitsAcknowledgement(ticket))
            let stale = KernelCycleTelemetry(cycle: 9, lastFaultedCycle: 9, ackEpochSeen: 0, lastFaultedAckEpoch: 0)
            #expect(!stale.permitsAcknowledgement(ticket) && stale.lastFaultedAckEpoch == 0)
            #expect(rig.run(0, 64).0.status == .silenced(.scopeFaulted))
            let fresh = try #require(rig.cycle.latestTelemetry()).value
            #expect(fresh.ackEpochSeen == 1 && fresh.lastFaultedAckEpoch == 1 && fresh.permitsAcknowledgement(ticket))
            // A second request; the front sample stays cached (nothing published since) and must not approve it.
            let second = try rig.cycle.ackRequests.request(for: observation)
            for _ in 0..<3 {
                let cached = try #require(rig.cycle.latestTelemetry()).value
                #expect(cached == fresh && !cached.permitsAcknowledgement(second))
            }
            #expect(rig.run(64, 64).0.status == .silenced(.scopeFaulted))
            let approving = try #require(rig.cycle.latestTelemetry()).value
            #expect(approving.permitsAcknowledgement(second) && approving.lastFaultedAckEpoch == 2)
            #expect(try rig.cycle.acknowledgeCritical(observation, second) == observation.record)
            // An unsilenced cycle sees a newer epoch but is no faulted cycle, so it never approves.
            let third = try rig.cycle.ackRequests.request(for: observation)
            #expect(rig.run(128, 64).0.status == .ok)
            let quiet = try #require(rig.cycle.latestTelemetry()).value
            #expect(quiet.ackEpochSeen == 3 && quiet.lastFaultedAckEpoch == 2 && !quiet.permitsAcknowledgement(third))
        }

        /// Render loads the epoch before the latch: a request made mid-cycle (here from `emit`, after the latch
        /// read) is not covered by that cycle, only by the next. Kills: the epoch loaded after the latch read.
        @Test func requestAfterTheLatchReadWaitsForTheNextFaultedCycle() throws {
            let slots = try kernelCycleTelemetrySlots()
            let rig = try CycleRig(telemetry: KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 0))
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(0, noteOn(4)), token) == .ok)
            #expect(rig.run(0, 64).1.count == 1)
            #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 64) == .ok)
            let observation = try #require(rig.faults.observe(CycleRig.criticalScope))
            var ticket: KernelAckTicket?
            let result = rig.cycle.run(blockStart: 64, frames: 64) { _, _ in
                if ticket == nil { ticket = try? rig.cycle.ackRequests.request(for: observation) }
            }
            #expect(result.status == .silenced(.scopeFaulted) && result.releasedNotes == 1)
            guard let midCycle = ticket.take() else { throw CycleOrderingTicketMissing() }
            let early = try #require(rig.cycle.latestTelemetry()).value.permitsAcknowledgement(midCycle)
            #expect(rig.run(128, 64).0.status == .silenced(.scopeFaulted))
            let next = try #require(rig.cycle.latestTelemetry()).value.permitsAcknowledgement(midCycle)
            #expect(!early && next)
        }

        /// (b) The review's counterexample, cycle by cycle: control acknowledges F1, a producer queues `noteOn(X)`
        /// and its `noteOff` is refused (F2), control observes F2 but reads a stale sample. The old criterion
        /// (a faulted cycle two past the stale read cycle) approves at once and X sounds and sticks; the epoch
        /// refuses until a faulted cycle loaded F2's epoch, which drains and discards X.
        @Test func staleReadAfterReRaiseCannotLetAQueuedNoteOnSound() throws {
            for oldCriterion in [true, false] {
                let slots = try kernelCycleTelemetrySlots()
                let rig = try CycleRig(telemetry: KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 0))
                let token = try #require(rig.events.claimProducer())
                #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok)
                let first = try #require(rig.faults.observe(CycleRig.criticalScope))
                let firstTicket = try rig.cycle.ackRequests.request(for: first)
                #expect(rig.run(0, 64).0.status == .silenced(.scopeFaulted))
                let staleRead = try #require(rig.cycle.latestTelemetry()).value
                #expect(staleRead.permitsAcknowledgement(firstTicket) && staleRead.lastFaultedAckEpoch == 1)
                for block in Int64(1)...2 { #expect(rig.run(block * 64, 64).0.status == .silenced(.scopeFaulted)) }
                #expect(rig.faults.acknowledge(first) != nil)
                #expect(rig.push(cycleEvent(192, noteOn(9)), token) == .ok)
                #expect(rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 192) == .ok)
                let second = try #require(rig.faults.observe(CycleRig.criticalScope))
                let secondTicket = try rig.cycle.ackRequests.request(for: second)
                let now = try #require(rig.cycle.latestTelemetry()).value
                #expect(now.lastFaultedCycle >= staleRead.cycle + 2 && !now.permitsAcknowledgement(secondTicket))
                if oldCriterion { #expect(rig.faults.acknowledge(second) != nil) }
                var sounded = false
                for block in Int64(3)...6 {
                    let (result, emitted) = rig.run(block * 64, 64)
                    sounded = sounded || emitted.contains { $0.event.payload == noteOn(9) }
                    if !oldCriterion, result.status != .ok {
                        #expect(result.discardedWhileSilenced == 1)
                        let sample = try #require(rig.cycle.latestTelemetry()).value
                        #expect(sample.permitsAcknowledgement(secondTicket) && sample.lastFaultedAckEpoch == 2)
                        #expect(rig.faults.acknowledge(second) != nil)
                    }
                }
                #expect(sounded == oldCriterion && rig.ownership.isOwned(scope: 0, channel: 0, note: 9) == oldCriterion)
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

        /// Kills: `lastAdmittedFrame` advanced by a refused or full push; admission skipped; lookahead not checked
        /// first; equal frames refused.
        @Test func admissionAdvancesOnlyOnSuccessfulPush() throws {
            let rig = try CycleRig(lanes: 1, laneCapacity: 20)
            let token = try #require(rig.events.claimProducer())
            var admission = ProducerAdmission(deadline: rig.cycle.deadline, refusals: rig.cycle.admissionRefusals)
            func push(_ frame: Int64, _ payload: KernelEventPayload, now: Int64 = 0) -> KernelStatus {
                admission.push(cycleEvent(frame, payload), now: now, into: rig.events, token: token)
            }
            #expect(push(100, control(0)) == .ok && admission.lastAdmittedFrame == 100)
            #expect(push(99, control(1)) == .refused(.nonMonotonic))
            #expect(push(96_001, control(2)) == .refused(.beyondLookahead))
            #expect(push(50, control(3), now: -96_000) == .refused(.beyondLookahead))
            #expect(admission.lastAdmittedFrame == 100)
            #expect(push(96_000, control(4)) == .ok && push(96_000, noteOff(1)) == .ok)
            #expect(push(96_000, control(5)) == .ok)
            #expect(push(96_001, control(7), now: 96_001) == .refused(.full))
            #expect(admission.lastAdmittedFrame == 96_000)
            let (result, emitted) = rig.run(0, 200)
            #expect(emitted.map(\.event.payload) == [control(0)] && result.drained == 4 && result.pending == 3)
        }

        /// Kills: no reset (an earlier frame after a relocation is refused), or a reset that also bypasses the
        /// lookahead; render re-queueing a reset producer's earlier frame instead of ordering it first.
        @Test func discontinuityResetAdmitsEarlierFramesOrderedFirst() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            var admission = ProducerAdmission(deadline: rig.cycle.deadline, refusals: rig.cycle.admissionRefusals)
            #expect(admission.push(cycleEvent(1_000, noteOn(60)), now: 0, into: rig.events, token: token) == .ok)
            #expect(admission.push(cycleEvent(10, noteOn(61)), now: 0, into: rig.events, token: token)
                    == .refused(.nonMonotonic))
            admission.resetForDiscontinuity()
            #expect(admission.lastAdmittedFrame == nil)
            #expect(admission.push(cycleEvent(96_001, noteOn(62)), now: 0, into: rig.events, token: token)
                    == .refused(.beyondLookahead))
            #expect(admission.push(cycleEvent(10, noteOn(61)), now: 0, into: rig.events, token: token) == .ok)
            #expect(admission.push(cycleEvent(20, noteOff(61)), now: 0, into: rig.events, token: token) == .ok)
            let (first, emitted) = rig.run(0, 64)
            #expect(emitted.map(\.event.frame) == [10, 20] && first.pending == 1)
            let (late, nothing) = rig.run(2_000, 64)
            #expect(late.droppedLate == 1 && nothing.isEmpty && rig.ownership.ownedCount(scope: 0) == 0)
        }
    }
}
