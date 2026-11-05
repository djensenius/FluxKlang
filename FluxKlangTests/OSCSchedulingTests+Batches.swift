import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Deterministic ordering, bounded capacity, cancellation and draining of
/// all-or-nothing batches.
extension OSCSchedulingTests {
    @Test func policyValidationIsBounded() throws {
        let limit = OSC.SchedulingPolicy.capacityLimit
        let widest = try Fixture.policy(batches: limit, messages: limit, depth: OSC.SchedulingPolicy.bundleDepthLimit)
        #expect(widest.maximumPendingBatches == limit && widest.maximumPendingMessages == limit)
        #expect(widest.maximumBundleDepth == 64)
        #expect(throws: Refusal.invalidCapacity(.pendingBatches, 0)) { try Fixture.policy(batches: 0) }
        #expect(throws: Refusal.invalidCapacity(.pendingBatches, limit + 1)) {
            try Fixture.policy(batches: limit + 1)
        }
        #expect(throws: Refusal.invalidCapacity(.pendingMessages, 0)) { try Fixture.policy(messages: 0) }
        #expect(throws: Refusal.invalidCapacity(.pendingMessages, limit + 1)) {
            try Fixture.policy(messages: limit + 1)
        }
        let horizon: UInt64 = 1_073_741_824_000_000_000 // 2^30 s
        #expect(try Fixture.policy(future: horizon).maximumFutureNanoseconds == horizon)
        #expect(throws: Refusal.futureHorizonOutOfRange(nanoseconds: horizon + 1)) {
            try Fixture.policy(future: horizon + 1)
        }
        #expect(throws: Refusal.futureHorizonOutOfRange(nanoseconds: .max)) { try Fixture.policy(future: .max) }
        #expect(try Fixture.policy(late: .max).lateHorizonNanoseconds == .max)
        #expect(throws: Refusal.invalidBundleDepth(0)) { try Fixture.policy(depth: 0) }
        #expect(throws: Refusal.invalidBundleDepth(65)) { try Fixture.policy(depth: 65) }
        let defaults = try OSC.SchedulingPolicy(lateHorizonNanoseconds: 1, maximumFutureNanoseconds: 2)
        #expect(defaults.maximumPendingBatches == 256 && defaults.maximumPendingMessages == 4_096)
        #expect(defaults.maximumBundleDepth == 8 && defaults.lateHorizonNanoseconds == 1)
        #expect(defaults.maximumFutureNanoseconds == 2)
    }

    @Test func earlierTimeSortsFirstRegardlessOfArrival() throws {
        var scheduler = try Fixture.scheduler()
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 5), 1), now: Fixture.host(0))
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 2), 2), now: Fixture.host(0))
        _ = try scheduler.admit(Fixture.message(3), now: Fixture.host(0))
        #expect(Fixture.values(scheduler.pending.flatMap(\.messages)) == [3, 2, 1])
        #expect(scheduler.pending.map(\.arrival) == [2, 1, 0])
    }

    @Test func equalTimesTieOnArrivalThenPreOrder() throws {
        var scheduler = try Fixture.scheduler()
        let tag = Fixture.tag(after: 1)
        let nested = Fixture.bundle(tag, [
            Fixture.bundle(tag, [try Fixture.message(2), Fixture.bundle(tag, [try Fixture.message(3)])]),
            try Fixture.message(1),
            try Fixture.timed(tag, 4)
        ])
        _ = try scheduler.admit(nested, now: Fixture.host(0))
        _ = try scheduler.admit(Fixture.timed(tag, 5), now: Fixture.host(0))
        #expect(scheduler.pending.map(\.bundleIndex) == [0, 1, 2, 3, 0])
        #expect(scheduler.pending.map(\.arrival) == [0, 0, 0, 0, 1])
        #expect(scheduler.pending.map { Fixture.values($0.messages) } == [[1], [2], [3], [4], [5]])
        #expect(scheduler.pending.map(\.id.value) == [0, 1, 2, 3, 4])
    }

    /// Instants inside one host tick share `earliest`; the earlier wall instant
    /// goes first even if it arrived later, and equal instants keep arrival order.
    @Test func sameTickTimesOrderByInstantThenArrival() throws {
        var scheduler = try Fixture.scheduler(timebase: Fixture.appleTimebase)
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 1, fraction: 9), 1), now: Fixture.host(0))
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 1, fraction: 1), 2), now: Fixture.host(0))
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 1, fraction: 1), 3), now: Fixture.host(0))
        let windows = scheduler.pending.map { Fixture.offsets($0.window) }
        #expect(windows == Array(repeating: [24_000_000, 24_000_001], count: 3))
        #expect(Fixture.values(scheduler.pending.flatMap(\.messages)) == [2, 3, 1])
        #expect(scheduler.pending.map(\.arrival) == [1, 2, 0])
    }

    /// On a shared earliest tick an immediate batch (whose instant is that tick)
    /// precedes a timed one (whose instant may lie anywhere in its window); a timed
    /// window opening earlier still goes first even though it closes later.
    @Test func immediateBatchPrecedesTimedBatchOnTheSameTick() throws {
        var scheduler = try Fixture.scheduler()
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 0), 1), now: Fixture.host(0))
        _ = try scheduler.admit(Fixture.message(2), now: Fixture.host(0))
        #expect(scheduler.pending.map { Fixture.offsets($0.window) } == [[0, 0], [0, 1]])
        #expect(Fixture.values(scheduler.pending.flatMap(\.messages)) == [2, 1])
        var uncertain = try Fixture.scheduler(mapping: Fixture.mapping(uncertainty: 10))
        _ = try uncertain.admit(Fixture.message(1), now: Fixture.host(0))
        _ = try uncertain.admit(Fixture.timed(Fixture.tag(after: 0), 2), now: Fixture.host(0))
        #expect(uncertain.pending.map { Fixture.offsets($0.window) } == [[-10, 11], [0, 0]])
        #expect(Fixture.values(uncertain.pending.flatMap(\.messages)) == [2, 1])
    }

    @Test func batchesAreOnePerBundleWithMessagesInElementOrder() throws {
        var scheduler = try Fixture.scheduler()
        let packet = Fixture.bundle(Fixture.tag(after: 1), [
            try Fixture.message(1), Fixture.bundle(Fixture.tag(after: 2)), try Fixture.message(2, "/fx/3/on"),
            Fixture.bundle(Fixture.tag(after: 3), [try Fixture.message(3)]), try Fixture.message(4)
        ])
        let batches = try scheduler.admit(packet, now: Fixture.host(0))
        #expect(batches.map(\.bundleIndex) == [0, 2])
        #expect(batches.map { Fixture.values($0.messages) } == [[1, 2, 4], [3]])
        #expect(batches[0].messages[1].address.stringValue == "/fx/3/on")
        #expect(scheduler.pendingMessageCount == 4)
    }

    @Test func pendingBatchCapacityIsNThenRefusesNPlusOne() throws {
        var scheduler = try Fixture.scheduler(policy: Fixture.policy(batches: 2))
        let inner = try Fixture.timed(Fixture.tag(after: 2), 2)
        let two = Fixture.bundle(Fixture.tag(after: 1), [try Fixture.message(1), inner])
        #expect(try scheduler.admit(two, now: Fixture.host(0)).count == 2)
        let one = try Fixture.timed(Fixture.tag(after: 3), 3)
        let full = Refusal.capacityExceeded(.pendingBatches, limit: 2)
        #expect(Fixture.refusal(scheduler) { try $0.admit(one, now: Fixture.host(0)) } == full)
        _ = try scheduler.cancel(try #require(scheduler.pending.first).id)
        #expect(try scheduler.admit(one, now: Fixture.host(0)).count == 1)
        let fresh = try Fixture.scheduler(policy: Fixture.policy(batches: 2))
        let three = Fixture.bundle(Fixture.tag(after: 1), [try Fixture.message(), two])
        #expect(Fixture.refusal(fresh) { try $0.admit(three, now: Fixture.host(0)) } == full)
    }

    @Test func pendingMessageCapacityIsNThenRefusesNPlusOne() throws {
        var scheduler = try Fixture.scheduler(policy: Fixture.policy(messages: 3))
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 1), 1, 2), now: Fixture.host(0))
        _ = try scheduler.admit(Fixture.message(3), now: Fixture.host(0))
        #expect(scheduler.pendingMessageCount == 3)
        let full = Refusal.capacityExceeded(.pendingMessages, limit: 3)
        #expect(Fixture.refusal(scheduler) { try $0.admit(Fixture.message(4), now: Fixture.host(0)) } == full)
        #expect(try scheduler.due(now: Fixture.host(0)).dispatch.count == 1)
        #expect(scheduler.pendingMessageCount == 2)
        #expect(try scheduler.admit(Fixture.message(4), now: Fixture.host(0)).count == 1)
        let fresh = try Fixture.scheduler(policy: Fixture.policy(messages: 3))
        let four = try Fixture.timed(Fixture.tag(after: 1), 1, 2, 3, 4)
        #expect(Fixture.refusal(fresh) { try $0.admit(four, now: Fixture.host(0)) } == full)
    }

    @Test func cancelRemovesExactlyOnePendingBatch() throws {
        var scheduler = try Fixture.scheduler()
        let inner = try Fixture.timed(Fixture.tag(after: 2), 2, 3)
        let packet = Fixture.bundle(Fixture.tag(after: 1), [try Fixture.message(1), inner])
        let batches = try scheduler.admit(packet, now: Fixture.host(0))
        let cancelled = try scheduler.cancel(batches[1].id)
        #expect(cancelled == batches[1] && scheduler.pending == [batches[0]] && scheduler.pendingMessageCount == 1)
        #expect(Fixture.refusal(scheduler) { try $0.cancel(batches[1].id) } == .batchNotPending(batches[1].id))
        #expect(batches[1].id.description == "batch-1")
    }

    @Test func cancellingDispatchedOrForeignBatchesIsRefused() throws {
        var scheduler = try Fixture.scheduler()
        let dispatched = try #require(try scheduler.admit(Fixture.message(), now: Fixture.host(0)).first)
        #expect(try scheduler.due(now: Fixture.host(0)).dispatch == [dispatched])
        #expect(Fixture.refusal(scheduler) { try $0.cancel(dispatched.id) } == .batchNotPending(dispatched.id))
        var other = try Fixture.scheduler()
        for value in Int32(0)..<3 {
            _ = try other.admit(Fixture.message(value), now: Fixture.host(0))
        }
        let unknown = try #require(other.pending.last).id
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 1), 0), now: Fixture.host(0))
        #expect(unknown.value == 2 && scheduler.pending.map(\.id.value) == [1])
        #expect(Fixture.refusal(scheduler) { try $0.cancel(unknown) } == .batchNotPending(unknown))
    }

    @Test func dueReturnsOpenWindowsOnceInOrder() throws {
        var scheduler = try Fixture.scheduler()
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 2), 2), now: Fixture.host(0))
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 1), 1), now: Fixture.host(0))
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 3), 3), now: Fixture.host(0))
        #expect(try scheduler.due(now: Fixture.host(Fixture.second - 1)).dispatch.isEmpty)
        let due = try scheduler.due(now: Fixture.host(2 * Fixture.second))
        #expect(due.dispatch.map { Fixture.values($0.messages) } == [[1], [2]] && due.refused.isEmpty)
        #expect(due.dispatch.map(\.timing) == [.late(by: UInt64(Fixture.second - 1)), .onTime])
        #expect(Fixture.values(scheduler.pending.flatMap(\.messages)) == [3] && scheduler.pendingMessageCount == 1)
        #expect(try scheduler.due(now: Fixture.host(2 * Fixture.second)).dispatch.isEmpty)
        #expect(scheduler.latestNow == Fixture.host(2 * Fixture.second))
    }

    @Test func dueRefusesBatchesPastTheLateHorizon() throws {
        var scheduler = try Fixture.scheduler(policy: Fixture.policy(late: 100))
        let tag = Fixture.tag(after: 0)
        _ = try scheduler.admit(Fixture.timed(tag, 1), now: Fixture.host(0))
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 0, fraction: 100), 2), now: Fixture.host(0))
        let due = try scheduler.due(now: Fixture.host(102))
        #expect(due.refused.map(\.refusal) == [.tooLate(tag)])
        #expect(due.refused.map { Fixture.values($0.batch.messages) } == [[1]])
        #expect(due.dispatch.map { Fixture.values($0.messages) } == [[2]])
        #expect(due.dispatch.map(\.timing) == [.late(by: 78)])
        #expect(scheduler.pending.isEmpty && scheduler.pendingMessageCount == 0)
    }

    @Test func immediateBatchesAreDueAtOnceAndGoStale() throws {
        var scheduler = try Fixture.scheduler(policy: Fixture.policy(late: 100))
        _ = try scheduler.admit(Fixture.message(1), now: Fixture.host(0))
        let due = try scheduler.due(now: Fixture.host(100))
        #expect(due.dispatch.map(\.timing) == [.late(by: 100)])
        _ = try scheduler.admit(Fixture.message(2), now: Fixture.host(100))
        let stale = try scheduler.due(now: Fixture.host(201))
        #expect(stale.refused.map(\.refusal) == [.tooLate(.immediate)] && stale.dispatch.isEmpty)
    }

    @Test func refusedPacketsConsumeNoIdentifiers() throws {
        var scheduler = try Fixture.scheduler()
        let bad = Fixture.bundle(Fixture.tag(after: 1), [try Fixture.message(1), try Fixture.message(2, "/nope")])
        #expect(Fixture.refusal(scheduler) { try $0.admit(bad, now: Fixture.host(0)) } == .disallowedAddress("/nope"))
        let batch = try #require(try scheduler.admit(Fixture.message(), now: Fixture.host(0)).first)
        #expect(batch.id.value == 0 && batch.arrival == 0)
    }

    /// A seeded sweep of mixed operations: every refusal leaves the scheduler
    /// unchanged, counters always match, pending stays sorted and bounded, and
    /// each admitted batch leaves exactly once.
    @Test func randomOperationsKeepInvariants() throws {
        var generator = OSCSchedulingBatchGenerator(seed: 0x90_B47C)
        var scheduler = try Fixture.scheduler(policy: Fixture.policy(batches: 12, messages: 20))
        var now: Int64 = 0
        var admitted: Set<UInt64> = []
        var left: [UInt64] = []
        var refusals = 0
        for _ in 0..<1_500 {
            let before = scheduler
            now += Int64(generator.next(below: 400_000_000))
            do {
                switch generator.next(below: 4) {
                case 0, 1:
                    let seconds = now / Fixture.second + Int64(generator.next(below: 8)) - 2
                    let tag = Fixture.tag(after: seconds, fraction: UInt32(generator.next(below: 1 << 32)))
                    let values = (0..<generator.next(below: 4)).map { Int32($0) }
                    let packet = Fixture.bundle(tag, [try Fixture.message(9)] + [try Fixture.timed(tag, values)])
                    admitted.formUnion(try scheduler.admit(packet, now: Fixture.host(now)).map(\.id.value))
                case 2:
                    let due = try scheduler.due(now: Fixture.host(now))
                    left += due.dispatch.map(\.id.value) + due.refused.map(\.batch.id.value)
                default:
                    if let batch = scheduler.pending.randomElementOrNil(&generator) {
                        left.append(try scheduler.cancel(batch.id).id.value)
                    }
                }
            } catch {
                refusals += 1
                #expect(scheduler == before)
            }
            #expect(scheduler.pendingMessageCount == scheduler.pending.reduce(0) { $0 + $1.messages.count })
            #expect(scheduler.pending.count <= 12 && scheduler.pendingMessageCount <= 20)
            let keys = try scheduler.pending.map {
                ($0.window.earliest.ticks, try #require($0.wall), $0.arrival, $0.bundleIndex)
            }
            #expect(zip(keys, keys.dropFirst()).allSatisfy { $0.0 < $0.1 })
        }
        let pending = Set(scheduler.pending.map(\.id.value))
        #expect(Set(left).count == left.count && Set(left).isDisjoint(with: pending))
        #expect(Set(left).union(pending) == admitted)
        #expect(refusals > 50 && admitted.count > 300 && left.count > 300)
    }
}

/// SplitMix64 for the batch sweep.
private struct OSCSchedulingBatchGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(below bound: UInt64) -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return (value ^ (value >> 31)) % bound
    }
}

private extension Array {
    func randomElementOrNil(_ generator: inout OSCSchedulingBatchGenerator) -> Element? {
        isEmpty ? nil : self[Int(generator.next(below: UInt64(count)))]
    }
}

private extension OSCSchedulingFixture {
    static func timed(_ timeTag: OSC.TimeTag, _ values: [Int32]) throws -> OSC.Packet {
        bundle(timeTag, try values.map { try message($0) })
    }
}
