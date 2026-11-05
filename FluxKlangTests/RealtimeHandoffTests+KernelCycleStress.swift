import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Start flag, cancel flag, phase counters and joins for the dedicated kernel-cycle stress `Thread`s. Shared with
/// `RealtimeHandoffTests+KernelCycleOrderingStress.swift`.
final class CycleStressRun: @unchecked Sendable {
    /// Every controller wait and every worker's start wait is bounded by this.
    static let waitLimit: Duration = .seconds(15)
    let arrived = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    let cancelled = Atomic<Bool>(false)
    /// Producers that have finished pushing.
    let producersDone = Atomic<Int>(0)
    /// Critical faults the control worker acknowledged; render keeps cycling until there is at least one.
    let acknowledged = Atomic<Int>(0)
    /// Render's cycle index, stored before each cycle runs (the first is 1).
    let cycleStarted = Atomic<Int>(0)
    /// Bounded waits that hit `waitLimit` (each also ends its wait).
    let spinOverruns = Atomic<Int>(0)
    /// Set by control after its first `observe`; render's first cycle waits for it.
    let firstObserved = Atomic<Bool>(false)
    /// Set by the render worker once it stops running cycles.
    let renderDone = Atomic<Bool>(false)
    /// The render worker's current `blockStart`, read by producers to stamp frames near it.
    let now = Atomic<Int64>(0)
    /// Signalled once per finished worker. `@unchecked Sendable` covers this `DispatchSemaphore`.
    let joined = DispatchSemaphore(value: 0)

    var shouldStop: Bool { cancelled.load(ordering: .acquiring) }

    /// Worker side: counts this worker in, then waits (bounded) for the start flag. `false` means return now.
    func arriveAndWait() -> Bool {
        arrived.add(1, ordering: .acquiringAndReleasing)
        let deadline = ContinuousClock.now + Self.waitLimit
        var spins = 0
        while !started.load(ordering: .acquiring) {
            spins &+= 1
            if shouldStop || (spins & 1_023 == 0 && ContinuousClock.now >= deadline) { return false }
        }
        return !shouldStop
    }
}

/// Runs each worker on its own `Thread`, releases the start flag once all have arrived and joins each with a
/// 15 s deadline. On any timeout this records an `Issue`, cancels and returns `false`.
func runCycleWorkers(_ run: CycleStressRun, _ workers: [@Sendable (CycleStressRun) -> Void]) -> Bool {
    for worker in workers {
        Thread {
            worker(run)
            run.joined.signal()
        }.start()
    }
    let arrival = ContinuousClock.now + CycleStressRun.waitLimit
    while run.arrived.load(ordering: .acquiring) < workers.count, ContinuousClock.now < arrival {
        Thread.sleep(forTimeInterval: 0.001)
    }
    guard run.arrived.load(ordering: .acquiring) == workers.count else {
        run.cancelled.store(true, ordering: .releasing)
        Issue.record("not every kernel-cycle stress worker arrived within 15 s; cancelled")
        return false
    }
    run.started.store(true, ordering: .releasing)
    for index in workers.indices where run.joined.wait(timeout: .now() + 15) == .timedOut {
        run.cancelled.store(true, ordering: .releasing)
        Issue.record("kernel-cycle stress join \(index) timed out after 15 s; post-run checks skipped")
        return false
    }
    return true
}

/// Per-worker result slots, written by each worker before it signals `joined`.
final class CycleSlots<Value: Sendable>: Sendable {
    private let values: Mutex<[Value?]>
    init(_ count: Int) { values = Mutex(Array(repeating: nil, count: count)) }
    func set(_ index: Int, _ value: Value) { values.withLock { $0[index] = value } }
    func get(_ index: Int) -> Value? { values.withLock { $0[index] } }
}

/// A small deterministic generator, one per worker.
struct CycleRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed | 1 }

    mutating func next(_ bound: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(bound))
    }
}

