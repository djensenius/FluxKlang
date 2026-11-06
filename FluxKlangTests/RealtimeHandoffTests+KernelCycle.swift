import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Root = RealtimeHandoffTests

/// One `emit` call: the event and the frame it was dispatched at.
struct CycleEmission: Equatable {
    let event: KernelEvent
    let frame: Int64
}

/// A `KernelCycle` over a fan-in, its latch and two ownership/safety scopes. Shared with
/// `RealtimeHandoffTests+KernelCycleStress.swift`.
struct CycleRig {
    static let criticalScope = FaultScope(handoff: 64, target: 5)
    static let slotsScope = FaultScope(handoff: 64, target: 6)
    /// A neighbouring scope on the same latch, as a SysEx assembler would use.
    static let sysexScope = FaultScope(handoff: 65, target: 0)

    let faults: FaultLatch
    let events: FanInHandoff<KernelEvent>
    let ownership: NoteOwnership
    let safety: SafetyFlags
    let ramps: RampSlots
    let cycle: KernelCycle

    init(lanes: Int = 2, laneCapacity: Int = 20, blockCapacity: Int = 64, pulsesPerBlock: Int = 4,
         staleTolerance: Int64 = 48, perLaneQuota: Int = 64, telemetry: KernelCycleTelemetryOutput? = nil) throws {
        faults = try FaultLatch(scopes: [Self.criticalScope, Self.slotsScope, Self.sysexScope])
        events = try FanInHandoff(policy: Self.policy(lanes: lanes, laneCapacity: laneCapacity),
                                  laneCapacity: laneCapacity, reserved: 16, faults: faults,
                                  criticalScope: Self.criticalScope, producerSlotsScope: Self.slotsScope)
        ownership = try NoteOwnership(scopes: 2)
        safety = try SafetyFlags(scopes: 2)
        ramps = try RampSlots(parameterCount: 4)
        let parts = KernelCycleParts(events: events, faults: faults, ownership: ownership, safety: safety,
                                     ramps: ramps, telemetry: telemetry, start: .freshFanIn)
        cycle = try KernelCycle(parts, pulses: ClockPulseGate(maximumPulsesPerBlock: pulsesPerBlock,
                                                              staleTolerance: staleTolerance),
                                blockCapacity: blockCapacity, perLaneQuota: perLaneQuota)
    }

    /// A MIDI-receive fan-in to render with a 480-frame tolerance and a 96,000-frame lookahead.
    static func policy(lanes: Int = 2, laneCapacity: Int = 20, consumer: ExecutionContext = .render) -> HandoffPolicy {
        Root.policy(producer: .midiReceive,
                    producers: ProducerCardinality(maximum: lanes,
                                                   evidence: lanes == 1 ? .verified : .assumedConservative),
                    consumer: consumer, capacity: laneCapacity &* lanes, ordering: .fifoPerProducer,
                    overflow: .reservedCritical(reserved: 16 &* lanes))
    }

    func push(_ event: KernelEvent, _ token: ProducerToken) -> KernelStatus {
        events.tryPush(event, class: event.eventClass, frame: event.frame, token: token)
    }

    /// Runs one cycle and returns its result with everything it emitted.
    func run(_ blockStart: Int64, _ frames: Int64) -> (KernelCycleResult, [CycleEmission]) {
        var emitted: [CycleEmission] = []
        let result = cycle.run(blockStart: blockStart, frames: frames) {
            emitted.append(CycleEmission(event: $0, frame: $1))
        }
        return (result, emitted)
    }
}

/// An event at `frame` with `payload`.
func cycleEvent(_ frame: Int64, _ payload: KernelEventPayload, scope: UInt32 = 0, sequence: UInt64 = 0) -> KernelEvent {
    KernelEvent(frame: frame, scope: scope, sequence: sequence, payload: payload)
}

private func noteOn(_ note: UInt8) -> KernelEventPayload { .noteOn(channel: 0, note: note, velocity: 100) }
private func noteOff(_ note: UInt8) -> KernelEventPayload { .noteOff(channel: 0, note: note) }
private func control(_ value: UInt32) -> KernelEventPayload { .control(channel: 0, controller: 7, value: value) }

