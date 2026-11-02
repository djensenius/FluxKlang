import Foundation
import Synchronization
import Testing
@testable import FluxKlang

private typealias Root = RealtimeHandoffTests

private func ring(capacity: Int, startingIndex: UInt64 = 0) throws -> SPSCRing<UInt64> {
    try SPSCRing<UInt64>(policy: Root.policy(capacity: capacity), startingIndex: startingIndex)
}

private typealias RingError = SPSCRing<UInt64>.PreparationError

/// Why `SPSCRing.init` refuses `policy`, or `nil` when it accepts it.
private func ringRefusal(_ policy: HandoffPolicy) -> RingError? {
    do {
        _ = try SPSCRing<UInt64>(policy: policy)
        return nil
    } catch {
        return error
    }
}

/// Runs `ops` (true = push, false = pop) against the ring and an `Array` model; returns both traces.
/// Trace codes: push ok = -1, push refused = -2, empty pop = -3, otherwise the popped value.
private func traces(_ ring: SPSCRing<UInt64>, capacity: Int, ops: [Bool]) -> (ring: [Int64], model: [Int64]) {
    var model: [UInt64] = []
    var refusals: UInt64 = 0
    var next: UInt64 = 0
    var actual: [Int64] = []
    var expected: [Int64] = []
    for push in ops {
        if push {
            let status = ring.tryPush(next)
            actual.append(status == .ok ? -1 : status == .refused(.full) ? -2 : -9)
            if model.count < capacity {
                model.append(next)
                expected.append(-1)
            } else {
                refusals += 1
                expected.append(-2)
            }
            next += 1
        } else {
            actual.append(ring.tryPop().map { Int64($0) } ?? -3)
            expected.append(model.isEmpty ? -3 : Int64(model.removeFirst()))
        }
    }
    actual.append(Int64(ring.refusedCount))
    expected.append(Int64(refusals))
    return (actual, expected)
}

private struct SideResult: Sendable {
    var count: UInt64 = 0
    var checksum: UInt64 = 0
    var mismatches = 0
    var torn = 0
    var exhausted = false
}

/// A three-word stress element whose words are derived from one another, so a torn read is detectable.
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
}

private final class StressResults: Sendable {
    let sides = Mutex<(producer: SideResult, consumer: SideResult)>((SideResult(), SideResult()))
}

private func mix(_ value: UInt64) -> UInt64 { (value &+ 1) &* 0x9E37_79B9_7F4A_7C15 }

/// Bounded spin retry. `sched_yield` adds no happens-before edge under TSan, whereas Swift concurrency's runtime
/// annotations do, which would hide a missing release or acquire in the ring.
private func retry(_ failures: inout Int) -> Bool {
    failures += 1
    if failures & 1_023 == 0 { sched_yield() }
    return failures < 200_000_000
}

private func produce(_ ring: SPSCRing<Stamp>, total: UInt64) -> SideResult {
    var side = SideResult()
    var failures = 0
    while side.count < total {
        if ring.tryPush(Stamp(side.count)) == .ok {
            side.checksum &+= mix(side.count)
            side.count += 1
            failures = 0
        } else if !retry(&failures) {
            side.exhausted = true
            break
        }
    }
    return side
}

/// Alternates `tryPop` and `popAll` and checks exact FIFO order and element integrity.
private func consume(_ ring: SPSCRing<Stamp>, total: UInt64) -> SideResult {
    var side = SideResult()
    var failures = 0
    let receive = { (value: Stamp) in
        if !value.isConsistent { side.torn += 1 }
        if value.sequence != side.count { side.mismatches += 1 }
        side.checksum &+= mix(value.sequence)
        side.count += 1
        failures = 0
    }
    while side.count < total {
        if side.count % 2 == 0, let value = ring.tryPop() {
            receive(value)
        } else if ring.popAll(limit: 7, receive) == 0, !retry(&failures) {
            side.exhausted = true
            break
        }
    }
    return side
}

