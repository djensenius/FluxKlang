import Foundation
import Synchronization
import Testing
@testable import FluxKlang

private typealias Root = RealtimeHandoffTests
private typealias RingError = ReservedCapacityRing<UInt64>.PreparationError

private let ringScope = FaultScope(handoff: 4, target: 2)
private let neighbourScope = FaultScope(handoff: 4, target: 3)

private func reservedPolicy(capacity: Int = 20, reserved: Int = 16) -> HandoffPolicy {
    Root.policy(capacity: capacity, overflow: .reservedCritical(reserved: reserved))
}

private func makeLatch() throws -> FaultLatch {
    try FaultLatch(scopes: [ringScope, neighbourScope])
}

private func makeRing(_ faults: FaultLatch, capacity: Int = 20, reserved: Int = 16, startingIndex: UInt64 = 0,
                      startingRefusals: UInt64 = 0) throws -> ReservedCapacityRing<UInt64> {
    try ReservedCapacityRing<UInt64>(policy: reservedPolicy(capacity: capacity, reserved: reserved), faults: faults,
                                     scope: ringScope, startingIndex: startingIndex,
                                     startingRefusals: startingRefusals)
}

/// Why `init` refuses `policy`, or `nil` when it accepts it.
private func refusal(_ policy: HandoffPolicy, _ faults: FaultLatch) -> RingError? {
    do {
        _ = try ReservedCapacityRing<UInt64>(policy: policy, faults: faults, scope: ringScope)
        return nil
    } catch {
        return error
    }
}

/// The latched record for `ringScope`, if any.
private func record(_ faults: FaultLatch) -> FaultRecord? {
    var found: FaultRecord?
    _ = faults.pending { if $0.scope == ringScope { found = $0 } }
    return found
}

private func drain(_ ring: ReservedCapacityRing<UInt64>) -> [UInt64] {
    var values: [UInt64] = []
    while let value = ring.tryPop() { values.append(value) }
    return values
}

/// A small deterministic generator so model runs are reproducible.
private struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

extension RealtimeHandoffTests {
    struct ReservedRingCapacity {
        @Test func initRejectsPoliciesWithoutAValidReserve() throws {
            let faults = try makeLatch()
            #expect(refusal(Root.policy(), faults) == .unsupportedPolicy(.refuseProducer))
            #expect(refusal(Root.telemetryPolicy(), faults) == .unsupportedPolicy(.overwriteLatest))
            for reserved in Root.adversarialInts + [20, 21] where !(1..<20).contains(reserved) {
                #expect(refusal(reservedPolicy(reserved: reserved), faults) == .policy(.violates(.r7Reserve)))
            }
            for reserved in 1..<KernelLimits.minimumCriticalReserve {
                #expect(refusal(reservedPolicy(capacity: 64, reserved: reserved), faults)
                        == .reserveBelowMinimum(reserved))
            }
            #expect(refusal(reservedPolicy(capacity: 16, reserved: 16), faults) == .policy(.violates(.r7Reserve)))
            #expect(refusal(reservedPolicy(capacity: 17, reserved: 16), faults) == nil)
            let fanIn = Root.policy(producer: .midiReceive, producers: .conservativeDefault(for: .midiReceive),
                                    overflow: .reservedCritical(reserved: 16))
            #expect(refusal(fanIn, faults) == .policy(.violates(.r2Cardinality)))
            let shared = Root.policy(consumers: 2, overflow: .reservedCritical(reserved: 16))
            #expect(refusal(shared, faults) == .policy(.violates(.r1SingleConsumer)))
            for capacity in [17, 128, KernelLimits.maximumCapacity] {
                let overflow = try #require(OverflowPolicy.defaultCriticalReserve(capacity: capacity))
                guard case .reservedCritical(let reserved) = overflow else { continue }
                let ring = try ReservedCapacityRing<UInt64>(policy: Root.policy(capacity: capacity, overflow: overflow),
                                                            faults: faults, scope: ringScope)
                #expect(ring.capacity == capacity && ring.reserved == reserved)
                #expect(ring.generalLimit == capacity - reserved)
            }
        }

