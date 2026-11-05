import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The block-order key of an emitted event the cycle did not synthesize: its original frame, lane, producer lane
/// (the high half of `sequence`) and sequence.
private struct OrderKey: Comparable {
    let frame: Int64
    let lane: UInt8
    let producer: UInt64
    let index: UInt64

    init(_ event: KernelEvent) {
        frame = event.frame
        lane = event.lane.rawValue
        producer = event.sequence >> 32
        index = event.sequence & 0xFFFF_FFFF
    }

    static func < (lhs: OrderKey, rhs: OrderKey) -> Bool {
        (lhs.frame, lhs.lane, lhs.producer, lhs.index) < (rhs.frame, rhs.lane, rhs.producer, rhs.index)
    }
}

/// What render saw: totals, the cumulative counters telemetry must match, the ownership model rebuilt from
/// emissions, and rule breaks.
private struct OrderingModel: Sendable {
    var drained = 0
    var decided = 0
    var cycles: UInt64 = 0
    var droppedLate: UInt64 = 0
    var resyncs: UInt64 = 0
    var lastFaultedCycle: UInt64 = 0
    var discardedWhileSilenced: UInt64 = 0
    var discardedSuperseded: UInt64 = 0
    var flushingCycles = 0
    /// Bit `scope * 16 + note` set while the emissions say channel 0's `note` sounds in `scope`.
    var sounding: UInt32 = 0
    /// Emitted `noteOn(14)` or `noteOn(15)` in scope 0: one was dropped late, the other lost its release.
    var forbiddenNoteOns = 0
    var violations: [String] = []

    /// Folds one cycle in, checking block-key order, window and silence rules.
    mutating func record(_ result: KernelCycleResult, _ emitted: [CycleEmission], blockStart: Int64, frames: Int64) {
        cycles += 1
        drained += result.drained
        decided += result.dispatched + result.droppedLate + result.refused + result.skippedPulses
            + result.discardedWhileSilenced + result.discardedSuperseded
        droppedLate += UInt64(result.droppedLate)
        discardedWhileSilenced += UInt64(result.discardedWhileSilenced)
        discardedSuperseded += UInt64(result.discardedSuperseded)
        if result.resync { resyncs += 1 }
        if result.status == .silenced(.scopeFaulted) { lastFaultedCycle = cycles }
        if result.flushing { flushingCycles += 1 }
        if result.flushing, emitted.contains(where: { if case .noteOn = $0.event.payload { true } else { false } }) {
            violations.append("cycle at \(blockStart) emitted a noteOn while flushing")
        }
        if result.status != .ok, emitted.contains(where: { $0.event.lane != .release || $0.frame != blockStart }) {
            violations.append("silenced cycle at \(blockStart) emitted something other than a release")
        }
        checkEmissions(emitted, blockStart: blockStart, frames: frames)
    }

    /// Frames stay in the block and never decrease; non-synthesized emissions follow the block key.
    private mutating func checkEmissions(_ emitted: [CycleEmission], blockStart: Int64, frames: Int64) {
        var previousFrame = Int64.min
        var previousKey: OrderKey?
        for emission in emitted {
            if emission.frame < previousFrame { violations.append("emission frames decreased at \(blockStart)") }
            previousFrame = emission.frame
            if emission.frame < blockStart || emission.frame - blockStart >= max(frames, 1) {
                violations.append("emission at \(emission.frame) outside block \(blockStart)")
            }
            if emission.event.sequence != KernelCycle.releaseSequence {
                let key = OrderKey(emission.event)
                if let previousKey, !(previousKey < key) {
                    violations.append("block at \(blockStart) left (frame, lane, producer, sequence) order")
                }
                previousKey = key
            }
            apply(emission.event)
        }
    }

    mutating func apply(_ event: KernelEvent) {
        switch event.payload {
        case .noteOn(_, let note, _) where event.scope < 2:
            sounding |= Self.bit(event.scope, note)
            if event.scope == 0, note >= 14 { forbiddenNoteOns += 1 }
        case .noteOff(_, let note) where event.scope < 2:
            sounding &= ~Self.bit(event.scope, note)
        default:
            break
        }
    }