extension RealtimeHandoffTests {
    struct RingCapacity {
        @Test func pushRefusesAtExactlyCapacityAndCounts() throws {
            for capacity in [1, 2, 3, 7, 256, KernelLimits.maximumCapacity] {
                let subject = try ring(capacity: capacity)
                #expect(subject.capacity == capacity)
                for value in 0..<UInt64(capacity) where subject.tryPush(value) != .ok {
                    Issue.record("capacity \(capacity): push \(value) refused below capacity")
                }
                #expect(subject.refusedCount == 0)
                #expect(subject.tryPush(.max) == .refused(.full))
                #expect(subject.refusedCount == 1)
                #expect(subject.tryPush(.max) == .refused(.full))
                #expect(subject.refusedCount == 2)
                var popped: [UInt64] = []
                #expect(subject.popAll(limit: .max) { popped.append($0) } == capacity)
                #expect(popped == Array(0..<UInt64(capacity)))
                #expect(subject.tryPop() == nil)
                #expect(subject.refusedCount == 2)
            }
        }

        @Test func popOnEmptyHasNoSideEffects() throws {
            for capacity in [1, 2, 3] {
                let subject = try ring(capacity: capacity)
                for _ in 0..<3 {
                    #expect(subject.tryPop() == nil)
                    #expect(subject.popAll(limit: .max) { _ in Issue.record("body called on empty") } == 0)
                }
                for value in 0..<UInt64(capacity) {
                    #expect(subject.tryPush(value) == .ok)
                }
                #expect(subject.tryPush(99) == .refused(.full))
                for value in 0..<UInt64(capacity) {
                    #expect(subject.tryPop() == value)
                }
                #expect(subject.tryPop() == nil)
                #expect(subject.tryPush(7) == .ok)
                #expect(subject.tryPop() == 7)
                #expect(subject.refusedCount == 1)
            }
        }

        @Test func fifoMatchesModelForAllShortInterleavings() throws {
            for capacity in 1...3 {
                for length in 0...8 {
                    for mask in 0..<(1 << length) {
                        let ops = (0..<length).map { mask & (1 << $0) != 0 }
                        let result = traces(try ring(capacity: capacity), capacity: capacity, ops: ops)
                        #expect(result.ring == result.model, "capacity \(capacity), ops \(ops)")
                    }
                }
            }
        }

        @Test func indicesNearUInt64MaxMatchModel() throws {
            // Fill, drain and alternate so live elements straddle the wrap from `UInt64.max` to 0.
            for capacity in [1, 2, 3, 5, 7] {
                let ops = Array(repeating: true, count: capacity + 1) + Array(repeating: false, count: capacity + 1)
                    + (0..<(4 * capacity + 8)).map { $0 % 3 != 2 } + Array(repeating: false, count: 2 * capacity)
                for distance: UInt64 in [0, 1, 2, 3, UInt64(capacity), UInt64(capacity) + 1, 20] {
                    let start = UInt64.max &- distance
                    let subject = try ring(capacity: capacity, startingIndex: start)
                    let result = traces(subject, capacity: capacity, ops: ops)
                    #expect(result.ring == result.model, "capacity \(capacity), start max - \(distance)")
                }
                let full = try ring(capacity: capacity, startingIndex: .max &- 1)
                for value in 0..<UInt64(capacity) {
                    #expect(full.tryPush(value) == .ok)
                }
                var popped: [UInt64] = []
                #expect(full.popAll(limit: .max) { popped.append($0) } == capacity)
                #expect(popped == Array(0..<UInt64(capacity)))
            }
        }

        @Test func popAllBoundedByLimitAndCapacity() throws {
            for limit in Root.adversarialInts + [3, 4] {
                let subject = try ring(capacity: 4)
                for value: UInt64 in 0..<3 {
                    #expect(subject.tryPush(value) == .ok)
                }
                var popped: [UInt64] = []
                let count = subject.popAll(limit: limit) { popped.append($0) }
                let expected = min(max(limit, 0), 3)
                #expect(count == expected, "limit \(limit)")
                #expect(popped == Array(0..<UInt64(expected)), "limit \(limit)")
                var rest: [UInt64] = []
                while let value = subject.tryPop() { rest.append(value) }
                #expect(rest == Array(UInt64(expected)..<3), "limit \(limit)")
            }
            let large = try ring(capacity: KernelLimits.maximumCapacity)
            for value in 0..<UInt64(KernelLimits.maximumCapacity) where large.tryPush(value) != .ok {
                Issue.record("push \(value) refused")
            }
            var sum: UInt64 = 0
            #expect(large.popAll(limit: .max) { sum &+= $0 } == KernelLimits.maximumCapacity)
            #expect(sum == UInt64(KernelLimits.maximumCapacity) * UInt64(KernelLimits.maximumCapacity - 1) / 2)
            #expect(large.popAll(limit: .max) { _ in } == 0)
        }