/// What the render side saw: the result totals, the ownership model rebuilt from emissions, and rule breaks.
private struct CycleModel: Sendable {
    var drained = 0
    var decided = 0
    var cycles = 0
    var silencedCycles = 0
    /// Bit `scope * 16 + note` set while the emissions say channel 0's `note` sounds in `scope`.
    var sounding: UInt32 = 0
    var violations: [String] = []
    /// Cycles that reported `flushing`.
    var flushingCycles = 0
    /// Emitted `noteOn(15)`s in scope 0: only `latchCriticalScope` sends one, ahead of its refused release.
    var lostReleaseNoteOns = 0

    /// Folds one cycle's result and emissions in, checking per-cycle ordering and window rules.
    mutating func record(_ result: KernelCycleResult, _ emitted: [CycleEmission], blockStart: Int64, frames: Int64) {
        cycles += 1
        drained += result.drained
        decided += result.dispatched + result.droppedLate + result.refused + result.skippedPulses
            + result.discardedWhileSilenced + result.discardedSuperseded
        if result.status != .ok { silencedCycles += 1 }
        if result.flushing { flushingCycles += 1 }
        if result.flushing, emitted.contains(where: { if case .noteOn = $0.event.payload { true } else { false } }) {
            violations.append("cycle at \(blockStart) emitted a noteOn while flushing")
        }
        // A silenced cycle emits only releases of owned notes, all at `blockStart`.
        if result.status != .ok, emitted.contains(where: { !Self.isRelease($0.event) || $0.frame != blockStart }) {
            violations.append("silenced cycle at \(blockStart) emitted something other than a release")
        }
        var previous = Int64.min
        for emission in emitted {
            if emission.frame < previous { violations.append("emission frames decreased at \(blockStart)") }
            previous = emission.frame
            if emission.frame < blockStart || emission.frame - blockStart >= frames {
                violations.append("emission at \(emission.frame) outside block \(blockStart)")
            }
            apply(emission.event)
        }
        let released = emitted.count { $0.event.sequence == KernelCycle.releaseSequence }
        if released != result.releasedNotes || emitted.count - released != result.dispatched {
            violations.append("emission count disagrees with result at \(blockStart)")
        }
    }

    mutating func apply(_ event: KernelEvent) {
        switch event.payload {
        case .noteOn(_, let note, _) where event.scope < 2:
            sounding |= Self.bit(event.scope, note)
            if event.scope == 0, note == 15 { lostReleaseNoteOns += 1 }
        case .noteOff(_, let note) where event.scope < 2:
            sounding &= ~Self.bit(event.scope, note)
        default:
            break
        }
    }

    static func isRelease(_ event: KernelEvent) -> Bool {
        if case .noteOff = event.payload { true } else { false }
    }

    static func bit(_ scope: UInt32, _ note: UInt8) -> UInt32 { 1 << (scope &* 16 &+ UInt32(note & 15)) }
}

/// A producer's accepted pushes, and bit `scope * 16 + note` set where its last note event for that note was a
/// refused `noteOff` (so the note must end unowned).
private struct ProducerOutcome: Sendable {
    var accepted = 0
    var refusedLast: UInt32 = 0

    /// Counts one push of `event` that returned `status`, tracking its note when its scope is in range.
    mutating func record(_ event: KernelEvent, _ status: KernelStatus) {
        if status == .ok { accepted += 1 }
        guard event.scope < 2 else { return }
        switch event.payload {
        case .noteOn(_, let note, _): refusedLast &= ~CycleModel.bit(event.scope, note)
        case .noteOff(_, let note) where status == .ok: refusedLast &= ~CycleModel.bit(event.scope, note)
        case .noteOff(_, let note): refusedLast |= CycleModel.bit(event.scope, note)
        default: break
        }
    }
}

/// One of every payload kind, chosen by `random`, on `note`.
private func stressPayload(_ random: inout CycleRandom, note: UInt8, index: Int) -> KernelEventPayload {
    switch random.next(8) {
    case 0, 1, 2: .noteOn(channel: 0, note: note, velocity: 90)
    case 3, 4: .noteOff(channel: 0, note: note)
    case 5: .control(channel: 0, controller: 7, value: UInt32(index))
    case 6: .clockPulse
    default: .rampTo(parameter: UInt32(random.next(5)), value: Float(random.next(100)) / 100,
                     durationFrames: Int64(random.next(256)))
    }
}

