import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Root = RealtimeHandoffTests
private typealias FanInError = FanInHandoff<UInt64>.PreparationError
private typealias FanOutError = FanOutHandoff<UInt64>.PreparationError

/// Why `FanInHandoff.init` refuses, or `nil` when it accepts.
private func fanInRefusal(_ policy: HandoffPolicy, laneCapacity: Int = 20, reserved: Int = 16,
                          _ faults: FaultLatch) -> FanInError? {
    do {
        _ = try FanInHandoff<UInt64>(policy: policy, laneCapacity: laneCapacity, reserved: reserved, faults: faults,
                                     criticalScope: Root.fanInCriticalScope, producerSlotsScope: Root.fanInSlotsScope)
        return nil
    } catch {
        return error
    }
}

/// Why `FanOutHandoff.init` refuses, or `nil` when it accepts.
private func fanOutRefusal(_ policies: [HandoffPolicy]) -> FanOutError? {
    do {
        _ = try FanOutHandoff<UInt64>(policies: policies)
        return nil
    } catch {
        return error
    }
}

private func popAll(_ ring: SPSCRing<UInt64>?) -> [UInt64] {
    var values: [UInt64] = []
    while let value = ring?.tryPop() { values.append(value) }
    return values
}

/// Shared by `+FanInOut`, `+Starvation` and `+FanInStress`.
extension RealtimeHandoffTests {
    /// Lane critical exhaustion (`criticalExhausted`).
    static let fanInCriticalScope = FaultScope(handoff: 5, target: 1)
    /// Claim exhaustion (`producerSlotsExhausted`).
    static let fanInSlotsScope = FaultScope(handoff: 5, target: 3)
    /// Prepared but never raised by a fan-in.
    static let fanInNeighbourScope = FaultScope(handoff: 5, target: 2)

    /// One element delivered by `FanInHandoff.drain`, tagged with its lane.
    struct FanInDelivery: Hashable {
        let lane: UInt8
        let value: UInt64
    }

    /// A valid MIDI-receive fan-in policy for `lanes` producers: the whole handoff holds `lanes × laneCapacity`
    /// slots, `lanes × reserved` of them critical.
    static func fanInPolicy(lanes: Int = 4, laneCapacity: Int = 20, reserved: Int = 16,
                            ordering: HandoffOrdering = .fifoPerProducer) -> HandoffPolicy {
        policy(producer: .midiReceive,
               producers: ProducerCardinality(maximum: lanes, evidence: lanes == 1 ? .verified : .assumedConservative),
               capacity: laneCapacity &* lanes, ordering: ordering,
               overflow: .reservedCritical(reserved: reserved &* lanes))
    }

    static func fanInLatch() throws -> FaultLatch {
        try FaultLatch(scopes: [fanInCriticalScope, fanInSlotsScope, fanInNeighbourScope])
    }

    static func makeFanIn(_ faults: FaultLatch, lanes: Int = 4, laneCapacity: Int = 20,
                          reserved: Int = 16) throws -> FanInHandoff<UInt64> {
        try FanInHandoff<UInt64>(policy: fanInPolicy(lanes: lanes, laneCapacity: laneCapacity, reserved: reserved),
                                 laneCapacity: laneCapacity, reserved: reserved, faults: faults,
                                 criticalScope: fanInCriticalScope, producerSlotsScope: fanInSlotsScope)
    }

    /// One drain's deliveries, in delivery order.
    static func drained(_ handoff: FanInHandoff<UInt64>, quota: Int, total: Int) -> [FanInDelivery] {
        var deliveries: [FanInDelivery] = []
        let count = handoff.drain(perLaneQuota: quota, total: total) {
            deliveries.append(FanInDelivery(lane: $0, value: $1))
        }
        #expect(count == deliveries.count)
        return deliveries
    }

    /// The latched record for `scope`, if any.
    static func fanInRecord(_ faults: FaultLatch, _ scope: FaultScope) -> FaultRecord? {
        var found: FaultRecord?
        _ = faults.pending { if $0.scope == scope { found = $0 } }
        return found
    }
}