        @Test func popAllToleratesReentrantPop() throws {
            for capacity in [2, 3, 4, 8] {
                let subject = try ring(capacity: capacity)
                var pushed: UInt64 = 0
                var popped: [UInt64] = []
                func push(_ count: Int) {
                    for _ in 0..<count where subject.tryPush(pushed) == .ok { pushed += 1 }
                }
                // Bounded so a desynchronised ring, whose `head` has passed `tail`, fails instead of spinning.
                func drain() {
                    for _ in 0...capacity {
                        guard let value = subject.tryPop() else { return }
                        popped.append(value)
                    }
                }
                // `body` pushes and drains past the `tail` this `popAll` acquired on entry.
                push(2)
                subject.popAll(limit: .max) { value in
                    popped.append(value)
                    guard value == 0 else { return }
                    push(2)
                    drain()
                }
                // Nested `popAll` inside `body`.
                push(capacity)
                subject.popAll(limit: .max) { value in
                    popped.append(value)
                    subject.popAll(limit: 1) { popped.append($0) }
                }
                // The ring must stay coherent afterwards.
                for _ in 0..<(3 * capacity) {
                    push(2)
                    if let value = subject.tryPop() { popped.append(value) }
                }
                drain()
                #expect(subject.tryPop() == nil, "capacity \(capacity)")
                #expect(popped == Array(0..<pushed), "capacity \(capacity)")
                #expect(pushed > UInt64(3 * capacity), "capacity \(capacity)")
            }
        }

        @Test func refusedCountSaturates() throws {
            let subject = try SPSCRing<UInt64>(policy: Root.policy(capacity: 1), startingIndex: 0,
                                               startingRefusals: .max - 2)
            #expect(subject.tryPush(1) == .ok)
            var counts: [UInt64] = []
            for _ in 0..<4 {
                #expect(subject.tryPush(2) == .refused(.full))
                counts.append(subject.refusedCount)
            }
            #expect(counts == [.max - 1, .max, .max, .max])
            #expect(subject.tryPop() == 1)
        }

        @Test func storageAddressStableAcrossCycles() throws {
            for capacity in [1, 3, 64] {
                let subject = try ring(capacity: capacity)
                let base = subject.storageBaseAddress
                var next: UInt64 = 0
                for round in 0..<10 {
                    while subject.tryPush(next) == .ok { next += 1 }
                    #expect(subject.storageBaseAddress == base, "capacity \(capacity), round \(round) full")
                    _ = subject.popAll(limit: .max) { _ in }
                    for _ in 0..<capacity {
                        _ = subject.tryPush(next)
                        next += 1
                        _ = subject.tryPop()
                    }
                    #expect(subject.storageBaseAddress == base, "capacity \(capacity), round \(round) drained")
                }
            }
        }