    static func bit(_ scope: UInt32, _ note: UInt8) -> UInt32 { 1 << (scope &* 16 &+ UInt32(note & 15)) }
}

/// One admitting producer's tallies.
private struct AdmittingOutcome: Sendable {
    var accepted = 0
    /// Bit `scope * 16 + note` set where this producer's last event for that note was a refused `noteOff`.
    var refusedLast: UInt32 = 0
    var resets = 0
    var beyondLookahead = 0
    /// Every admission refusal this producer saw, retries included, by kind.
    var refusedNonMonotonic: UInt64 = 0
    var refusedBeyondLookahead: UInt64 = 0
    var edgeAdmitted = false
    var violations: [String] = []

    /// Counts one push's admission refusal, if any.
    mutating func count(_ status: KernelStatus) {
        if status == .refused(.nonMonotonic) { refusedNonMonotonic += 1 }
        if status == .refused(.beyondLookahead) { refusedBeyondLookahead += 1 }
    }

    /// Checks one final push status against its frame kind (see `AdmittingSource`), then records it.
    mutating func check(_ event: KernelEvent, _ status: KernelStatus, kind: Int, now: Int64) {
        let admissionRefusal = status == .refused(.beyondLookahead) || status == .refused(.nonMonotonic)
        if kind == 0, status == .refused(.beyondLookahead) {
            beyondLookahead += 1
        } else if kind == 0 || admissionRefusal {
            violations.append("frame \(event.frame) (kind \(kind)) at \(now) returned \(status)")
        }
        if kind == -1, status == .ok { edgeAdmitted = true }
        record(event, status)
    }

    mutating func record(_ event: KernelEvent, _ status: KernelStatus) {
        if status == .ok { accepted += 1 }
        switch event.payload {
        case .noteOn(_, let note, _): refusedLast &= ~OrderingModel.bit(event.scope, note)
        case .noteOff(_, let note) where status == .ok: refusedLast &= ~OrderingModel.bit(event.scope, note)
        case .noteOff(_, let note): refusedLast |= OrderingModel.bit(event.scope, note)
        default: break
        }
    }
}

/// Producer `id` on token lane `lane`, making its events.
private struct AdmittingSource {
    let id: Int
    let lane: UInt8
    let lookahead: Int64

    /// The next event. `kind` -1 is the lookahead edge, 0 beyond it (both controls), 1 and 2 the tolerance
    /// edges, anything else 700 late to 300 ahead. The sequence's high half is the producer lane.
    func event(_ random: inout CycleRandom, kind: Int, index: Int, now: Int64) -> KernelEvent {
        let note = UInt8(id == 1 ? 8 : 0) &+ UInt8(random.next(6))
        let scope = UInt32(id == 0 ? 0 : id == 2 ? 1 : random.next(2))
        var payload: KernelEventPayload = switch random.next(8) {
        case 0, 1, 2: .noteOn(channel: 0, note: note, velocity: 90)
        case 3, 4: .noteOff(channel: 0, note: note)
        case 5: .clockPulse
        default: .control(channel: 0, controller: 7, value: UInt32(index))
        }
        let frame: Int64 = switch kind {
        case -1: now &+ lookahead
        case 0: now &+ lookahead &+ 1
        case 1: now &- 480
        case 2: now &- 481
        default: now &+ Int64(random.next(1_001)) &- 700
        }
        if kind <= 0 { payload = .control(channel: 0, controller: 9, value: UInt32(index)) }
        return cycleEvent(frame, payload, scope: scope, sequence: UInt64(lane) << 32 | UInt64(index))
    }
}

