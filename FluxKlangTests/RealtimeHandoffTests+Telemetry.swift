import Foundation
import Synchronization
import Testing
@testable import FluxKlang

private typealias Root = RealtimeHandoffTests

/// A value whose fields must agree; a torn read breaks `check == ~word`.
private struct Paired: BitwiseCopyable, Sendable, Equatable {
    let word: UInt64
    let check: UInt64

    init(_ word: UInt64) {
        self.word = word
        check = ~word
    }

    var isConsistent: Bool { check == ~word }
}

private typealias Slots = TelemetrySlots<Paired>

private func stamp(_ frame: Int64, generation: UInt64 = 1) -> TelemetryStamp {
    TelemetryStamp(clockGeneration: generation, frame: frame)
}

/// A valid render-to-UI telemetry policy declaring `capacity` slots.
private func sizedTelemetryPolicy(capacity: Int) -> HandoffPolicy {
    Root.policy(purpose: .telemetry, producer: .render, consumer: .ui, capacity: capacity, ordering: .latestOnly,
                deadline: .none, overflow: .overwriteLatest)
}

private func makeSlots(_ count: Int = 4) throws -> Slots {
    try Slots(policy: sizedTelemetryPolicy(capacity: count), slotCount: count)
}

/// What the stress consumer saw.
private struct StressObservation: Sendable {
    var failures = 0
    var sawFinal = false
    var distinctIntermediate = 0
}

private func sample(_ read: TelemetryRead<Paired>) -> TelemetrySample<Paired>? {
    if case .measured(let sample) = read { return sample }
    return nil
}

private func reason(_ read: TelemetryRead<Paired>) -> TelemetryUnavailable? {
    if case .unavailable(let reason) = read { return reason }
    return nil
}

private func initError(_ policy: HandoffPolicy, slotCount: Int = 256) -> Slots.PreparationError? {
    do {
        _ = try Slots(policy: policy, slotCount: slotCount)
        return nil
    } catch {
        return error
    }
}

extension RealtimeHandoffTests {
    struct TelemetryLatest {
        @Test func neverPublishedIsUnavailable() throws {
            Root.requireBitwise(TelemetrySample<Paired>.self)
            Root.requireBitwise(TelemetryRead<Paired>.self)
            let slots = try makeSlots()
            for slot in 0..<slots.slotCount {
                #expect(reason(slots.latest(slot: slot)) == .neverPublished)
                #expect(reason(slots.latest(slot: slot)) == .neverPublished)
            }
            #expect(slots.publish(slot: 1, value: Paired(0), stamp: stamp(0)) == .ok)
            #expect(reason(slots.latest(slot: 0)) == .neverPublished)
            #expect(reason(slots.latest(slot: 2)) == .neverPublished)
            let first = sample(slots.latest(slot: 1))
            #expect(first?.value == Paired(0))
            #expect(first?.sequence == 1)
        }

        @Test func readerGetsLatestComplete() throws {
            let slots = try makeSlots(1)
            #expect(slots.publish(slot: 0, value: Paired(10), stamp: stamp(100)) == .ok)
            for _ in 0..<3 {
                let read = sample(slots.latest(slot: 0))
                #expect(read?.value == Paired(10))
                #expect(read?.stamp == stamp(100))
                #expect(read?.sequence == 1)
            }
            for word in UInt64(11)...15 {
                #expect(slots.publish(slot: 0, value: Paired(word), stamp: stamp(Int64(word) * 10)) == .ok)
            }
            for _ in 0..<3 {
                let read = sample(slots.latest(slot: 0))
                #expect(read?.value == Paired(15))
                #expect(read?.stamp == stamp(150))
                #expect(read?.sequence == 6)
            }
            // Alternate publish and read so every cell rotates through back, middle and front.
            for word in UInt64(16)...40 {
                #expect(slots.publish(slot: 0, value: Paired(word), stamp: stamp(Int64(word))) == .ok)
                if word.isMultiple(of: 3) {
                    #expect(slots.publish(slot: 0, value: Paired(word + 100), stamp: stamp(Int64(word))) == .ok)
                }
                let expected = word.isMultiple(of: 3) ? word + 100 : word
                #expect(sample(slots.latest(slot: 0))?.value == Paired(expected))
                #expect(sample(slots.latest(slot: 0))?.value == Paired(expected))
            }
        }