/// Pushes a deterministic mix of every payload with frames around the render worker's `now`, on notes
/// `noteBase..<noteBase + 7` only (notes 7 and 15 are left to `latchCriticalScope`).
@Sendable private func produce(_ rig: CycleRig, _ run: CycleStressRun, seed: UInt64, noteBase: UInt8,
                               pushes: Int) -> ProducerOutcome {
    var outcome = ProducerOutcome()
    guard run.arriveAndWait(), let token = rig.events.claimProducer() else { return outcome }
    // Push only once render's first cycle is done, so no new fault hides how that cycle met the pre-start latch.
    let deadline = ContinuousClock.now + CycleStressRun.waitLimit
    while run.cycleStarted.load(ordering: .acquiring) < 2, !run.shouldStop, ContinuousClock.now < deadline {}
    var random = CycleRandom(seed: seed)
    for index in 0..<pushes where !run.shouldStop {
        let note = noteBase &+ UInt8(random.next(7))
        // Scope 2 is out of range, so some notes are refused by `NoteOwnership`.
        let scope = UInt32(random.next(9) / 4)
        let payload = stressPayload(&random, note: note, index: index)
        // From 700 frames late (beyond the 480-frame tolerance) to 300 frames ahead.
        let frame = run.now.load(ordering: .relaxed) &+ Int64(random.next(1_001)) &- 700
        let event = cycleEvent(frame, payload, scope: scope, sequence: UInt64(index))
        outcome.record(event, rig.push(event, token))
    }
    _ = rig.events.releaseProducer(token)
    run.producersDone.add(1, ordering: .releasing)
    return outcome
}