private func preparationError(_ make: () throws(KernelCycle.PreparationError) -> KernelCycle)
    -> KernelCycle.PreparationError? {
    do {
        _ = try make()
        return nil
    } catch {
        return error
    }
}

extension RealtimeHandoffTests {
    struct CycleRules {
        @Test func preparationRefusesInvalidShapes() throws {
            let rig = try CycleRig()
            let gate = try ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 0)
            let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership,
                                         safety: rig.safety, ramps: rig.ramps)
            for capacity in [0, -1, KernelCycle.maximumBlockCapacity + 1] {
                #expect(preparationError { () throws(KernelCycle.PreparationError) in
                    try KernelCycle(parts, pulses: gate, blockCapacity: capacity, perLaneQuota: 1)
                } == .blockCapacityOutOfRange(capacity))
            }
            #expect(preparationError { () throws(KernelCycle.PreparationError) in
                try KernelCycle(parts, pulses: gate, blockCapacity: KernelCycle.maximumBlockCapacity, perLaneQuota: 0)
            } == .perLaneQuotaOutOfRange(0))
            let wide = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership,
                                        safety: try SafetyFlags(scopes: 3), ramps: rig.ramps)
            #expect(preparationError { () throws(KernelCycle.PreparationError) in
                try KernelCycle(wide, pulses: gate, blockCapacity: 1, perLaneQuota: 1)
            } == .scopeCountMismatch(ownership: 2, safety: 3))
            let control = try FanInHandoff<KernelEvent>(
                policy: CycleRig.policy(consumer: .control), laneCapacity: 20, reserved: 16, faults: rig.faults,
                criticalScope: CycleRig.criticalScope, producerSlotsScope: CycleRig.slotsScope)
            let off = KernelCycleParts(events: control, faults: rig.faults, ownership: rig.ownership,
                                       safety: rig.safety, ramps: rig.ramps)
            #expect(preparationError { () throws(KernelCycle.PreparationError) in
                try KernelCycle(off, pulses: gate, blockCapacity: 1, perLaneQuota: 1)
            } == .notRenderEvents)
            #expect(rig.cycle.deadline == (try DeadlinePolicy(lateTolerance: 480, lookahead: 96_000)))
        }

        /// Kills: release not first at a frame; producer or sequence ignored; drain order kept instead of frame.
        @Test func blockOrderIsFrameLaneProducerSequence() throws {
            let rig = try CycleRig()
            let first = try #require(rig.events.claimProducer())
            let second = try #require(rig.events.claimProducer())
            for (event, token) in [
                (cycleEvent(50, control(1), sequence: 9), second), (cycleEvent(100, noteOn(61), sequence: 1), second),
                (cycleEvent(100, control(2), sequence: 2), second), (cycleEvent(100, noteOff(60), sequence: 3), first),
                (cycleEvent(100, .clockPulse, sequence: 4), first), (cycleEvent(100, noteOn(62), sequence: 7), first),
                (cycleEvent(100, noteOn(63), sequence: 5), first)
            ] {
                #expect(rig.push(event, token) == .ok)
            }
            let (result, emitted) = rig.run(0, 128)
            #expect(emitted.map(\.event.sequence) == [9, 3, 4, 2, 5, 7, 1])
            #expect(emitted.map(\.frame) == [50, 100, 100, 100, 100, 100, 100])
            #expect(result.drained == 7 && result.dispatched == 7 && result.pending == 0 && result.status == .ok)
        }

        /// E2 review P2-3. Kills: sorting by the decided frame, which puts the release lane's `noteOff` (999)
        /// before the `noteOn` (990) when both collapse onto `blockStart`, leaving the note stuck.
        @Test func lateEventsKeepOriginalFrameOrder() throws {
            let rig = try CycleRig()
            let release = try #require(rig.events.claimProducer())
            let content = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(999, noteOff(60)), release) == .ok)
            #expect(rig.push(cycleEvent(990, noteOn(60)), content) == .ok)
            let (result, emitted) = rig.run(1_000, 64)
            #expect(emitted == [CycleEmission(event: cycleEvent(990, noteOn(60)), frame: 1_000),
                                CycleEmission(event: cycleEvent(999, noteOff(60)), frame: 1_000)])
            #expect(result.dispatched == 2 && result.droppedLate == 0)
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 60))
        }

        /// Kills: a dropped late note not counted; a late release, state or ramp dropped; a dropped note owned.
        @Test func lateNoteBeyondToleranceDroppedAndCounted() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            let ramp = KernelEventPayload.rampTo(parameter: 0, value: 1, durationFrames: 0)
            for event in [cycleEvent(0, control(3)), cycleEvent(10, noteOff(61)), cycleEvent(519, noteOn(60)),
                          cycleEvent(520, noteOn(62)), cycleEvent(521, ramp)] {
                #expect(rig.push(event, token) == .ok)
            }
            let (result, emitted) = rig.run(1_000, 64)
            #expect(result.droppedLate == 1 && result.dispatched == 4 && result.refused == 0)
            #expect(emitted.map(\.frame) == [1_000, 1_000, 1_000, 1_000])
            #expect(!emitted.contains { $0.event.frame == 519 })
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 60))
            #expect(rig.ownership.isOwned(scope: 0, channel: 0, note: 62))
            #expect(rig.cycle.parameterValue(0) == 1)
        }

        /// Kills: future events dropped, dispatched early or lost from the buffer.
        @Test func futureEventsWaitInTheBlockBuffer() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(200, noteOn(60)), token) == .ok)
            let (early, none) = rig.run(0, 128)
            #expect(early.drained == 1 && early.pending == 1 && early.dispatched == 0 && none.isEmpty)
            let (due, emitted) = rig.run(128, 128)
            #expect(due.drained == 0 && due.pending == 0 && emitted.map(\.frame) == [200])
            #expect(rig.ownership.isOwned(scope: 0, channel: 0, note: 60))
        }

        /// Kills: empty cycles draining or deciding timed events; safety skipped on an empty cycle.
        @Test func emptyCyclesDecideNothingButApplySafety() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(0, noteOn(60)), token) == .ok)
            #expect(rig.run(0, 64).0.dispatched == 1)
            #expect(rig.push(cycleEvent(64, .clockPulse), token) == .ok)
            #expect(rig.safety.request(.allNotesOff, scope: 0) == .ok)
            for frames in [0, -1, Int64.min] {
                let (result, emitted) = rig.run(64, frames)
                #expect(result.drained == 0 && result.dispatched == 0 && result.status == .ok)
                #expect(emitted.allSatisfy { $0.event.sequence == KernelCycle.releaseSequence })
            }
            #expect(rig.ownership.ownedCount(scope: 0) == 0)
            #expect(rig.cycle.pulses.skippedStale == 0 && rig.cycle.pulses.rateLimited == 0)
            let (result, emitted) = rig.run(64, 64)
            #expect(result.dispatched == 1 && emitted.map(\.event.payload) == [.clockPulse])
        }

        /// Kills: CC or program merging, reordering or deduplication.
        @Test func statefulEventsDispatchedUncoalescedInOrder() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            let payloads: [KernelEventPayload] = [control(1), control(1), control(2),
                                                  .program(channel: 0, program: 3, bank: 0), control(1),
                                                  .program(channel: 0, program: 3, bank: 0)]
            for (index, payload) in payloads.enumerated() {
                #expect(rig.push(cycleEvent(10, payload, sequence: UInt64(index)), token) == .ok)
            }
            let (result, emitted) = rig.run(0, 64)
            #expect(emitted.map(\.event.payload) == payloads && result.dispatched == payloads.count)
        }

        /// Kills: a resync per block during a stall; a lost marker; no re-arm after a clean block.
        @Test func continuousStallEmitsOneResyncMarker() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            var markers: [Bool] = []
            for block in Int64(0)..<3 {
                for pulse in Int64(0)..<3 { _ = rig.push(cycleEvent(block * 3 + pulse, .clockPulse), token) }
                let (result, emitted) = rig.run(10_000 + block * 64, 64)
                #expect(result.skippedPulses == 3 && emitted.isEmpty)
                markers.append(result.resync)
            }
            #expect(markers == [true, false, false])
            #expect(rig.push(cycleEvent(10_200, .clockPulse), token) == .ok)
            let (clean, pulses) = rig.run(10_192, 64)
            #expect(!clean.resync && pulses.count == 1)
            #expect(rig.push(cycleEvent(10, .clockPulse), token) == .ok)
            #expect(rig.run(10_256, 64).0.resync)
            #expect(rig.cycle.pulses.skippedStale == 10)
        }

        /// Kills: unbounded pulse emission per block.
        @Test func pulsesRateLimitedPerBlock() throws {
            let rig = try CycleRig(laneCapacity: 32, pulsesPerBlock: 2)
            let token = try #require(rig.events.claimProducer())
            for frame in Int64(0)..<5 { #expect(rig.push(cycleEvent(frame, .clockPulse), token) == .ok) }
            let (result, emitted) = rig.run(0, 64)
            #expect(result.dispatched == 2 && result.skippedPulses == 3 && emitted.count == 2 && result.resync)
            #expect(rig.cycle.pulses.rateLimited == 3)
        }

        /// Kills: a ramp replaced from its start or end instead of its value at the dispatch frame; ramps queued;
        /// a refused ramp dispatched.
        @Test func rampsReplaceFromValueAtDispatchFrame() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(0, .rampTo(parameter: 1, value: 1, durationFrames: 200)), token) == .ok)
            #expect(rig.run(0, 100).0.dispatched == 1)
            #expect(rig.cycle.parameterValue(1) == 0.5)
            #expect(rig.push(cycleEvent(150, .rampTo(parameter: 1, value: 0, durationFrames: 100)), token) == .ok)
            for index in 0..<10 {
                let ramp = KernelEventPayload.rampTo(parameter: 2, value: Float(index), durationFrames: 1_000)
                #expect(rig.push(cycleEvent(160, ramp), token) == .ok)
            }
            #expect(rig.push(cycleEvent(170, .rampTo(parameter: 9, value: 1, durationFrames: 1)), token) == .ok)
            #expect(rig.push(cycleEvent(171, .rampTo(parameter: 3, value: .nan, durationFrames: 1)), token) == .ok)
            let (result, emitted) = rig.run(100, 100)
            #expect(rig.cycle.parameterValue(1) == 0.375)
            #expect(rig.ramps.activeCount == 2 && result.dispatched == 11 && result.refused == 2)
            #expect(emitted.count == 11 && rig.cycle.parameterValue(9) == nil && rig.cycle.parameterValue(3) == 0)
            #expect(rig.run(200, 100).0.status == .ok && rig.cycle.parameterValue(1) == 0)
        }

        /// Kills: no release on critical loss; a silenced cycle that stops draining, emits unowned releases or drops
        /// state; auto-clear without acknowledgement; permanent mute.
        @Test func latchedCriticalFaultReleasesOwnedNotesUntilAcknowledged() throws {
            let rig = try CycleRig(lanes: 1, laneCapacity: 17)
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(0, noteOn(60), scope: 1), token) == .ok)
            #expect(rig.run(0, 64).0.dispatched == 1)
            for note in UInt8(0)..<17 { #expect(rig.push(cycleEvent(64, noteOff(note)), token) == .ok) }
            #expect(rig.push(cycleEvent(64, noteOff(17)), token) == .refused(.criticalExhausted))
            let (faulted, released) = rig.run(64, 64)
            #expect(faulted.status == .silenced(.scopeFaulted) && faulted.releasedNotes == 1)
            #expect(faulted.drained == 17 && faulted.discardedWhileSilenced == 17 && faulted.dispatched == 0)
            #expect(released == [CycleEmission(event: KernelEvent(frame: 64, scope: 1, sequence: .max,
                                                                  payload: noteOff(60)), frame: 64)])
            #expect(rig.push(cycleEvent(128, control(5)), token) == .ok)
            let (still, nothing) = rig.run(128, 64)
            #expect(still.status == .silenced(.scopeFaulted) && nothing.isEmpty)
            #expect(still.drained == 1 && still.pending == 1 && still.dispatched == 0)
            // Control observes, recovers the scope and acknowledges; only then does the cycle resume.
            let observation = try #require(rig.faults.observe(CycleRig.criticalScope))
            #expect(observation.record.kind == .criticalExhausted)
            #expect(rig.faults.acknowledge(observation) != nil)
            let (resumed, late) = rig.run(192, 64)
            #expect(resumed.status == .ok && resumed.dispatched == 1 && resumed.pending == 0)
            #expect(late == [CycleEmission(event: cycleEvent(128, control(5)), frame: 192)])
        }

        /// Kills: panic depending on queue capacity; allNotesOff muting; a mute that outlives its cycle.
        @Test func panicFlagReleasesAllOwnedNotesEvenWhenQueuesFull() throws {
            let rig = try CycleRig(lanes: 1, laneCapacity: 17)
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(0, noteOn(60), scope: 0), token) == .ok)
            #expect(rig.run(0, 64).0.dispatched == 1)
            #expect(rig.push(cycleEvent(64, noteOn(61), scope: 1), token) == .ok)
            #expect(rig.run(64, 64).0.dispatched == 1)
            #expect(rig.push(cycleEvent(128, control(1)), token) == .ok)
            #expect(rig.push(cycleEvent(128, control(2)), token) == .refused(.full))
            #expect(rig.safety.request(.panic, scope: 0) == .ok)
            #expect(rig.safety.request(.allNotesOff, scope: 1) == .ok)
            let (muted, released) = rig.run(128, 64)
            #expect(muted.status == .silenced(.safetyMute) && muted.releasedNotes == 2)
            #expect(muted.drained == 1 && muted.pending == 1 && muted.dispatched == 0)
            #expect(released.count == 2 && rig.ownership.ownedCount(scope: 0) + rig.ownership.ownedCount(scope: 1) == 0)
            #expect(rig.safety.request(.allNotesOff, scope: 1) == .ok)
            let (resumed, emitted) = rig.run(192, 64)
            #expect(resumed.status == .ok && resumed.dispatched == 1 && emitted.map(\.frame) == [192])
        }

        /// E4 interaction. SysEx never drains on render (R5), so its faults latch only its own scope. Kills: a
        /// cycle silenced by a neighbouring scope on the same latch.
        @Test func sysexFaultsOnTheirScopeDoNotSilenceTheCycle() throws {
            #expect(Root.violation(Root.policy(purpose: .sysex, producer: .midiReceive,
                                               producers: .init(maximum: 1, evidence: .verified),
                                               consumer: .render, ordering: .completeMessagesFIFO))
                    == .r5TelemetryNotRender)
            let rig = try CycleRig()
            let ring = try SPSCRing<SysExMessageRef>(policy: Root.policy(
                purpose: .sysex, producer: .midiReceive, producers: .init(maximum: 1, evidence: .verified),
                consumer: .control, capacity: 4, ordering: .completeMessagesFIFO, deadline: .none))
            let sysex = try SysExAssembler(sources: 1, maximumMessageBytes: 4, poolBytes: 8, output: ring,
                                           faults: rig.faults, scopeBase: CycleRig.sysexScope.handoff)
            #expect(sysex.accept(source: 0, status: .complete, bytes: (1, 2, 3, 4, 5, 6), count: 6)
                    == .refused(.invalidLength))
            #expect(rig.faults.isLatched(CycleRig.sysexScope) && !rig.faults.isLatched(CycleRig.criticalScope))
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(0, noteOn(60)), token) == .ok)
            let (result, emitted) = rig.run(0, 64)
            #expect(result.status == .ok && result.dispatched == 1 && emitted.count == 1 && ring.tryPop() == nil)
        }

        /// Kills: overfilling the block buffer; losing events the buffer had no room for.
        @Test func blockBufferIsBoundedAndLanesWait() throws {
            let rig = try CycleRig(laneCapacity: 32, blockCapacity: 4)
            let token = try #require(rig.events.claimProducer())
            for note in UInt8(0)..<10 { #expect(rig.push(cycleEvent(1_000 + Int64(note), noteOn(note)), token) == .ok) }
            let (first, _) = rig.run(0, 64)
            #expect(first.drained == 4 && first.pending == 4)
            let (full, _) = rig.run(64, 64)
            #expect(full.drained == 0 && full.pending == 4)
            var frames: [Int64] = []
            for block in Int64(0)..<4 {
                let (result, emitted) = rig.run(1_000 + block * 16, 16)
                #expect(result.pending <= 4 && result.droppedLate == 0)
                frames += emitted.map(\.frame)
            }
            #expect(frames == [1_000, 1_001, 1_002, 1_003, 1_016, 1_016, 1_016, 1_016, 1_032, 1_032])
            #expect(rig.ownership.ownedCount(scope: 0) == 10)
        }

        /// Kills: arithmetic traps at `Int64` extremes, negative or huge frames, and refused-scope notes owned.
        @Test func adversarialBlocksNeverTrap() throws {
            let rig = try CycleRig(blockCapacity: 8)
            let token = try #require(rig.events.claimProducer())
            var pushed = 0
            var counted = 0
            for blockStart in Root.adversarialFrames {
                for frames in Root.adversarialInts.map(Int64.init) + [Int64.max] {
                    for frame in [Int64.min, blockStart, .max] {
                        let ramp = KernelEventPayload.rampTo(parameter: 0, value: 1, durationFrames: frame)
                        for payload in [ramp, noteOn(1), .clockPulse]
                        where rig.push(cycleEvent(frame, payload, scope: 7), token) == .ok {
                            pushed += 1
                        }
                    }
                    let (result, _) = rig.run(blockStart, frames)
                    counted += result.dispatched + result.droppedLate + result.refused + result.skippedPulses
                        + result.discardedWhileSilenced
                }
            }
            // Whatever the cycle has not decided is still buffered or still in the lane.
            counted += rig.cycle.bufferedCount + rig.events.drain(perLaneQuota: 64, total: 1_024) { _, _ in }
            #expect(pushed == counted)
            #expect(rig.ownership.ownedCount(scope: 0) == 0 && rig.ownership.ownedCount(scope: 1) == 0)
        }
    }

    struct CycleRecovery {
        /// Review finding 1. Kills: ordering only the newly drained run, leaving late events behind a kept future
        /// `noteOn` (nothing is decided, and the late `noteOn` would later sound after its `noteOff`).
        @Test func lateDrainMergesAheadOfKeptFutureEvents() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(1_000, noteOn(70)), token) == .ok)
            #expect(rig.run(0, 64).0.pending == 1)
            #expect(rig.push(cycleEvent(10, noteOn(60)), token) == .ok)
            #expect(rig.push(cycleEvent(5, noteOff(61)), token) == .ok)
            let (result, emitted) = rig.run(64, 64)
            #expect(emitted == [CycleEmission(event: cycleEvent(5, noteOff(61)), frame: 64),
                                CycleEmission(event: cycleEvent(10, noteOn(60)), frame: 64)])
            #expect(result.drained == 2 && result.dispatched == 2 && result.pending == 1)
            #expect(rig.run(1_000, 64).1 == [CycleEmission(event: cycleEvent(1_000, noteOn(70)), frame: 1_000)])
        }

        /// Review finding 2. Kills: a silenced cycle that leaves a queued `noteOn` in the lane, so it sounds after
        /// acknowledgement although its `noteOff` was refused (stuck note).
        @Test func noteQueuedBeforeLostReleaseNeverSoundsAfterAcknowledgement() throws {
            let rig = try CycleRig(lanes: 1, laneCapacity: 17)
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(0, noteOn(60)), token) == .ok)
            for note in UInt8(0)..<16 { #expect(rig.push(cycleEvent(1, noteOff(note), scope: 1), token) == .ok) }
            #expect(rig.push(cycleEvent(2, noteOff(60)), token) == .refused(.criticalExhausted))
            let (faulted, emitted) = rig.run(64, 64)
            #expect(faulted.status == .silenced(.scopeFaulted) && emitted.isEmpty)
            #expect(faulted.drained == 17 && faulted.discardedWhileSilenced == 17 && faulted.pending == 0)
            let observation = try #require(rig.faults.observe(CycleRig.criticalScope))
            #expect(rig.faults.acknowledge(observation) != nil)
            for block in Int64(2)..<5 {
                let (result, after) = rig.run(block * 64, 64)
                #expect(result.status == .ok && result.dispatched == 0 && after.isEmpty)
            }
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 60) && rig.ownership.ownedCount(scope: 0) == 0)
        }

        /// Round 3 finding 1. A full buffer leaves the latched cycle no room to drain, and control acknowledges at
        /// once. Kills: clearing the flush bits on acknowledgement (the queued `noteOn` would sound late and stick).
        @Test func flushWatermarkOutlivesEarlyAcknowledgement() throws {
            let rig = try CycleRig(lanes: 1, laneCapacity: 17, blockCapacity: 4)
            let token = try #require(rig.events.claimProducer())
            for block in Int64(0)..<4 {
                #expect(rig.push(cycleEvent(600, control(UInt32(block))), token) == .ok)
                #expect(rig.run(block * 64, 64).0.pending == Int(block) + 1)
            }
            #expect(rig.push(cycleEvent(300, noteOn(60)), token) == .ok)
            for note in UInt8(0)..<16 { #expect(rig.push(cycleEvent(301, noteOff(note), scope: 1), token) == .ok) }
            #expect(rig.push(cycleEvent(302, noteOff(60)), token) == .refused(.criticalExhausted))
            let (faulted, _) = rig.run(256, 64)
            #expect(faulted.status == .silenced(.scopeFaulted) && faulted.drained == 0 && faulted.flushing)
            #expect(rig.faults.acknowledge(try #require(rig.faults.observe(CycleRig.criticalScope))) != nil)
            // The controls dispatch at 576; from 640 the lane drains 4 a cycle, `noteOn(60)` first and 340 late.
            var emitted: [CycleEmission] = []
            var discarded = 0
            var last: KernelCycleResult?
            for block in Int64(5)..<24 {
                let cycle = rig.run(block * 64, 64)
                last = cycle.0
                emitted += cycle.1
                discarded &+= cycle.0.discardedWhileSilenced
            }
            let result = try #require(last)
            #expect(!result.flushing && result.pending == 0 && discarded == 1)
            #expect(rig.events.drain(perLaneQuota: 1, total: 1) { _, _ in } == 0)
            #expect(emitted.filter { $0.event.payload == control(0) }.count == 1)
            #expect(!emitted.contains { $0.event.payload == noteOn(60) })
            #expect(!rig.ownership.isOwned(scope: 0, channel: 0, note: 60) && rig.ownership.ownedCount(scope: 0) == 0)
        }

        /// Owner decision: panic flushes the backlog. Kills: a buffered or just-drained `noteOn` sounding after a
        /// panic; a panic dropping state events; an owned release swallowed.
        @Test func panicDiscardsBufferedNoteOnsAndKeepsState() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(0, noteOn(50), scope: 1), token) == .ok)
            #expect(rig.push(cycleEvent(1_000, noteOn(60)), token) == .ok)
            #expect(rig.run(0, 64).0.pending == 1)
            for event in [cycleEvent(500, noteOn(61)), cycleEvent(600, noteOff(50), scope: 1),
                          cycleEvent(700, noteOff(62)), cycleEvent(1_000, control(9))] {
                #expect(rig.push(event, token) == .ok)
            }
            #expect(rig.safety.request(.panic, scope: 0) == .ok)
            let (muted, emitted) = rig.run(64, 64)
            #expect(muted.status == .silenced(.safetyMute) && muted.drained == 4 && muted.pending == 1)
            #expect(muted.discardedWhileSilenced == 3 && muted.dispatched == 1 && muted.releasedNotes == 0)
            #expect(emitted == [CycleEmission(event: cycleEvent(600, noteOff(50), scope: 1), frame: 64)])
            let (later, sounded) = rig.run(1_000, 64)
            #expect(later.status == .ok && sounded.map(\.event.payload) == [control(9)])
            #expect(rig.ownership.ownedCount(scope: 0) == 0 && rig.ownership.ownedCount(scope: 1) == 0)
        }

        /// Review finding 6, pinned: the E2 key orders a same-frame `noteOff` (release lane) before its `noteOn`
        /// (content lane); round 4b's tie rule treats the `noteOn` as a retrigger, so a zero-length note sounds and
        /// stays owned. Producers must not send zero-length notes.
        @Test func zeroLengthNoteFromOneProducerIsReleaseFirst() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            #expect(rig.push(cycleEvent(100, noteOn(60), sequence: 0), token) == .ok)
            #expect(rig.push(cycleEvent(100, noteOff(60), sequence: 1), token) == .ok)
            let (result, emitted) = rig.run(64, 64)
            #expect(emitted.map(\.event.sequence) == [1, 0] && result.discardedSuperseded == 0)
            #expect(rig.ownership.isOwned(scope: 0, channel: 0, note: 60))
        }
    }
}