        @Test func sequenceMonotonicPerSlot() throws {
            let slots = try makeSlots(3)
            var last: [UInt64] = [0, 0, 0]
            for step in 0..<60 {
                let slot = step % 3 == 2 ? 2 : step % 2
                #expect(slots.publish(slot: slot, value: Paired(UInt64(step)), stamp: stamp(Int64(step))) == .ok)
                for read in 0..<3 {
                    guard let got = sample(slots.latest(slot: read)) else { continue }
                    #expect(got.sequence >= last[read])
                    last[read] = got.sequence
                }
                #expect(last[slot] > 0)
            }
            let published = (0..<60).map { $0 % 3 == 2 ? 2 : $0 % 2 }
            for slot in 0..<3 {
                #expect(last[slot] == UInt64(published.filter { $0 == slot }.count))
            }
        }

        @Test func classifyUsesGenerationEqualityAndAge() {
            let measured = TelemetryRead<Paired>.measured(
                TelemetrySample(value: Paired(1), stamp: stamp(1_000, generation: 5), sequence: 1))
            func classify(generation: UInt64 = 5, frame: Int64 = 1_000, maximumAge: Int64 = 100,
                          _ read: TelemetryRead<Paired>? = nil) -> TelemetryRead<Paired> {
                Slots.classify(read ?? measured, generation: generation, frame: frame, maximumAgeFrames: maximumAge)
            }
            #expect(classify() == measured)
            for generation in [UInt64(0), 4, 6, .max] {
                #expect(reason(classify(generation: generation)) == .staleGeneration)
            }
            #expect(classify(frame: 1_100) == measured)
            #expect(reason(classify(frame: 1_101)) == .tooOld)
            #expect(classify(frame: 1_000, maximumAge: 0) == measured)
            #expect(reason(classify(frame: 1_001, maximumAge: 0)) == .tooOld)
            // A future stamp (negative age) is measured.
            #expect(classify(frame: 0) == measured)
            #expect(classify(frame: -1_000_000, maximumAge: 0) == measured)
            for maximumAge in [Int64.min, -1] {
                #expect(reason(classify(maximumAge: maximumAge)) == .tooOld)
                #expect(reason(classify(frame: 0, maximumAge: maximumAge)) == .tooOld)
            }
            #expect(classify(maximumAge: .max) == measured)
            // Stamp frame 1_000: `.min - 1_000` overflows (too old); the rest are negative or in-range ages.
            for frame in Root.adversarialFrames {
                let result = classify(frame: frame, maximumAge: .max)
                if frame == .min {
                    #expect(reason(result) == .tooOld)
                } else {
                    #expect(result == measured)
                }
            }
            let extreme = { (stampFrame: Int64) in
                TelemetryRead<Paired>.measured(
                    TelemetrySample(value: Paired(1), stamp: stamp(stampFrame, generation: 5), sequence: 1))
            }
            #expect(reason(classify(frame: .max, maximumAge: .max, extreme(.min))) == .tooOld)
            #expect(reason(classify(frame: .min, maximumAge: .max, extreme(.max))) == .tooOld)
            #expect(reason(classify(frame: .max, maximumAge: .max - 1, extreme(0))) == .tooOld)
            #expect(classify(frame: .max, maximumAge: .max, extreme(0)) == extreme(0))
            for passthrough in [TelemetryUnavailable.neverPublished, .invalidSlot, .staleGeneration, .tooOld] {
                let read = TelemetryRead<Paired>.unavailable(passthrough)
                #expect(reason(classify(generation: 0, frame: .min, maximumAge: -1, read)) == passthrough)
            }
        }