        @Test func initRejectsMultiProducerPolicy() {
            let fanIn = [
                Root.policy(producers: .init(maximum: 2, evidence: .appOwned)),
                Root.policy(producers: .init(maximum: KernelLimits.maximumProducers, evidence: .verified)),
                Root.policy(producer: .worker, producers: .conservativeDefault(for: .worker)),
                Root.sysexPolicy()
            ]
            for policy in fanIn {
                #expect(Root.violation(policy) == nil)
                #expect(ringRefusal(policy) == .policy(.violates(.r2Cardinality)))
            }
            // Valid policies served by other containers.
            let telemetry = Root.telemetryPolicy()
            #expect(Root.violation(telemetry) == nil)
            #expect(ringRefusal(telemetry) == .unsupportedPolicy(.overwriteLatest))
            let reserved = Root.policy(overflow: .defaultCriticalReserve(capacity: 256) ?? .refuseProducer)
            #expect(Root.violation(reserved) == nil)
            #expect(ringRefusal(reserved) == .unsupportedPolicy(.reservedCritical))
            // Invalid policies surface the validator's own rule.
            #expect(ringRefusal(Root.policy(consumers: 2)) == .policy(.violates(.r1SingleConsumer)))
            for capacity in Root.adversarialInts where capacity < 1 {
                #expect(ringRefusal(Root.policy(capacity: capacity)) == .policy(.violates(.r3Capacity)))
            }
            #expect(ringRefusal(Root.policy(ordering: .latestOnly)) == .policy(.violates(.r4LatestOnly)))
            // Accepted: single-producer FIFO orderings, including verified single-producer SysEx (E4).
            let sysex = Root.policy(purpose: .sysex, producer: .midiReceive,
                                    producers: .init(maximum: 1, evidence: .verified), consumer: .control,
                                    ordering: .completeMessagesFIFO, deadline: .none)
            for policy in [Root.policy(), Root.policy(ordering: .fifoPerProducer), Root.policy(capacity: 1), sysex] {
                #expect(ringRefusal(policy) == nil)
            }
        }

        @Test func nonIntegerElementsRoundTrip() throws {
            Root.requireBitwise(KernelStatus.self)
            let subject = try SPSCRing<KernelStatus>(policy: Root.policy(capacity: 2))
            #expect(subject.tryPush(.refused(.notOwner)) == .ok)
            #expect(subject.tryPush(.silenced(.safetyMute)) == .ok)
            #expect(subject.tryPush(.ok) == .refused(.full))
            #expect(subject.tryPop() == .refused(.notOwner))
            #expect(subject.tryPop() == .silenced(.safetyMute))
            #expect(subject.tryPop() == nil)
        }

        @Test func endpointsAreClaimedOnceAndMoveByConsume() async throws {
            let subject = try ring(capacity: 8)
            guard let producer = subject.makeProducer(), let consumer = subject.makeConsumer() else {
                Issue.record("first claim of each endpoint must succeed")
                return
            }
            let secondProducer = subject.makeProducer() == nil
            let secondConsumer = subject.makeConsumer() == nil
            #expect(secondProducer && secondConsumer)
            let pushes = Task { [producer = consume producer] in
                (0..<10).map { producer.tryPush(UInt64($0)) }
            }
            let expected: [KernelStatus] = Array(repeating: .ok, count: 8) + [.refused(.full), .refused(.full)]
            #expect(await pushes.value == expected)
            #expect(consumer.tryPop() == 0)
            var popped: [UInt64] = []
            #expect(consumer.popAll(limit: .max) { popped.append($0) } == 7)
            #expect(popped == Array(1..<8))
            #expect(subject.refusedCount == 2)
        }
    }

    struct RingStress {
        /// Two OS threads rather than a `TaskGroup`: TSan cannot see a missing release or acquire between tasks.
        @Test(.timeLimit(.minutes(1)))
        func stressExactFIFOWithChecksum() throws {
            let total: UInt64 = 1_000_000
            let subject = try SPSCRing<Stamp>(policy: Root.policy(capacity: 16))
            let results = StressResults()
            let done = DispatchSemaphore(value: 0)
            Thread {
                let side = produce(subject, total: total)
                results.sides.withLock { $0.producer = side }
                done.signal()
            }.start()
            Thread {
                let side = consume(subject, total: total)
                results.sides.withLock { $0.consumer = side }
                done.signal()
            }.start()
            // `.timeLimit` cannot interrupt a semaphore wait, so bound both waits within its minute.
            for _ in 0..<2 where done.wait(timeout: .now() + .seconds(25)) == .timedOut {
                Issue.record("stress thread did not finish")
                // Safe to return: the threads keep running but touch only Sendable objects they strongly retain.
                return
            }
            let (producer, consumer) = results.sides.withLock { $0 }
            #expect(!producer.exhausted && !consumer.exhausted)
            #expect(producer.count == total && consumer.count == total)
            #expect(consumer.mismatches == 0 && consumer.torn == 0)
            #expect(consumer.checksum == producer.checksum)
            #expect(subject.tryPop() == nil)
        }
    }
}