/// Producer `id` (0–2) pushes through a `ProducerAdmission`: frames from 700 late to 300 ahead, at both sides of
/// the 480-frame tolerance, beyond the lookahead (refused) and once at it. A `.nonMonotonic` refusal is a
/// discontinuity: reset and retry. Notes are disjoint per producer: 0 → scope 0 notes 0–5, 1 → both scopes notes
/// 8–13, 2 → scope 1 notes 0–5.
@Sendable private func admitAndPush(_ rig: CycleRig, _ run: CycleStressRun, id: Int, pushes: Int) -> AdmittingOutcome {
    var outcome = AdmittingOutcome()
    guard run.arriveAndWait(), let token = rig.events.claimProducer() else { return outcome }
    let deadline = ContinuousClock.now + CycleStressRun.waitLimit
    while run.cycleStarted.load(ordering: .acquiring) < 2, !run.shouldStop, ContinuousClock.now < deadline {}
    var admission = ProducerAdmission(deadline: rig.cycle.deadline, refusals: rig.cycle.admissionRefusals)
    let source = AdmittingSource(id: id, lane: token.lane, lookahead: rig.cycle.deadline.lookahead)
    var random = CycleRandom(seed: 0x5EED_0000 &+ UInt64(id) &* 0x9E37_79B9)
    for index in 0..<pushes where !run.shouldStop {
        let now = run.now.load(ordering: .relaxed)
        let kind = index == pushes / 2 ? -1 : random.next(32)
        let event = source.event(&random, kind: kind, index: index, now: now)
        var status = admission.push(event, now: now, into: rig.events, token: token)
        outcome.count(status)
        if status == .refused(.nonMonotonic) {
            admission.resetForDiscontinuity()
            outcome.resets += 1
            status = admission.push(event, now: now, into: rig.events, token: token)
            outcome.count(status)
        }
        // The lookahead edge is retried (render drains meanwhile) so every producer lands one.
        while kind == -1, status == .refused(.full), !run.shouldStop {
            status = admission.push(event, now: now, into: rig.events, token: token)
            outcome.count(status)
        }
        outcome.check(event, status, kind: kind, now: now)
    }
    run.producersDone.add(1, ordering: .releasing)
    return outcome
}

/// Runs 64-frame cycles from frame 64 until every producer is done and control has acknowledged a fault.
@Sendable private func renderCycles(_ rig: CycleRig, _ run: CycleStressRun, setup: OrderingModel,
                                    producers: Int) -> OrderingModel {
    var model = setup
    guard run.arriveAndWait() else { return model }
    let deadline = ContinuousClock.now + CycleStressRun.waitLimit
    while !run.firstObserved.load(ordering: .acquiring), !run.shouldStop, ContinuousClock.now < deadline {}
    Thread.sleep(forTimeInterval: 0.002)
    var blockStart: Int64 = 64
    while run.producersDone.load(ordering: .acquiring) < producers || run.acknowledged.load(ordering: .acquiring) == 0,
          !run.shouldStop {
        run.cycleStarted.add(1, ordering: .sequentiallyConsistent)
        let (result, emitted) = rig.run(blockStart, 64)
        model.record(result, emitted, blockStart: blockStart, frames: 64)
        blockStart &+= 64
        run.now.store(blockStart, ordering: .relaxed)
    }
    run.renderDone.store(true, ordering: .releasing)
    return model
}