/// Runs 64-frame cycles until every producer is done and control has acknowledged at least one fault,
/// publishing each `blockStart` as `now`.
@Sendable private func render(_ rig: CycleRig, _ run: CycleStressRun, producers: Int) -> CycleModel {
    var model = CycleModel()
    guard run.arriveAndWait() else { return model }
    // Render starts after control's first observation (bounded), so an acknowledgement not gated on a faulted
    // cycle would clear the pre-start latch before render saw it.
    let deadline = ContinuousClock.now + CycleStressRun.waitLimit
    while !run.firstObserved.load(ordering: .acquiring), !run.shouldStop, ContinuousClock.now < deadline {}
    Thread.sleep(forTimeInterval: 0.002)
    var blockStart: Int64 = 0
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

/// Spins until `condition` holds (`true`), the run is cancelled or render is done (`false`), or `waitLimit` passes
/// (`false`, counted in `spinOverruns`).
private func awaitBounded(_ run: CycleStressRun, _ condition: () -> Bool) -> Bool {
    let deadline = ContinuousClock.now + CycleStressRun.waitLimit
    var spins = 0
    while !condition() {
        spins &+= 1
        if run.shouldStop || run.renderDone.load(ordering: .acquiring) { return false }
        if spins & 1_023 == 0, ContinuousClock.now >= deadline {
            run.spinOverruns.add(1, ordering: .relaxed)
            return false
        }
    }
    return true
}

/// Acknowledges each observed critical fault only once telemetry shows a `.scopeFaulted` cycle that loaded the
/// epoch requested after the observation (the KernelCycle contract), and requests safety actions while render runs.
@Sendable private func control(_ rig: CycleRig, _ run: CycleStressRun,
                               _ slots: TelemetrySlots<KernelCycleTelemetry>) {
    guard run.arriveAndWait() else { return }
    var random = CycleRandom(seed: 0xC0FFEE)
    while !run.renderDone.load(ordering: .acquiring), !run.shouldStop {
        if let observation = rig.faults.observe(CycleRig.criticalScope),
           let ticket = try? rig.cycle.ackRequests.request(for: observation) {
            run.firstObserved.store(true, ordering: .releasing)
            var sample: KernelCycleTelemetry?
            let permitted = awaitBounded(run) {
                sample = latestKernelCycleSample(slots)?.value
                return sample?.permitsAcknowledgement(ticket) == true
            }
            if permitted, (try? rig.cycle.acknowledgeCritical(observation, ticket, sample: sample)) != nil {
                run.acknowledged.add(1, ordering: .releasing)
            }
        }
        // Like producers, no safety request before render's first cycle is done.
        guard run.cycleStarted.load(ordering: .acquiring) >= 2 else { continue }
        switch random.next(64) {
        case 0: _ = rig.safety.request(.panic, scope: UInt32(random.next(2)))
        case 1: _ = rig.safety.request(.allNotesOff, scope: UInt32(random.next(2)))
        default: break
        }
    }
}

/// Before the workers start, with no cycle draining, queues `noteOn(15)` on a third lane, fills it with
/// `noteOff(7)`s and has `noteOff(15)` refused: a certain `.criticalExhausted` latch with a `noteOn` ahead of its
/// lost release (note 15 must end unowned). Returns the accepted pushes.
private func latchCriticalScope(_ rig: CycleRig) throws -> Int {
    let token = try #require(rig.events.claimProducer())
    #expect(rig.push(cycleEvent(0, .noteOn(channel: 0, note: 15, velocity: 90)), token) == .ok)
    var accepted = 1
    while accepted < 64, rig.push(cycleEvent(0, .noteOff(channel: 0, note: 7)), token) == .ok { accepted += 1 }
    #expect(rig.push(cycleEvent(1, .noteOff(channel: 0, note: 15)), token) == .refused(.criticalExhausted))
    #expect(rig.faults.isLatched(CycleRig.criticalScope))
    return accepted
}

/// The rounds each re-raising producer has raised so far, published (release) after each raise.
private final class ReRaisedRounds: Sendable {
    private let low = Atomic<Int>(0)
    private let high = Atomic<Int>(0)
    func publish(_ producer: Int, _ round: Int) {
        if producer == 0 { low.store(round, ordering: .releasing) } else { high.store(round, ordering: .releasing) }
    }
    func load(_ producer: Int) -> Int {
        producer == 0 ? low.load(ordering: .acquiring) : high.load(ordering: .acquiring)
    }
    /// Producer `p`'s note in scope 1: 15 or 7, which no other producer uses there.
    static func note(_ producer: Int) -> UInt8 { producer == 0 ? 15 : 7 }
}

/// A re-raising producer: each round, once an acknowledgement has landed since its last raise (bounded), queues
/// `noteOn(note)` in scope 1 with velocity `round`, raises the critical scope as its refused `noteOff` would, then
/// publishes the round. Returns rule breaks.
@Sendable private func reRaise(_ rig: CycleRig, _ run: CycleStressRun, _ rounds: ReRaisedRounds, producer: Int,
                               count: Int) -> [String] {
    var violations: [String] = []
    guard run.arriveAndWait(), let token = rig.events.claimProducer() else { return ["producer \(producer) not run"] }
    var acknowledgedBefore = -1
    for round in 1...count where !run.shouldStop {
        guard awaitBounded(run, { run.acknowledged.load(ordering: .acquiring) > acknowledgedBefore }) else {
            violations.append("producer \(producer) round \(round): no acknowledgement in time")
            break
        }
        let frame = run.now.load(ordering: .relaxed) &+ 64
        let payload = KernelEventPayload.noteOn(channel: 0, note: ReRaisedRounds.note(producer),
                                                velocity: UInt16(round))
        let noteOn = cycleEvent(frame, payload, scope: 1, sequence: UInt64(round))
        guard awaitBounded(run, { rig.push(noteOn, token) == .ok }) else {
            violations.append("producer \(producer) round \(round): noteOn never queued")
            break
        }
        acknowledgedBefore = run.acknowledged.load(ordering: .acquiring)
        if rig.faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: frame) != .ok {
            violations.append("producer \(producer) round \(round): raise refused")
        }
        rounds.publish(producer, round)
    }
    _ = rig.events.releaseProducer(token)
    run.producersDone.add(1, ordering: .releasing)
    return violations
}