        @Test func initRejectsNonTelemetryPolicy() {
            #expect(initError(Root.telemetryPolicy()) == nil)
            #expect(initError(Root.telemetryPolicy(consumer: .control)) == nil)
            #expect(initError(Root.policy()) == .policy(.violates(.r4LatestOnly)))
            #expect(initError(Root.sysexPolicy()) == .policy(.violates(.r4LatestOnly)))
            #expect(initError(Root.telemetryPolicy(consumer: .render)) == .policy(.violates(.r5TelemetryNotRender)))
            #expect(initError(Root.telemetryPolicy(consumers: 2)) == .policy(.violates(.r1SingleConsumer)))
            let controlProducer = Root.policy(purpose: .telemetry, producer: .control, consumer: .ui,
                                              ordering: .latestOnly, deadline: .none, overflow: .overwriteLatest)
            #expect(initError(controlProducer) == .policy(.violates(.r5TelemetryNotRender)))
            let fanIn = Root.policy(purpose: .telemetry, producer: .render,
                                    producers: .init(maximum: 2, evidence: .appOwned), consumer: .ui,
                                    ordering: .latestOnly, deadline: .none, overflow: .overwriteLatest)
            #expect(Root.violation(fanIn) == nil)
            #expect(initError(fanIn) == .policy(.violates(.r2Cardinality)))
            #expect(KernelLimits.maximumTelemetrySlots == 4_096)
            #expect(Slots.maximumSlots == KernelLimits.maximumTelemetrySlots)
            for count in Root.adversarialInts + [Slots.maximumSlots, Slots.maximumSlots + 1] {
                let valid = count >= 1 && count <= Slots.maximumSlots
                #expect(initError(Root.telemetryPolicy(), slotCount: count)
                        == (valid ? .capacityMismatch(declared: 256, slots: count) : .slotCountOutOfRange))
            }
            for count in [1, 2, 256, Slots.maximumSlots] {
                #expect(initError(sizedTelemetryPolicy(capacity: count), slotCount: count) == nil)
            }
            // A valid policy capacity above the slot limit is still refused on the slot count.
            let oversized = Slots.maximumSlots + 1
            #expect(initError(sizedTelemetryPolicy(capacity: oversized), slotCount: oversized) == .slotCountOutOfRange)
            #expect(initError(sizedTelemetryPolicy(capacity: 4), slotCount: 5)
                    == .capacityMismatch(declared: 4, slots: 5))
            #expect(initError(sizedTelemetryPolicy(capacity: 5), slotCount: 4)
                    == .capacityMismatch(declared: 5, slots: 4))
        }

        @Test func invalidSlotsNeverTrap() throws {
            let slots = try makeSlots(4)
            for slot in Root.adversarialInts + [3, 4, 5] {
                let valid = slot >= 0 && slot < 4
                let status = slots.publish(slot: slot, value: Paired(7), stamp: stamp(7))
                #expect(status == (valid ? .ok : .refused(.slotOutOfRange)))
                let read = slots.latest(slot: slot)
                if valid {
                    #expect(sample(read)?.value == Paired(7))
                } else {
                    #expect(reason(read) == .invalidSlot)
                }
            }
            for slot in 0..<4 {
                #expect(sample(slots.latest(slot: slot))?.sequence == 1)
            }
        }
    }

    struct TelemetryStress {
        /// Runs on dedicated threads so overlap never depends on executor scheduling. A start barrier, a
        /// free-running phase, then a bounded marker handshake that guarantees an intermediate observation.
        @Test(.timeLimit(.minutes(1)))
        func stressNoTornReads() throws {
            let harness = StressHarness(slots: try makeSlots(2))
            Thread { harness.runProducer() }.start()
            Thread { harness.runConsumer() }.start()
            let joined = [harness.producerDone, harness.consumerDone].map {
                $0.wait(timeout: .now() + StressHarness.joinTimeoutSeconds) == .success
            }
            guard joined == [true, true] else {
                Issue.record("stress threads did not finish within \(StressHarness.joinTimeoutSeconds) s")
                return
            }
            let barrierTimedOut = harness.barrierTimedOut.load(ordering: .acquiring)
            let handshakeTimedOut = harness.handshakeTimedOut.load(ordering: .acquiring)
            let producerFinished = harness.producerFinished.load(ordering: .acquiring)
            #expect(producerFinished)
            #expect(!barrierTimedOut, "start barrier timed out")
            #expect(!handshakeTimedOut, "consumer did not acknowledge the marker before the final publications")
            let seen = harness.observation.withLock { $0 }
            #expect(seen.failures == 0)
            #expect(seen.sawFinal)
            // The marker is intermediate, so an acknowledged handshake makes this non-vacuous.
            #expect(seen.distinctIntermediate > 0)
            #expect(sample(harness.slots.latest(slot: 1))?.value == Paired(StressHarness.finalWord - 1))
            #expect(sample(harness.slots.latest(slot: 0))?.value == Paired(StressHarness.finalWord))
        }
    }
}