/// Acknowledges each observed fault only once telemetry proves a faulted cycle began after the observation,
/// checks that the cumulative counters never go backwards, and requests safety actions.
@Sendable private func acknowledgeByTelemetry(_ rig: CycleRig, _ run: CycleStressRun,
                                              _ slots: TelemetrySlots<KernelCycleTelemetry>) -> [String] {
    var violations: [String] = []
    guard run.arriveAndWait() else { return violations }
    var random = CycleRandom(seed: 0xACC0_7E1E)
    var previous = KernelCycleTelemetry()
    func read() -> KernelCycleTelemetry {
        let value = latestCycleSample(slots)?.value ?? previous
        if value.cycle < previous.cycle || value.droppedLate < previous.droppedLate || value.resyncs
            < previous.resyncs || value.skippedStale < previous.skippedStale || value.rateLimited
            < previous.rateLimited || value.lastFaultedCycle < previous.lastFaultedCycle {
            violations.append("telemetry went backwards: \(previous) → \(value)")
        }
        previous = value
        return value
    }
    while !run.renderDone.load(ordering: .acquiring), !run.shouldStop {
        if let observation = rig.faults.observe(CycleRig.criticalScope) {
            let readCycle = read().cycle
            run.firstObserved.store(true, ordering: .releasing)
            while !read().provesFaultedCycleBegan(after: readCycle), !run.renderDone.load(ordering: .acquiring),
                  !run.shouldStop {}
            if previous.provesFaultedCycleBegan(after: readCycle), rig.faults.acknowledge(observation) != nil {
                run.acknowledged.add(1, ordering: .releasing)
            }
        }
        guard read().cycle >= 3 else { continue }
        if random.next(128) == 0 { _ = rig.safety.request(.panic, scope: UInt32(random.next(2))) }
    }
    return violations
}

extension RealtimeHandoffTests {
    @Suite(.serialized) struct CycleOrderingStress {
        /// AC1/AC2 under contention. Kills: a block that leaves (frame, lane, producer, sequence) order; a lost or
        /// doubly-counted event; an acknowledgement before a faulted cycle began after the observation (the
        /// pre-start `noteOn(15)` would sound); a stuck note after a refused release from the reserve; telemetry
        /// that diverges from the results or goes backwards; admission that refuses an admissible frame, admits
        /// one beyond the lookahead or never resets; a race TSan can see.
        @Test func admittingProducersSaturatedDeadlinesAndTelemetryHandshake() throws {
            let slots = try cycleTelemetrySlots()
            let rig = try CycleRig(lanes: 4, laneCapacity: 32, blockCapacity: 48,
                                   telemetry: KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 3))
            let setupToken = try #require(rig.events.claimProducer())
            var setupSequence: UInt64 = 0
            func setupPush(_ frame: Int64, _ payload: KernelEventPayload) -> KernelStatus {
                setupSequence += 1
                return rig.push(cycleEvent(frame, payload, sequence: setupSequence), setupToken)
            }
            // A late `noteOn(14)` dropped by a quiescent cycle; then a certain latch with `noteOn(15)` queued ahead
            // of its refused release, the general lane full and releases still taken from the reserve.
            #expect(setupPush(-10_000, .noteOn(channel: 0, note: 14, velocity: 90)) == .ok)
            var setup = OrderingModel()
            let (dropped, nothing) = rig.run(0, 64)
            setup.record(dropped, nothing, blockStart: 0, frames: 64)
            #expect(dropped.droppedLate == 1 && nothing.isEmpty)
            var accepted = 1
            #expect(setupPush(64, .noteOn(channel: 0, note: 15, velocity: 90)) == .ok)
            accepted += 1
            var status = KernelStatus.ok
            while status == .ok {
                status = setupPush(64, .control(channel: 0, controller: 7, value: 0))
                if status == .ok { accepted += 1 }
            }
            #expect(status == .refused(.full))
            var releases = 0
            status = .ok
            while status == .ok {
                status = setupPush(64, .noteOff(channel: 0, note: 7))
                if status == .ok { releases += 1 }
            }
            accepted += releases
            #expect(releases > 0 && status == .refused(.criticalExhausted))
            #expect(setupPush(65, .noteOff(channel: 0, note: 15)) == .refused(.criticalExhausted))
            #expect(rig.faults.isLatched(CycleRig.criticalScope))