/// Runs 64-frame cycles until both re-raising producers are done. A `noteOn` of round `r` emitted by a cycle that
/// began after its producer published `r` (so after the raise) is a violation: it was queued before that fault and
/// sounded although no faulted cycle (and so no acknowledgement) can have preceded its flush.
@Sendable private func reRaiseRender(_ rig: CycleRig, _ run: CycleStressRun, _ rounds: ReRaisedRounds) -> CycleModel {
    var model = CycleModel()
    guard run.arriveAndWait() else { return model }
    var blockStart: Int64 = 0
    let deadline = ContinuousClock.now + CycleStressRun.waitLimit
    while run.producersDone.load(ordering: .acquiring) < 2, !run.shouldStop, ContinuousClock.now < deadline {
        let raised = (rounds.load(0), rounds.load(1))
        run.cycleStarted.add(1, ordering: .sequentiallyConsistent)
        let (result, emitted) = rig.run(blockStart, 64)
        model.record(result, emitted, blockStart: blockStart, frames: 64)
        for emission in emitted where emission.event.scope == 1 {
            guard case .noteOn(_, let note, let round) = emission.event.payload else { continue }
            if (note == ReRaisedRounds.note(0) && Int(round) <= raised.0)
                || (note == ReRaisedRounds.note(1) && Int(round) <= raised.1) {
                model.violations.append("round \(round) noteOn(\(note)) sounded after its fault at \(blockStart)")
            }
        }
        blockStart &+= 64
        run.now.store(blockStart, ordering: .relaxed)
    }
    if ContinuousClock.now >= deadline { run.spinOverruns.add(1, ordering: .relaxed) }
    run.renderDone.store(true, ordering: .releasing)
    return model
}