/// Test-only coordination for `stressNoTornReads`; the slots themselves never wait. Every wait is bounded.
private final class StressHarness: Sendable {
    static let freeRunningWords: UInt64 = 200_000
    /// Odd, so it lands on slot 1, and below both slots' final words, so it counts as intermediate.
    static let marker: UInt64 = freeRunningWords + 1
    /// Even: slot 0 receives the last word.
    static let finalWord: UInt64 = freeRunningWords + 4
    static let barrierTimeout: Duration = .seconds(5)
    static let handshakeTimeout: Duration = .seconds(5)
    static let consumerTimeout: Duration = .seconds(30)
    static let joinTimeoutSeconds = 45.0

    let slots: Slots
    let arrived = Atomic<Int>(0)
    /// The highest word the consumer has observed; the producer's handshake waits on it.
    let highestSeen = Atomic<UInt64>(0)
    let barrierTimedOut = Atomic<Bool>(false)
    let handshakeTimedOut = Atomic<Bool>(false)
    let producerFinished = Atomic<Bool>(false)
    let observation = Mutex(StressObservation())
    let producerDone = DispatchSemaphore(value: 0)
    let consumerDone = DispatchSemaphore(value: 0)

    init(slots: Slots) {
        self.slots = slots
    }

    /// Yields until `done` holds or `timeout` passes; returns whether `done` held.
    private static func wait(upTo timeout: Duration, until done: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !done() {
            if ContinuousClock.now >= deadline { return done() }
            sched_yield()
        }
        return true
    }

    private func arriveAtBarrier() {
        arrived.add(1, ordering: .acquiringAndReleasing)
        if !Self.wait(upTo: Self.barrierTimeout, until: { arrived.load(ordering: .acquiring) >= 2 }) {
            barrierTimedOut.store(true, ordering: .releasing)
        }
    }

    private func publish(_ word: UInt64) {
        _ = slots.publish(slot: Int(word & 1), value: Paired(word), stamp: stamp(Int64(word)))
    }

    func runProducer() {
        arriveAtBarrier()
        for word in 1...Self.freeRunningWords {
            publish(word)
        }
        publish(Self.marker)
        if !Self.wait(upTo: Self.handshakeTimeout, until: { highestSeen.load(ordering: .acquiring) >= Self.marker }) {
            handshakeTimedOut.store(true, ordering: .releasing)
        }
        for word in (Self.marker + 1)...Self.finalWord {
            publish(word)
        }
        producerFinished.store(true, ordering: .releasing)
        producerDone.signal()
    }

    func runConsumer() {
        arriveAtBarrier()
        var seen = StressObservation()
        var lastWord: [UInt64] = [0, 0]
        var lastSequence: [UInt64] = [0, 0]
        let deadline = ContinuousClock.now + Self.consumerTimeout
        while lastWord[0] < Self.finalWord, ContinuousClock.now < deadline {
            for slot in 0..<2 {
                guard let got = sample(slots.latest(slot: slot)) else { continue }
                let ordered = got.value.word >= lastWord[slot] && got.sequence >= lastSequence[slot]
                let matches = got.stamp.frame == Int64(got.value.word)
                    && got.sequence == (got.value.word + 1) / 2
                    && Int(got.value.word & 1) == slot
                if !got.value.isConsistent || !ordered || !matches { seen.failures += 1 }
                if got.value.word != lastWord[slot], got.value.word < Self.finalWord - 1 {
                    seen.distinctIntermediate += 1
                }
                lastWord[slot] = got.value.word
                lastSequence[slot] = got.sequence
            }
            highestSeen.store(max(lastWord[0], lastWord[1]), ordering: .releasing)
        }
        seen.sawFinal = lastWord[0] == Self.finalWord
        observation.withLock { $0 = seen }
        consumerDone.signal()
    }
}