            let run = CycleStressRun()
            run.now.store(64, ordering: .relaxed)
            let outcomes = CycleSlots<AdmittingOutcome>(3)
            let model = CycleSlots<OrderingModel>(1)
            let control = CycleSlots<[String]>(1)
            let frozenSetup = setup
            let workers: [@Sendable (CycleStressRun) -> Void] = [
                { outcomes.set(0, admitAndPush(rig, $0, id: 0, pushes: 12_000)) },
                { outcomes.set(1, admitAndPush(rig, $0, id: 1, pushes: 12_000)) },
                { outcomes.set(2, admitAndPush(rig, $0, id: 2, pushes: 12_000)) },
                { model.set(0, renderCycles(rig, $0, setup: frozenSetup, producers: 3)) },
                { control.set(0, acknowledgeByTelemetry(rig, $0, slots)) }
            ]
            try #require(runCycleWorkers(run, workers))
            var observed = try #require(model.get(0))
            let producers = try (0..<3).map { try #require(outcomes.get($0)) }
            let controlViolations = try #require(control.get(0))
            #expect(run.acknowledged.load(ordering: .acquiring) > 0 && observed.lastFaultedCycle > 1)
            // Quiescent flush past the lookahead edge: acknowledge any latch after one silenced cycle, then run
            // until an unsilenced cycle starts empty.
            let observation = rig.faults.observe(CycleRig.criticalScope)
            var blockStart = run.now.load(ordering: .relaxed)
            for cycle in 0..<1_000 {
                if cycle == 1, let observation { _ = rig.faults.acknowledge(observation) }
                let (result, emitted) = rig.run(blockStart, 512)
                observed.record(result, emitted, blockStart: blockStart, frames: 512)
                blockStart &+= 512
                let decided = result.dispatched + result.droppedLate + result.refused + result.skippedPulses
                if result.status == .ok, result.drained == 0, decided == 0, !result.flushing,
                   rig.cycle.bufferedCount == 0 { break }
            }
            let violations = observed.violations + controlViolations + producers.flatMap(\.violations)
            #expect(violations.isEmpty, "\(violations.prefix(5))")
            #expect(rig.cycle.bufferedCount == 0 && rig.events.drain(perLaneQuota: 64, total: 64) { _, _ in } == 0)
            let pushed = accepted + producers.reduce(0) { $0 + $1.accepted }
            #expect(observed.drained == pushed && observed.decided == pushed)
            #expect(producers.map(\.edgeAdmitted) == [true, true, true])
            #expect(producers.allSatisfy { $0.resets > 0 }, "\(producers.map(\.resets))")
            #expect(producers.reduce(0) { $0 + $1.beyondLookahead } > 0 && observed.flushingCycles > 0)

            let final = try #require(latestCycleSample(slots))
            #expect(final.stamp == TelemetryStamp(clockGeneration: 3, frame: blockStart &- 512))
            let nonMonotonic = producers.reduce(0) { $0 + $1.refusedNonMonotonic }
            let beyondLookahead = producers.reduce(0) { $0 + $1.refusedBeyondLookahead }
            let expected = KernelCycleTelemetry(cycle: observed.cycles, lastFaultedCycle: observed.lastFaultedCycle,
                                                droppedLate: observed.droppedLate, resyncs: observed.resyncs,
                                                skippedStale: UInt64(rig.cycle.pulses.skippedStale),
                                                rateLimited: UInt64(rig.cycle.pulses.rateLimited),
                                                pending: 0, flushing: false,
                                                discardedWhileSilenced: observed.discardedWhileSilenced,
                                                discardedSuperseded: observed.discardedSuperseded,
                                                refusedNonMonotonic: nonMonotonic,
                                                refusedBeyondLookahead: beyondLookahead, blockAppendRefused: 0)
            #expect(final.value == expected && final.value.droppedLate >= 1)
            #expect(final.value.refusedNonMonotonic > 0 && final.value.refusedBeyondLookahead > 0)

            let mustEndUnowned = producers.reduce(OrderingModel.bit(0, 14) | OrderingModel.bit(0, 15)) {
                $0 | $1.refusedLast
            }
            #expect(observed.sounding & mustEndUnowned == 0 && observed.forbiddenNoteOns == 0)
            for scope in UInt32(0)..<2 {
                for note in UInt8(0)..<16 {
                    let sounding = observed.sounding & OrderingModel.bit(scope, note) != 0
                    #expect(rig.ownership.isOwned(scope: scope, channel: 0, note: note) == sounding)
                }
            }
        }
    }
}