extension RealtimeHandoffTests {
    struct FanInClaims {
        @Test func initValidatesPolicyAndLaneShape() throws {
            let faults = try Root.fanInLatch()
            #expect(fanInRefusal(Root.fanInPolicy(), faults) == nil)
            let shared = Root.policy(producer: .midiReceive, producers: .conservativeDefault(for: .midiReceive),
                                     consumers: 2, capacity: 1_280, ordering: .fifoPerProducer,
                                     overflow: .reservedCritical(reserved: 1_024))
            #expect(fanInRefusal(shared, faults) == .policy(.violates(.r1SingleConsumer)))
            #expect(fanInRefusal(Root.fanInPolicy(ordering: .fifo), faults) == .unsupportedPolicy(.ordering(.fifo)))
            #expect(fanInRefusal(Root.sysexPolicy(), faults) == .unsupportedPolicy(.ordering(.completeMessagesFIFO)))
            #expect(fanInRefusal(Root.telemetryPolicy(), faults) == .unsupportedPolicy(.ordering(.latestOnly)))
            let refusing = Root.policy(producer: .midiReceive, producers: .conservativeDefault(for: .midiReceive),
                                       ordering: .fifoPerProducer)
            #expect(fanInRefusal(refusing, faults) == .unsupportedPolicy(.overflow(.refuseProducer)))
            // `(1 << 62) + 20` times 4 lanes wraps to exactly 80: the shape check must see the overflow.
            for laneCapacity in Root.adversarialInts + [19, 21, (1 << 62) + 20] {
                #expect(fanInRefusal(Root.fanInPolicy(), laneCapacity: laneCapacity, faults)
                        == .laneShapeMismatch(laneCapacity: laneCapacity, reserved: 16))
            }
            for reserved in Root.adversarialInts + [15, 17, (1 << 62) + 16] {
                #expect(fanInRefusal(Root.fanInPolicy(), reserved: reserved, faults)
                        == .laneShapeMismatch(laneCapacity: 20, reserved: reserved))
            }
            #expect(fanInRefusal(Root.fanInPolicy(laneCapacity: 20, reserved: 8), reserved: 8, faults)
                    == .lane(.reserveBelowMinimum(8)))
            let appOwnedMIDI = Root.policy(producer: .midiReceive, capacity: 20, ordering: .fifoPerProducer,
                                           overflow: .reservedCritical(reserved: 16))
            #expect(fanInRefusal(appOwnedMIDI, faults) == .policy(.violates(.r2Cardinality)))
            #expect(fanInRefusal(Root.fanInPolicy(lanes: 64, laneCapacity: 1_025), laneCapacity: 1_025, faults)
                    == .policy(.violates(.r3Capacity)))

            let single = try Root.makeFanIn(faults, lanes: 1, laneCapacity: 17)
            #expect(single.laneCount == 1 && single.laneCapacity == 17 && single.reserved == 16)
            let widest = try Root.makeFanIn(faults, lanes: 64, laneCapacity: 1_024)
            #expect(widest.laneCount == 64 && widest.policy == Root.fanInPolicy(lanes: 64, laneCapacity: 1_024))
            let control = Root.policy(capacity: 20, ordering: .fifoPerProducer,
                                      overflow: .reservedCritical(reserved: 16))
            #expect(fanInRefusal(control, faults) == nil)
            #expect(!faults.isLatched(Root.fanInCriticalScope) && !faults.isLatched(Root.fanInSlotsScope))
        }

        @Test func claimProducerIsExclusiveAndBounded() throws {
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults)
            let tokens = (0..<4).compactMap { _ in handoff.claimProducer(frame: 5) }
            #expect(tokens.map(\.lane) == [0, 1, 2, 3])
            #expect(tokens.allSatisfy { $0.handoff == handoff.identity && $0.generation == 1 })
            #expect(handoff.refusedClaimCount == 0 && !faults.isLatched(Root.fanInSlotsScope))

            #expect(handoff.claimProducer(frame: 77) == nil)
            #expect(handoff.refusedClaimCount == 1)
            let slots = FaultRecord(scope: Root.fanInSlotsScope, kind: .producerSlotsExhausted, count: 1,
                                    firstFrame: 77)
            #expect(Root.fanInRecord(faults, Root.fanInSlotsScope) == slots)
            #expect(handoff.claimProducer() == nil)
            #expect(handoff.refusedClaimCount == 2 && Root.fanInRecord(faults, Root.fanInSlotsScope)?.count == 2)
            #expect(Root.fanInRecord(faults, Root.fanInSlotsScope)?.firstFrame == 77)
            #expect(!faults.isLatched(Root.fanInCriticalScope) && !faults.isLatched(Root.fanInNeighbourScope))

            // Each token pushes into its own lane only.
            for (index, token) in tokens.enumerated() {
                #expect(handoff.tryPush(UInt64(index) * 10, class: .general, frame: 0, token: token) == .ok)
            }
            let deliveries = Root.drained(handoff, quota: 4, total: 16)
            #expect(deliveries == tokens.enumerated().map { Root.FanInDelivery(lane: $1.lane, value: UInt64($0) * 10) })
            #expect(handoff.refusedNotOwnerCount == 0)
        }

        @Test func releasedLaneIsReclaimableOnlyAfterDrain() throws {
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 2)
            let first = try #require(handoff.claimProducer())
            let other = try #require(handoff.claimProducer())
            for value: UInt64 in 1...3 {
                #expect(handoff.tryPush(value, class: .general, frame: 0, token: first) == .ok)
            }
            #expect(handoff.releaseProducer(first) == .ok)
            #expect(handoff.claimProducer() == nil)
            // A partial drain leaves the retiring lane non-empty, so it is still not reclaimable.
            #expect(Root.drained(handoff, quota: 2, total: 2) == [.init(lane: 0, value: 1), .init(lane: 0, value: 2)])
            #expect(handoff.claimProducer() == nil)
            #expect(Root.drained(handoff, quota: 8, total: 64) == [.init(lane: 0, value: 3)])
            let second = try #require(handoff.claimProducer())
            #expect(second.lane == 0 && second.generation == first.generation + 1 && second != first)
            #expect(handoff.refusedClaimCount == 2)

            // The released token no longer owns anything; the new owner's pushes follow the old ones.
            #expect(handoff.tryPush(99, class: .general, frame: 0, token: first) == .refused(.notOwner))
            #expect(handoff.tryPush(99, class: .critical, frame: 0, token: first) == .refused(.notOwner))
            #expect(handoff.releaseProducer(first) == .refused(.notOwner))
            #expect(handoff.tryPush(4, class: .general, frame: 0, token: second) == .ok)
            #expect(handoff.refusedNotOwnerCount == 3)
            #expect(handoff.releaseProducer(second) == .ok && handoff.releaseProducer(second) == .refused(.notOwner))
            #expect(handoff.releaseProducer(other) == .ok && handoff.refusedNotOwnerCount == 4)
            #expect(Root.drained(handoff, quota: 8, total: 64) == [.init(lane: 0, value: 4)])
            // An empty retiring lane is freed by the next drain that visits it.
            #expect(handoff.claimProducer()?.lane == 0 && handoff.claimProducer()?.lane == 1)
            #expect(handoff.claimProducer() == nil && handoff.refusedClaimCount == 3)
        }

        /// The drain reads a lane's state before popping it: a producer that pushes and releases while the
        /// drain is in that lane (here re-entrantly, from `body`) leaves the lane retiring and non-empty, so it
        /// must not be freed until a later drain empties it.
        @Test func releaseDuringDrainKeepsLaneUntilEmptied() throws {
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 1, laneCapacity: 17)
            let token = try #require(handoff.claimProducer())
            #expect(handoff.tryPush(1, class: .general, frame: 0, token: token) == .ok)
            var statuses: [KernelStatus] = []
            let count = handoff.drain(perLaneQuota: 4, total: 4) { _, _ in
                statuses.append(handoff.tryPush(2, class: .critical, frame: 0, token: token))
                statuses.append(handoff.releaseProducer(token))
            }
            #expect(count == 1 && statuses == [.ok, .ok])
            #expect(handoff.claimProducer() == nil && handoff.refusedClaimCount == 1)
            #expect(Root.drained(handoff, quota: 4, total: 4) == [.init(lane: 0, value: 2)])
            #expect(handoff.claimProducer()?.lane == 0)
        }

        @Test func foreignTokenIsRefusedNotOwner() throws {
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 2)
            let elsewhere = try Root.makeFanIn(faults, lanes: 2)
            let owner = try #require(handoff.claimProducer())
            let foreign = try #require(elsewhere.claimProducer())
            #expect(owner.lane == 0 && foreign.lane == 0 && owner.generation == foreign.generation)
            #expect(owner.handoff == handoff.identity && foreign.handoff == elsewhere.identity)
            #expect(owner.handoff != foreign.handoff)
            let (id, generation) = (owner.handoff, owner.generation)
            let forged = [
                foreign,
                ProducerToken(handoff: id, generation: generation &+ 1, lane: 0),
                // Phase bits in the generation must not alias the lane's claimed state word.
                ProducerToken(handoff: id, generation: generation | 1 << 62, lane: 0),
                ProducerToken(handoff: id, generation: generation | 3 << 62, lane: 0),
                ProducerToken(handoff: 0, generation: generation, lane: 0),
                ProducerToken(handoff: id, generation: generation, lane: 1),
                ProducerToken(handoff: id, generation: generation, lane: 2),
                ProducerToken(handoff: id, generation: generation, lane: .max)
            ]
            for (index, token) in forged.enumerated() {
                for eventClass in EventClass.allCases {
                    #expect(handoff.tryPush(UInt64(100 + index), class: eventClass, frame: 0, token: token)
                            == .refused(.notOwner))
                }
                #expect(handoff.releaseProducer(token) == .refused(.notOwner))
            }
            #expect(handoff.refusedNotOwnerCount == UInt64(forged.count * 3))
            #expect(elsewhere.refusedNotOwnerCount == 0 && handoff.refusedClaimCount == 0)
            #expect(handoff.tryPush(7, class: .general, frame: 0, token: owner) == .ok)
            #expect(Root.drained(handoff, quota: 8, total: 64) == [.init(lane: 0, value: 7)])
            #expect(Root.drained(elsewhere, quota: 8, total: 64).isEmpty)
            // The forged releases freed nothing: lane 1 is the only free lane.
            #expect(handoff.claimProducer()?.lane == 1 && handoff.claimProducer() == nil)
            #expect(!faults.isLatched(Root.fanInNeighbourScope))
        }

        /// The counter type behind both refusal counts, checked directly near its cap (no live handoff is seeded),
        /// then the handoff's two counts on their own.
        @Test func refusalCountersSaturate() throws {
            let cap = FanInRefusalCounter.cap
            #expect(cap == UInt64.max / 2)
            let fresh = FanInRefusalCounter()
            fresh.bump()
            fresh.bump()
            #expect(fresh.count == 2)
            let nearCap = FanInRefusalCounter(cap - 1)
            nearCap.bump()
            #expect(nearCap.count == cap)
            nearCap.bump()
            #expect(nearCap.count == cap)
            // Concurrent overshoot past the cap is clamped on read and never wraps.
            let overshot = FanInRefusalCounter(.max - 1)
            #expect(overshot.count == cap)
            for _ in 0..<3 { overshot.bump() }
            #expect(overshot.count == cap)

            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 1, laneCapacity: 17)
            let token = try #require(handoff.claimProducer())
            let stray = ProducerToken(handoff: handoff.identity, generation: 1, lane: 9)
            for round in UInt64(1)...2 {
                #expect(handoff.claimProducer() == nil)
                #expect(handoff.refusedClaimCount == round && handoff.refusedNotOwnerCount == round &- 1)
                #expect(handoff.tryPush(1, class: .general, frame: 0, token: stray) == .refused(.notOwner))
                #expect(handoff.refusedClaimCount == round && handoff.refusedNotOwnerCount == round)
            }
            #expect(handoff.releaseProducer(token) == .ok)
        }

        @Test func valuesAreBitwiseCopyable() {
            Root.requireBitwise(ProducerToken.self)
            Root.requireBitwise(FanOutResult.self)
            let token = ProducerToken(handoff: 2, generation: 9, lane: 3)
            #expect(token == ProducerToken(handoff: 2, generation: 9, lane: 3))
            #expect(token != ProducerToken(handoff: 2, generation: 8, lane: 3))
            #expect(token != ProducerToken(handoff: 1, generation: 9, lane: 3))
        }
    }

    struct FanInLanes {
        @Test func perLaneFIFOPreservedAcrossDrains() throws {
            let faults = try Root.fanInLatch()
            let policy = Root.fanInPolicy(lanes: 3, laneCapacity: 40)
            let handoff = try FanInHandoff<KernelEvent>(
                policy: policy, laneCapacity: 40, reserved: 16, faults: faults,
                criticalScope: Root.fanInCriticalScope, producerSlotsScope: Root.fanInSlotsScope)
            var pushed: [[KernelEvent]] = [[], [], []]
            for lane in 0..<3 {
                let token = try #require(handoff.claimProducer())
                // Repeated and alternating stateful values: a merging or coalescing lane would lose some.
                let payloads: [KernelEventPayload] = [
                    .control(channel: 0, controller: 7, value: 10), .control(channel: 0, controller: 7, value: 10),
                    .control(channel: 0, controller: 7, value: 11), .program(channel: 0, program: 3, bank: 1),
                    .noteOn(channel: 0, note: 60, velocity: 100), .noteOff(channel: 0, note: 60),
                    .noteOn(channel: 0, note: 60, velocity: 90), .noteOff(channel: 0, note: 60),
                    .control(channel: 0, controller: 7, value: 10), .program(channel: 0, program: 3, bank: 1),
                    .noteOff(channel: 0, note: 61), .clockPulse
                ]
                for (sequence, payload) in payloads.enumerated() {
                    let event = KernelEvent(frame: Int64(sequence / 4), scope: UInt32(lane), sequence: UInt64(sequence),
                                            payload: payload)
                    #expect(handoff.tryPush(event, class: event.eventClass, frame: event.frame, token: token) == .ok)
                    pushed[Int(token.lane)].append(event)
                }
            }
            var delivered: [[KernelEvent]] = [[], [], []]
            var laneOrder: [UInt8] = []
            for _ in 0..<40 {
                let count = handoff.drain(perLaneQuota: 2, total: 5) { lane, event in
                    delivered[Int(lane)].append(event)
                    laneOrder.append(lane)
                }
                #expect(count <= 5)
                if count == 0 { break }
            }
            #expect(delivered == pushed)
            // Drains interleave the lanes rather than emptying one lane first.
            #expect(Array(laneOrder.prefix(5)) == [0, 0, 1, 1, 2])
            #expect(laneOrder.count == 36)
        }

        @Test func floodingProducerCannotTakeAnotherLanesCapacity() throws {
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 3)
            let flooder = try #require(handoff.claimProducer())
            let victim = try #require(handoff.claimProducer())
            var floodStatuses: [KernelStatus] = []
            for value: UInt64 in 0..<100 {
                floodStatuses.append(handoff.tryPush(value, class: .general, frame: 0, token: flooder))
            }
            for value: UInt64 in 100..<130 {
                floodStatuses.append(handoff.tryPush(value, class: .critical, frame: 9, token: flooder))
            }
            #expect(floodStatuses.prefix(4).allSatisfy { $0 == .ok })
            #expect(floodStatuses[4..<100].allSatisfy { $0 == .refused(.full) })
            #expect(floodStatuses[100..<116].allSatisfy { $0 == .ok })
            #expect(floodStatuses[116...].allSatisfy { $0 == .refused(.criticalExhausted) })
            #expect(Root.fanInRecord(faults, Root.fanInCriticalScope)
                    == FaultRecord(scope: Root.fanInCriticalScope, kind: .criticalExhausted, count: 14, firstFrame: 9))
            #expect(!faults.isLatched(Root.fanInSlotsScope))

            // The victim's lane still has its whole general room and reserve.
            for value: UInt64 in 200..<204 {
                #expect(handoff.tryPush(value, class: .general, frame: 0, token: victim) == .ok)
            }
            #expect(handoff.tryPush(204, class: .general, frame: 0, token: victim) == .refused(.full))
            for value: UInt64 in 205..<221 {
                #expect(handoff.tryPush(value, class: .critical, frame: 0, token: victim) == .ok)
            }
            #expect(handoff.refusedCount(lane: 0, class: .general) == 96)
            #expect(handoff.refusedCount(lane: 0, class: .critical) == 14)
            #expect(handoff.refusedCount(lane: 1, class: .general) == 1)
            #expect(handoff.refusedCount(lane: 1, class: .critical) == 0)
            #expect(handoff.refusedCount(lane: 2, class: .general) == 0)
            for lane in Root.adversarialInts + [3, 64] where !(0..<3).contains(lane) {
                #expect(handoff.refusedCount(lane: lane, class: .general) == nil)
            }
            let deliveries = Root.drained(handoff, quota: 64, total: 128)
            let flooded = (0..<4).map { UInt64($0) } + (100..<116).map { UInt64($0) }
            let protected = (200..<204).map { UInt64($0) } + (205..<221).map { UInt64($0) }
            #expect(deliveries.filter { $0.lane == flooder.lane }.map(\.value) == flooded)
            #expect(deliveries.filter { $0.lane == victim.lane }.map(\.value) == protected)
            #expect(deliveries.count == 40)
        }
    }

    struct FanOutIsolation {
        @Test func fanOutInitValidatesPolicies() {
            #expect(fanOutRefusal([]) == .consumerCountOutOfRange(0))
            let widest = Array(repeating: Root.policy(capacity: 2), count: FanOutHandoff<UInt64>.maximumConsumers)
            #expect(FanOutHandoff<UInt64>.maximumConsumers == 64 && fanOutRefusal(widest) == nil)
            #expect(fanOutRefusal(widest + [Root.policy()]) == .consumerCountOutOfRange(65))
            #expect(fanOutRefusal([Root.policy(), Root.policy(consumers: 2)])
                    == .policy(consumer: 1, .violates(.r1SingleConsumer)))
            let reserved = Root.policy(overflow: .reservedCritical(reserved: 16))
            #expect(fanOutRefusal([Root.policy(), Root.policy(), reserved])
                    == .unsupportedPolicy(consumer: 2, .reservedCritical))
            #expect(fanOutRefusal([Root.telemetryPolicy()]) == .unsupportedPolicy(consumer: 0, .overwriteLatest))
            #expect(fanOutRefusal([Root.policy(), Root.sysexPolicy()])
                    == .policy(consumer: 1, .violates(.r2Cardinality)))
            let fromUI = Root.policy(producer: .ui, consumer: .control)
            #expect(fanOutRefusal([Root.policy(), fromUI]) == .mixedProducers(consumer: 1))
            #expect(fanOutRefusal([Root.policy(), Root.policy(consumer: .ui), Root.policy(consumer: .worker)]) == nil)
        }

        @Test func fanOutSlowConsumerIsolatedAndCounted() throws {
            let fanOut = try FanOutHandoff<UInt64>(policies: [Root.policy(capacity: 4), Root.policy(capacity: 2),
                                                              Root.policy(capacity: 4)])
            #expect(fanOut.consumerCount == 3)
            let results = (1...5).map { fanOut.publish(UInt64($0)) }
            #expect(results.map(\.accepted) == [0b111, 0b111, 0b101, 0b101, 0b000])
            #expect(results.map(\.refused) == [0b000, 0b000, 0b010, 0b010, 0b111])
            #expect(results.map(\.isComplete) == [true, true, false, false, false])
            #expect((0..<3).map { fanOut.refusedCount(consumer: $0) } == [1, 3, 1])
            #expect(popAll(fanOut.ring(1)) == [1, 2])
            // Once the slow consumer catches up it receives again; the full ones stay isolated and counted.
            #expect(fanOut.publish(6) == FanOutResult(accepted: 0b010, refused: 0b101))
            #expect(popAll(fanOut.ring(0)) == [1, 2, 3, 4] && popAll(fanOut.ring(1)) == [6])
            #expect(popAll(fanOut.ring(2)) == [1, 2, 3, 4])
            #expect(fanOut.publish(7) == FanOutResult(accepted: 0b111, refused: 0))
            #expect((0..<3).map { fanOut.refusedCount(consumer: $0) } == [2, 3, 2])
            for consumer in Root.adversarialInts + [3, 64] where !(0..<3).contains(consumer) {
                #expect(fanOut.ring(consumer) == nil && fanOut.refusedCount(consumer: consumer) == nil)
            }
        }

        @Test func fanOutUsesEveryConsumerBit() throws {
            let fanOut = try FanOutHandoff<UInt64>(policies: Array(repeating: Root.policy(capacity: 1), count: 64))
            #expect(fanOut.publish(1) == FanOutResult(accepted: .max, refused: 0))
            #expect(fanOut.ring(63)?.tryPop() == 1 && fanOut.ring(0)?.tryPop() == 1)
            #expect(fanOut.publish(2) == FanOutResult(accepted: 1 | 1 << 63, refused: .max ^ (1 | 1 << 63)))
            #expect(fanOut.refusedCount(consumer: 62) == 1 && fanOut.refusedCount(consumer: 63) == 0)
        }
    }
}