        /// For every occupancy `k`, built from critical events, a general push is admitted exactly when
        /// `k < capacity − reserved`; refusals are `.full`, counted and never raise a fault.
        @Test func generalRefusedAtCapacityMinusReserve() throws {
            for occupancy in 0...20 {
                let faults = try makeLatch()
                let ring = try makeRing(faults)
                for value in 0..<occupancy {
                    #expect(ring.tryPush(UInt64(value), class: .critical, frame: 0) == .ok)
                }
                #expect(ring.producerOccupancy == occupancy)
                let admitted = occupancy < 4
                #expect(ring.tryPush(99, class: .general, frame: 0) == (admitted ? .ok : .refused(.full)))
                #expect(ring.refusedGeneralCount == (admitted ? 0 : 1))
                #expect(ring.refusedCriticalCount == 0 && !faults.isLatched(ringScope))
                #expect(drain(ring) == (0..<occupancy).map(UInt64.init) + (admitted ? [99] : []))
            }
        }

        @Test func criticalUsesReserveAfterGeneralFull() throws {
            let faults = try makeLatch()
            let ring = try makeRing(faults)
            for value in 0..<4 { #expect(ring.tryPush(UInt64(value), class: .general, frame: 0) == .ok) }
            #expect(ring.tryPush(4, class: .general, frame: 0) == .refused(.full))
            for value in 5..<21 { #expect(ring.tryPush(UInt64(value), class: .critical, frame: 0) == .ok) }
            #expect(ring.producerOccupancy == 20)
            #expect(!faults.isLatched(ringScope) && ring.refusedCriticalCount == 0)
            #expect(drain(ring) == [0, 1, 2, 3] + (5..<21).map(UInt64.init))
        }

        @Test func criticalExhaustionRaisesScopedFaultAndRefuses() throws {
            let faults = try makeLatch()
            let ring = try makeRing(faults)
            for value in 0..<20 { #expect(ring.tryPush(UInt64(value), class: .critical, frame: 0) == .ok) }
            #expect(ring.tryPush(98, class: .general, frame: 7) == .refused(.full))
            #expect(!faults.isLatched(ringScope))
            #expect(ring.tryPush(99, class: .critical, frame: 1_234) == .refused(.criticalExhausted))
            #expect(faults.isLatched(ringScope) && !faults.isLatched(neighbourScope))
            #expect(record(faults) == FaultRecord(scope: ringScope, kind: .criticalExhausted, count: 1,
                                                  firstFrame: 1_234))
            #expect(ring.tryPush(100, class: .critical, frame: .min) == .refused(.criticalExhausted))
            #expect(record(faults)?.count == 2 && record(faults)?.firstFrame == 1_234)
            #expect(ring.refusedCriticalCount == 2 && ring.refusedGeneralCount == 1 && ring.refusedCount == 3)
            #expect(drain(ring) == (0..<20).map(UInt64.init))
            for frame in Root.adversarialFrames {
                let latch = try makeLatch()
                let full = try makeRing(latch, capacity: 17)
                for value in 0..<17 { _ = full.tryPush(UInt64(value), class: .critical, frame: frame) }
                #expect(full.tryPush(0, class: .critical, frame: frame) == .refused(.criticalExhausted))
                #expect(record(latch)?.firstFrame == frame && record(latch)?.kind == .criticalExhausted)
            }
        }

        /// An unprepared scope still refuses and stays visible through `unknownScopeFaults`.
        @Test func criticalExhaustionOnUnpreparedScopeIsStillVisible() throws {
            let faults = try FaultLatch(scopes: [neighbourScope])
            let ring = try ReservedCapacityRing<UInt64>(policy: reservedPolicy(capacity: 17), faults: faults,
                                                        scope: ringScope)
            for value in 0..<17 { #expect(ring.tryPush(UInt64(value), class: .critical, frame: 0) == .ok) }
            #expect(ring.tryPush(0, class: .critical, frame: 3) == .refused(.criticalExhausted))
            #expect(faults.unknownScopeFaults == 1 && ring.refusedCriticalCount == 1)
        }

        /// Refused events are refused whole; queued stateful events are never merged, replaced or reordered.
        @Test func overflowNeverMergesOrReordersStatefulEvents() throws {
            let faults = try makeLatch()
            let ring = try ReservedCapacityRing<KernelEvent>(policy: reservedPolicy(), faults: faults,
                                                             scope: ringScope)
            var accepted: [KernelEvent] = []
            for index in 0..<90 {
                let payload: KernelEventPayload = index % 3 == 2
                    ? .noteOff(channel: 0, note: 60)
                    : index % 3 == 1 ? .program(channel: 0, program: UInt8(index), bank: 0)
                    : .control(channel: 0, controller: 7, value: UInt32(index))
                let event = KernelEvent(frame: 0, scope: 1, sequence: UInt64(index), payload: payload)
                if ring.tryPush(event, class: event.eventClass, frame: event.frame) == .ok { accepted.append(event) }
                if index % 15 == 14, let popped = ring.tryPop() { #expect(popped == accepted.removeFirst()) }
            }
            var rest: [KernelEvent] = []
            #expect(ring.popAll(limit: .max) { rest.append($0) } == accepted.count)
            #expect(rest == accepted)
            #expect(ring.refusedGeneralCount > 0 && ring.refusedCriticalCount > 0)
        }

        @Test func reserveRestoredAfterDrain() throws {
            let faults = try makeLatch()
            let ring = try makeRing(faults)
            for cycle in 1...3 {
                var admitted = 0
                while ring.tryPush(UInt64(admitted), class: .general, frame: 0) == .ok { admitted += 1 }
                #expect(admitted == 4)
                for value in 4..<20 { #expect(ring.tryPush(UInt64(value), class: .critical, frame: 0) == .ok) }
                #expect(ring.tryPush(20, class: .critical, frame: Int64(cycle)) == .refused(.criticalExhausted))
                // Drain through both consumer paths: each must hand the reserve back.
                var popped: [UInt64] = []
                if cycle == 2 {
                    popped = drain(ring)
                } else {
                    #expect(ring.popAll(limit: .max) { popped.append($0) } == 20)
                }
                #expect(popped == (0..<20).map(UInt64.init) && ring.tryPop() == nil)
                #expect(ring.producerOccupancy == 0)
                #expect(ring.refusedGeneralCount == UInt64(cycle) && ring.refusedCriticalCount == UInt64(cycle))
                #expect(record(faults)?.count == UInt64(cycle) && record(faults)?.firstFrame == 1)
            }
        }

        @Test func popAllIsBoundedAndToleratesReentrantPop() throws {
            let ring = try makeRing(try makeLatch())
            for value in 0..<10 { _ = ring.tryPush(UInt64(value), class: .critical, frame: 0) }
            for limit in [Int.min, -1, 0] { #expect(ring.popAll(limit: limit) { _ in Issue.record("popped") } == 0) }
            var seen: [UInt64] = []
            #expect(ring.popAll(limit: 2) { seen.append($0) } == 2)
            #expect(ring.popAll(limit: .max) { value in
                seen.append(value)
                if let next = ring.tryPop() { seen.append(next + 1_000) }
            } == 4)
            #expect(seen == [0, 1, 2, 1_003, 4, 1_005, 6, 1_007, 8, 1_009])
            #expect(ring.popAll(limit: .max) { _ in } == 0 && ring.producerOccupancy == 0)
        }

        @Test func refusalCountersSaturate() throws {
            let ring = try makeRing(try makeLatch(), capacity: 17, startingRefusals: .max - 1)
            for value in 0..<17 { _ = ring.tryPush(UInt64(value), class: .critical, frame: 0) }
            for _ in 0..<3 {
                #expect(ring.tryPush(0, class: .general, frame: 0) == .refused(.full))
                #expect(ring.tryPush(0, class: .critical, frame: 0) == .refused(.criticalExhausted))
            }
            #expect(ring.refusedGeneralCount == .max && ring.refusedCriticalCount == .max && ring.refusedCount == .max)
        }

        /// Seeded mixed traffic against an `Array` model: FIFO across classes, both limits, counters and faults,
        /// for capacities that are not powers of two and indices that cross `UInt64.max` over many laps.
        @Test(arguments: [(17, 16, UInt64(0)), (20, 16, UInt64.max - 7), (33, 16, UInt64.max - 100),
                          (64, 32, UInt64(0))])
        func mixedTrafficMatchesModelAcrossWrap(capacity: Int, reserved: Int, start: UInt64) throws {
            let faults = try makeLatch()
            let ring = try makeRing(faults, capacity: capacity, reserved: reserved, startingIndex: start)
            var random = SplitMix(state: UInt64(capacity))
            var model: [UInt64] = []
            var refusals = (general: UInt64(0), critical: UInt64(0))
            var firstFrame: Int64?
            var mismatches = 0
            for step in 0..<20_000 {
                // Alternating 150-step phases: filling (mostly pushes, half critical) reaches both limits; draining
                // (mostly pops) empties the ring.
                let roll = random.next() % 16
                let filling = (step / 150) % 2 == 0
                if roll < (filling ? 14 : 4) {
                    let critical = random.next() % 2 == 0
                    let frame = Int64(step)
                    let status = ring.tryPush(UInt64(step), class: critical ? .critical : .general, frame: frame)
                    let expected: KernelStatus
                    if model.count < (critical ? capacity : capacity - reserved) {
                        model.append(UInt64(step))
                        expected = .ok
                    } else if critical {
                        refusals.critical += 1
                        firstFrame = firstFrame ?? frame
                        expected = .refused(.criticalExhausted)
                    } else {
                        refusals.general += 1
                        expected = .refused(.full)
                    }
                    if status != expected { mismatches += 1 }
                } else if roll < (filling ? 15 : 10) {
                    if ring.tryPop() != (model.isEmpty ? nil : model.removeFirst()) { mismatches += 1 }
                } else {
                    let limit = Int(random.next() % 6)
                    var popped: [UInt64] = []
                    let count = ring.popAll(limit: limit) { popped.append($0) }
                    let expected = Array(model.prefix(limit))
                    model.removeFirst(expected.count)
                    if popped != expected || count != expected.count { mismatches += 1 }
                }
                if ring.producerOccupancy != model.count { mismatches += 1 }
            }
            #expect(mismatches == 0)
            #expect(ring.refusedGeneralCount == refusals.general && ring.refusedCriticalCount == refusals.critical)
            #expect(refusals.general > 0 && refusals.critical > 0)
            #expect(record(faults)?.count == refusals.critical && record(faults)?.firstFrame == firstFrame)
            #expect(drain(ring) == model)
        }

        @Test func valuesAreBitwiseCopyable() {
            Root.requireBitwise(EventClass.self)
            Root.requireBitwise(KernelEvent.self)
        }
    }
}

/// A three-word element whose words derive from one another, so a torn read shows; its class is a function of
/// its sequence, so the consumer can check the mix without shared state.
private struct Stamp: BitwiseCopyable, Sendable {
    let sequence: UInt64
    let inverse: UInt64
    let scaled: UInt64

    init(_ sequence: UInt64) {
        self.sequence = sequence
        inverse = ~sequence
        scaled = sequence &* 0x9E37_79B9_7F4A_7C15
    }

    var isConsistent: Bool { inverse == ~sequence && scaled == sequence &* 0x9E37_79B9_7F4A_7C15 }

    /// About one event in four is critical (note release).
    static func eventClass(_ sequence: UInt64) -> EventClass {
        (sequence &* 0x9E37_79B9_7F4A_7C15) >> 62 == 0 ? .critical : .general
    }
}

private struct ProducerSide: Sendable {
    var accepted: [Bool] = []
    var refused = (general: UInt64(0), critical: UInt64(0))
    var firstCriticalRefusal: Int64?
    var wrongStatus = 0
    var maxGeneralOccupancy = 0
    var maxOccupancy = 0
    var finished = false
}

private struct ConsumerSide: Sendable {
    var popped: [Bool] = []
    var count: UInt64 = 0
    var outOfOrder = 0
    var torn = 0
    var finished = false
}

/// Shared flags for one stress run. Every worker loop is bounded by `deadline` and by `cancelled`.
private final class RingStressState: Sendable {
    let arrived = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    let cancelled = Atomic<Bool>(false)
    let producerDone = Atomic<Bool>(false)
    let exited = Atomic<Int>(0)
    let producer = Mutex(ProducerSide())
    let consumer = Mutex(ConsumerSide())
    let deadline = ContinuousClock.now + .seconds(25)

    var shouldStop: Bool { cancelled.load(ordering: .acquiring) || ContinuousClock.now >= deadline }

    /// Arrival barrier: counts this worker in, then waits (bounded) for the controller's start flag.
    func arriveAndWait() -> Bool {
        arrived.add(1, ordering: .releasing)
        while !started.load(ordering: .acquiring) {
            if shouldStop { return false }
        }
        return !cancelled.load(ordering: .acquiring)
    }
}

private func produce(_ ring: ReservedCapacityRing<Stamp>, total: Int, _ state: RingStressState) -> ProducerSide {
    var side = ProducerSide()
    side.accepted = Array(repeating: false, count: total)
    guard state.arriveAndWait() else { return side }
    for index in 0..<total {
        if index & 1_023 == 0, state.shouldStop { return side }
        let sequence = UInt64(index)
        let eventClass = Stamp.eventClass(sequence)
        let status = ring.tryPush(Stamp(sequence), class: eventClass, frame: Int64(index))
        switch (status, eventClass) {
        case (.ok, _):
            side.accepted[index] = true
            // Producer-side occupancy just after this push: conservative (a stale consumer count only raises it).
            let occupancy = ring.producerOccupancy
            side.maxOccupancy = max(side.maxOccupancy, occupancy)
            if eventClass == .general { side.maxGeneralOccupancy = max(side.maxGeneralOccupancy, occupancy) }
        case (.refused(.full), .general):
            side.refused.general += 1
        case (.refused(.criticalExhausted), .critical):
            side.refused.critical += 1
            side.firstCriticalRefusal = side.firstCriticalRefusal ?? Int64(index)
        default:
            side.wrongStatus += 1
        }
    }
    side.finished = true
    return side
}

/// Alternates `tryPop` and `popAll`; checks strictly increasing sequences, integrity and duplicates.
private func consume(_ ring: ReservedCapacityRing<Stamp>, total: Int, _ state: RingStressState) -> ConsumerSide {
    var side = ConsumerSide()
    side.popped = Array(repeating: false, count: total)
    guard state.arriveAndWait() else { return side }
    var last: UInt64?
    let receive = { (value: Stamp) in
        if !value.isConsistent || value.sequence >= UInt64(total) {
            side.torn += 1
            return
        }
        if let previous = last, value.sequence <= previous { side.outOfOrder += 1 }
        last = value.sequence
        side.popped[Int(value.sequence)] = true
        side.count += 1
    }
    var round = 0
    while !state.shouldStop {
        // Acquire `producerDone` before draining: an empty drain after it means every push has been seen.
        let done = state.producerDone.load(ordering: .acquiring)
        round += 1
        var drained = 0
        if round % 2 == 0, let value = ring.tryPop() {
            receive(value)
            drained = 1
        } else {
            drained = ring.popAll(limit: 5, receive)
        }
        if drained == 0, done {
            side.finished = true
            break
        }
    }
    return side
}

extension RealtimeHandoffTests {
    /// Dedicated `Thread`s (not a `TaskGroup`, whose runtime annotations would hide a missing acquire or release
    /// from TSan). Run under TSan with `--filter Stress`.
    struct ReservedRingStress {
        @Test(.timeLimit(.minutes(1)))
        func stressMixedClassesConserveAndRespectReserve() throws {
            let total = 400_000
            let faults = try makeLatch()
            let ring = try ReservedCapacityRing<Stamp>(policy: reservedPolicy(capacity: 24, reserved: 16),
                                                       faults: faults, scope: ringScope)
            let state = RingStressState()
            Thread {
                let side = produce(ring, total: total, state)
                state.producer.withLock { $0 = side }
                state.producerDone.store(true, ordering: .releasing)
                state.exited.add(1, ordering: .releasing)
            }.start()
            Thread {
                let side = consume(ring, total: total, state)
                state.consumer.withLock { $0 = side }
                state.exited.add(1, ordering: .releasing)
            }.start()
            while state.arrived.load(ordering: .acquiring) < 2, ContinuousClock.now < state.deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            state.started.store(true, ordering: .releasing)
            while state.exited.load(ordering: .acquiring) < 2, ContinuousClock.now < state.deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if state.exited.load(ordering: .acquiring) < 2 {
                state.cancelled.store(true, ordering: .releasing)
                Issue.record("reserved ring stress timed out; workers cancelled")
                let grace = ContinuousClock.now + .seconds(5)
                while state.exited.load(ordering: .acquiring) < 2, ContinuousClock.now < grace {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                // A worker that never exited may still touch the ring: skip the post-run state checks.
                guard state.exited.load(ordering: .acquiring) == 2 else { return }
            }
            let producer = state.producer.withLock { $0 }
            let consumer = state.consumer.withLock { $0 }
            #expect(producer.finished && consumer.finished)
            guard producer.finished, consumer.finished else { return }
            let refused = producer.refused.general + producer.refused.critical
            print("ReservedRingStress refused general \(producer.refused.general), critical "
                  + "\(producer.refused.critical); max occupancy \(producer.maxOccupancy), "
                  + "max after general \(producer.maxGeneralOccupancy)")
            #expect(producer.wrongStatus == 0 && consumer.torn == 0 && consumer.outOfOrder == 0)
            #expect(UInt64(total) - refused == consumer.count)
            #expect(producer.accepted == consumer.popped)
            #expect(producer.maxGeneralOccupancy <= ring.generalLimit && producer.maxOccupancy <= ring.capacity)
            #expect(ring.refusedGeneralCount == producer.refused.general)
            #expect(ring.refusedCriticalCount == producer.refused.critical)
            if let first = producer.firstCriticalRefusal {
                #expect(record(faults) == FaultRecord(scope: ringScope, kind: .criticalExhausted,
                                                      count: producer.refused.critical, firstFrame: first))
            } else {
                #expect(!faults.isLatched(ringScope))
            }
            #expect(ring.tryPop() == nil && ring.producerOccupancy == 0)
        }
    }
}