extension RealtimeHandoffTests {
    @Suite(.serialized) struct CycleStress {
        /// Kills: a lost, duplicated or doubly-counted event; an emission outside its block or out of frame order;
        /// a silenced cycle emitting more than releases; no certain fault or acknowledgement; a `noteOn` emitted
        /// while flushing; a note left owned after its `noteOff` was refused; ownership diverging from what was
        /// emitted; a race TSan can see.
        @Test func concurrentProducersRenderAndControlKeepEveryEventAccounted() throws {
            let slots = try kernelCycleTelemetrySlots()
            let rig = try CycleRig(lanes: 3, laneCapacity: 32, blockCapacity: 48,
                                   telemetry: KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 0))
            let burst = try latchCriticalScope(rig)
            let run = CycleStressRun()
            let outcomes = CycleSlots<ProducerOutcome>(2)
            let model = CycleSlots<CycleModel>(1)
            let workers: [@Sendable (CycleStressRun) -> Void] = [
                { outcomes.set(0, produce(rig, $0, seed: 0x1234_5678, noteBase: 0, pushes: 20_000)) },
                { outcomes.set(1, produce(rig, $0, seed: 0x9ABC_DEF0, noteBase: 8, pushes: 20_000)) },
                { model.set(0, render(rig, $0, producers: 2)) },
                { control(rig, $0, slots) }
            ]
            try #require(runCycleWorkers(run, workers))
            #expect(run.spinOverruns.load(ordering: .acquiring) == 0)
            var observed = try #require(model.get(0))
            let first = try #require(outcomes.get(0))
            let second = try #require(outcomes.get(1))
            let pushed = burst + first.accepted + second.accepted
            #expect(run.acknowledged.load(ordering: .acquiring) > 0 && observed.silencedCycles > 0)
            // Quiescent flush: observe any latch, run one cycle (silenced if latched, arming the flush), then
            // acknowledge and run cycles past every stamped frame until an unsilenced cycle finds nothing left.
            let observation = rig.faults.observe(CycleRig.criticalScope)
            var blockStart = run.now.load(ordering: .relaxed)
            for cycle in 0..<1_000 {
                if cycle == 1, let observation { _ = rig.faults.acknowledge(observation) }
                let (result, emitted) = rig.run(blockStart, 512)
                observed.record(result, emitted, blockStart: blockStart, frames: 512)
                blockStart &+= 512
                // Done only when an unsilenced cycle started empty: it drained and decided nothing. (A cycle
                // that started with a full buffer drains nothing yet may leave the lanes non-empty.)
                let decided = result.dispatched + result.droppedLate + result.refused + result.skippedPulses
                if result.status == .ok, result.drained == 0, decided == 0, !result.flushing,
                   rig.cycle.bufferedCount == 0 { break }
            }
            #expect(observed.violations.isEmpty, "\(observed.violations.prefix(5))")
            #expect(rig.cycle.bufferedCount == 0 && rig.events.drain(perLaneQuota: 64, total: 64) { _, _ in } == 0)
            #expect(observed.drained == pushed)
            #expect(observed.decided == pushed)
            #expect(observed.cycles > 1 && observed.flushingCycles > 0)
            // A note whose last event was a refused `noteOff` must not stick, wherever its `noteOn`s were queued.
            let mustEndUnowned = first.refusedLast | second.refusedLast | CycleModel.bit(0, 15)
            #expect(observed.sounding & mustEndUnowned == 0 && observed.lostReleaseNoteOns == 0)
            for scope in UInt32(0)..<2 {
                for note in UInt8(0)..<16 {
                    let sounding = observed.sounding & CycleModel.bit(scope, note) != 0
                    #expect(rig.ownership.isOwned(scope: scope, channel: 0, note: note) == sounding)
                }
                #expect(rig.ownership.ownedCount(scope: scope) == (0..<16).count {
                    observed.sounding & CycleModel.bit(scope, UInt8($0)) != 0
                })
            }
        }

        /// Finding 4: producers re-raise the critical scope after acknowledgements, mid-run, each with a `noteOn`
        /// queued just before its raise. Kills: an acknowledgement before a faulted cycle loaded its request epoch
        /// (a queued `noteOn` sounds after its fault); an unbounded wait; a note left owned.
        @Test func producersReRaiseAfterAcknowledgementsMidRun() throws {
            let slots = try kernelCycleTelemetrySlots()
            let rig = try CycleRig(telemetry: KernelCycleTelemetryOutput(slots: slots, slot: 1, clockGeneration: 0))
            let run = CycleStressRun()
            let rounds = ReRaisedRounds()
            let breaks = CycleSlots<[String]>(2)
            let model = CycleSlots<CycleModel>(1)
            let workers: [@Sendable (CycleStressRun) -> Void] = [
                { breaks.set(0, reRaise(rig, $0, rounds, producer: 0, count: 40)) },
                { breaks.set(1, reRaise(rig, $0, rounds, producer: 1, count: 40)) },
                { model.set(0, reRaiseRender(rig, $0, rounds)) },
                { control(rig, $0, slots) }
            ]
            try #require(runCycleWorkers(run, workers))
            var observed = try #require(model.get(0))
            #expect(breaks.get(0) == [] && breaks.get(1) == [])
            #expect(run.spinOverruns.load(ordering: .acquiring) == 0 && run.acknowledged.load(ordering: .acquiring) > 1)
            // Quiescent: acknowledge any last latch after one faulted cycle, then run until nothing is left.
            let observation = rig.faults.observe(CycleRig.criticalScope)
            var blockStart = run.now.load(ordering: .relaxed)
            for cycle in 0..<64 {
                if cycle == 1, let observation { _ = rig.faults.acknowledge(observation) }
                let (result, emitted) = rig.run(blockStart, 512)
                observed.record(result, emitted, blockStart: blockStart, frames: 512)
                blockStart &+= 512
                if cycle > 1, result.status == .ok, !result.flushing, rig.cycle.bufferedCount == 0 { break }
            }
            #expect(observed.violations.isEmpty, "\(observed.violations.prefix(5))")
            #expect(observed.silencedCycles > 1 && !rig.faults.isLatched(CycleRig.criticalScope))
            for producer in 0..<2 {
                #expect(!rig.ownership.isOwned(scope: 1, channel: 0, note: ReRaisedRounds.note(producer)))
            }
        }
    }
}
