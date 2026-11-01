import Testing
@testable import FluxKlang

private typealias Root = RealtimeHandoffTests
private typealias Delivery = RealtimeHandoffTests.FanInDelivery

/// A small deterministic generator so model runs are reproducible.
private struct SeededMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

/// Claims every lane of `handoff` and returns the tokens in lane order.
private func claimAll(_ handoff: FanInHandoff<UInt64>) throws -> [ProducerToken] {
    try (0..<handoff.laneCount).map { _ in try #require(handoff.claimProducer()) }
}

/// Every lane of one handoff claimed, with each lane's queued count and next value number.
private struct Backlog {
    let handoff: FanInHandoff<UInt64>
    let tokens: [ProducerToken]
    var queued: [Int]
    var next: [UInt64]

    init(_ handoff: FanInHandoff<UInt64>) throws {
        self.handoff = handoff
        tokens = try claimAll(handoff)
        queued = Array(repeating: 0, count: handoff.laneCount)
        next = Array(repeating: 0, count: handoff.laneCount)
    }

    /// Tops each listed lane up to `depth` queued values (general class), numbering values per lane.
    mutating func fill(lanes: [Int], depth: Int) {
        for lane in lanes {
            while queued[lane] < depth {
                #expect(handoff.tryPush(UInt64(lane) << 32 | next[lane], class: .general, frame: 0,
                                        token: tokens[lane]) == .ok)
                next[lane] += 1
                queued[lane] += 1
            }
        }
    }

    /// One drain's deliveries; decrements `queued` for each.
    mutating func drain(quota: Int, total: Int) -> [Delivery] {
        let deliveries = Root.drained(handoff, quota: quota, total: total)
        for delivery in deliveries { queued[Int(delivery.lane)] -= 1 }
        return deliveries
    }
}

/// The lane that delivered first in each of `drains` drains.
private func firstLanes(_ handoff: FanInHandoff<UInt64>, drains: Int, quota: Int, total: Int) -> [UInt8?] {
    (0..<drains).map { _ in Root.drained(handoff, quota: quota, total: total).first?.lane }
}

/// Reference model of one `FanInHandoff<UInt64>` and its two fault scopes: lane admission (M4), the claim state
/// machine with per-lane generations, and the documented round-robin cursor rule.
private struct FanInModel {
    enum Phase: Equatable { case free, claimed, retiring }

    let laneCount: Int
    let generalLimit: Int
    let capacity: Int
    var queues: [[UInt64]]
    var phases: [Phase]
    /// The last claim generation issued on each lane.
    var generations: [UInt64]
    var cursor = 0
    var refusedNotOwner: UInt64 = 0
    var refusedClaims: UInt64 = 0
    var refusedGeneral: [UInt64]
    var refusedCritical: [UInt64]
    var criticalFault: FaultRecord?
    var slotsFault: FaultRecord?

    init(laneCount: Int, laneCapacity: Int, reserved: Int) {
        self.laneCount = laneCount
        generalLimit = laneCapacity - reserved
        capacity = laneCapacity
        queues = Array(repeating: [], count: laneCount)
        phases = Array(repeating: .free, count: laneCount)
        generations = Array(repeating: 0, count: laneCount)
        refusedGeneral = Array(repeating: 0, count: laneCount)
        refusedCritical = Array(repeating: 0, count: laneCount)
    }

    /// `FaultLatch` on one scope: the first kind and frame stick and the count grows.
    private static func raised(_ record: FaultRecord?, _ scope: FaultScope, _ kind: FaultKind,
                               frame: Int64) -> FaultRecord {
        FaultRecord(scope: scope, kind: record?.kind ?? kind, count: (record?.count ?? 0) + 1,
                    firstFrame: record?.firstFrame ?? frame)
    }

    /// The lowest free lane, or `nil` after counting and raising `producerSlotsExhausted`.
    mutating func claim(frame: Int64) -> Int? {
        guard let lane = phases.firstIndex(of: .free) else {
            refusedClaims += 1
            slotsFault = Self.raised(slotsFault, Root.fanInSlotsScope, .producerSlotsExhausted, frame: frame)
            return nil
        }
        phases[lane] = .claimed
        generations[lane] += 1
        return lane
    }

    mutating func refuseNotOwner() -> KernelStatus {
        refusedNotOwner += 1
        return .refused(.notOwner)
    }

    mutating func push(_ value: UInt64, critical: Bool, lane: Int, frame: Int64) -> KernelStatus {
        if !critical, queues[lane].count >= generalLimit {
            refusedGeneral[lane] += 1
            return .refused(.full)
        }
        if critical, queues[lane].count >= capacity {
            refusedCritical[lane] += 1
            criticalFault = Self.raised(criticalFault, Root.fanInCriticalScope, .criticalExhausted, frame: frame)
            return .refused(.criticalExhausted)
        }
        queues[lane].append(value)
        return .ok
    }

    mutating func drain(quota: Int, total: Int) -> [Delivery] {
        guard quota > 0, total > 0 else { return [] }
        var deliveries: [Delivery] = []
        var lane = cursor
        var last = cursor
        var remaining = total
        var visited = 0
        var lastLimit = 0
        while visited < laneCount, remaining > 0 {
            let limit = min(quota, remaining)
            let taken = min(limit, queues[lane].count)
            deliveries += queues[lane].prefix(taken).map { Delivery(lane: UInt8(lane), value: $0) }
            queues[lane].removeFirst(taken)
            if taken < limit, phases[lane] == .retiring { phases[lane] = .free }
            remaining -= taken
            lastLimit = limit
            last = lane
            visited += 1
            lane = (lane + 1) % laneCount
        }
        var next = lane
        if remaining == 0, lastLimit < quota { next = last }
        if next == cursor { next = (cursor + 1) % laneCount }
        cursor = next
        return deliveries
    }
}

/// One seeded `seededTrafficMatchesModel` run: each step acts on the handoff and the model and compares results.
private struct ModelRun {
    let handoff: FanInHandoff<UInt64>
    /// Live claims on another handoff (lane 0...2), never valid here.
    let foreign: [ProducerToken]
    var random: SeededMix
    var model: FanInModel
    var live: [ProducerToken?]
    var stale: [ProducerToken] = []

    init(handoff: FanInHandoff<UInt64>, foreign: [ProducerToken], random: SeededMix) {
        self.handoff = handoff
        self.foreign = foreign
        self.random = random
        model = FanInModel(laneCount: handoff.laneCount, laneCapacity: handoff.laneCapacity,
                           reserved: handoff.reserved)
        live = Array(repeating: nil, count: handoff.laneCount)
    }

    private var liveTokens: [ProducerToken] { live.compactMap { $0 } }

    mutating func claim(frame: Int64) {
        let token = handoff.claimProducer(frame: frame)
        let lane = model.claim(frame: frame)
        #expect(token.map { Int($0.lane) } == lane)
        if let token, let lane {
            #expect(token.handoff == handoff.identity && token.generation == model.generations[lane])
            live[lane] = token
        }
    }

    /// Releases a random live token, or re-releases the newest stale one.
    mutating func release() {
        let liveTokens = liveTokens
        if let token = liveTokens.isEmpty ? nil : liveTokens[random.below(liveTokens.count)] {
            #expect(handoff.releaseProducer(token) == .ok)
            model.phases[Int(token.lane)] = .retiring
            live[Int(token.lane)] = nil
            stale.append(token)
        } else if let token = stale.last {
            #expect(handoff.releaseProducer(token) == model.refuseNotOwner())
        }
    }

    /// Pushes through a random live token (7 in 10), or a stale, foreign or forged one.
    mutating func push(_ value: UInt64, frame: Int64) {
        let liveTokens = liveTokens
        let critical = random.below(4) == 0
        let eventClass: EventClass = critical ? .critical : .general
        let kind = random.below(10)
        if kind < 7, !liveTokens.isEmpty {
            let token = liveTokens[random.below(liveTokens.count)]
            #expect(handoff.tryPush(value, class: eventClass, frame: frame, token: token)
                    == model.push(value, critical: critical, lane: Int(token.lane), frame: frame))
            return
        }
        // Phase bits in the generation, or handoff identity 0 (never issued): no forgery can match.
        let anchor = stale.last?.generation ?? liveTokens.first?.generation ?? 1
        let lane = UInt8(random.below(model.laneCount + 2))
        let forged = random.below(2) == 0
            ? ProducerToken(handoff: handoff.identity, generation: anchor | 1 << 62, lane: lane)
            : ProducerToken(handoff: 0, generation: anchor, lane: lane)
        let token: ProducerToken
        switch kind {
        case 7: token = stale.last ?? forged
        case 8: token = foreign[random.below(foreign.count)]
        default: token = forged
        }
        #expect(handoff.tryPush(value, class: eventClass, frame: frame, token: token) == model.refuseNotOwner())
    }

    /// One drain with a random quota and total in -1...5 and -1...12.
    mutating func drain() {
        let quota = random.below(7) - 1
        let total = random.below(14) - 1
        #expect(Root.drained(handoff, quota: quota, total: total) == model.drain(quota: quota, total: total))
    }
}

extension RealtimeHandoffTests {
    struct LaneFairness {
        @Test func roundRobinVisitsEveryNonEmptyLaneWithinOneDrain() throws {
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 4, laneCapacity: 40)
            var backlog = try Backlog(handoff)
            backlog.fill(lanes: [0, 2, 3], depth: 10)
            // Ample budget: every non-empty lane gives exactly its quota, in lane order from the start lane.
            let first = backlog.drain(quota: 3, total: 12)
            #expect(first.map(\.lane) == [0, 0, 0, 2, 2, 2, 3, 3, 3])
            #expect(first.map { $0.value & 0xFFFF } == [0, 1, 2, 0, 1, 2, 0, 1, 2])
            // The next drain starts one lane later.
            #expect(backlog.drain(quota: 3, total: 12).map(\.lane)
                    == [2, 2, 2, 3, 3, 3, 0, 0, 0])
            // A tight budget stops mid-lane; the next drain resumes at the lane that was cut short.
            #expect(backlog.drain(quota: 3, total: 4).map(\.lane) == [2, 2, 2, 3])
            #expect(backlog.drain(quota: 3, total: 4).map(\.lane) == [3, 3, 3, 0])
            #expect(backlog.queued == [3, 0, 1, 0])
            // Exactly lanes × quota still reaches every non-empty lane.
            backlog.fill(lanes: [0, 2, 3], depth: 6)
            let exact = backlog.drain(quota: 2, total: 8)
            #expect(exact.map(\.lane) == [0, 0, 2, 2, 3, 3])
        }

        @Test func rotatingStartPreventsPositionalBias() throws {
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 4, laneCapacity: 40)
            var backlog = try Backlog(handoff)
            backlog.fill(lanes: [0, 1, 2, 3], depth: 8)
            // Ample budget: the start lane rotates 0, 1, 2, 3, 0.
            var starts: [UInt8?] = []
            for _ in 0..<5 {
                starts.append(backlog.drain(quota: 1, total: 4).first?.lane)
                backlog.fill(lanes: [0, 1, 2, 3], depth: 8)
            }
            #expect(starts == [0, 1, 2, 3, 0])

            // A budget that does not divide by the quota still shares evenly over many drains.
            var served = [0, 0, 0, 0]
            for _ in 0..<400 {
                for delivery in backlog.drain(quota: 2, total: 3) {
                    served[Int(delivery.lane)] += 1
                }
                backlog.fill(lanes: [0, 1, 2, 3], depth: 8)
            }
            #expect(served == [300, 300, 300, 300])

            // A budget below the quota still moves the start lane every drain.
            #expect(firstLanes(handoff, drains: 8, quota: 4, total: 2) == [1, 2, 3, 0, 1, 2, 3, 0])
        }

        @Test func emptyLanesDoNotBiasTheNextLane() throws {
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 4, laneCapacity: 40)
            var backlog = try Backlog(handoff)
            backlog.fill(lanes: [0, 1], depth: 20)
            // Lanes 2 and 3 stay empty; one event per drain alternates between lanes 0 and 1.
            let served = firstLanes(handoff, drains: 20, quota: 1, total: 1)
            #expect(served == Array(repeating: [0, 1] as [UInt8?], count: 10).flatMap { $0 })
        }

        @Test(arguments: [UInt64(1), 7, 0xDEAD_BEEF])
        func everyNonEmptyLaneIsServedWithinLaneCountDrains(seed: UInt64) throws {
            let lanes = 5
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: lanes, laneCapacity: 40)
            var backlog = try Backlog(handoff)
            var waited = Array(repeating: 0, count: lanes)
            var random = SeededMix(state: seed)
            for _ in 0..<2_000 {
                let busy = (0..<lanes).filter { _ in random.below(3) > 0 }
                backlog.fill(lanes: busy, depth: 1 + random.below(6))
                let nonEmpty = (0..<lanes).map { backlog.queued[$0] > 0 }
                let deliveries = Root.drained(handoff, quota: 1 + random.below(4), total: 1 + random.below(8))
                var servedLanes = Set<Int>()
                for delivery in deliveries {
                    servedLanes.insert(Int(delivery.lane))
                    backlog.queued[Int(delivery.lane)] -= 1
                }
                for lane in 0..<lanes {
                    waited[lane] = nonEmpty[lane] && !servedLanes.contains(lane) ? waited[lane] + 1 : 0
                    #expect(waited[lane] < lanes, "lane \(lane) waited \(waited[lane]) drains")
                }
            }
        }

        @Test func nonPositiveBudgetsAreNoOps() throws {
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 2, laneCapacity: 40)
            var backlog = try Backlog(handoff)
            backlog.fill(lanes: [0, 1], depth: 20)
            #expect(handoff.releaseProducer(backlog.tokens[1]) == .ok)
            // After every non-positive call, a one-event drain still alternates 0, 1, 0, …: the cursor never moved.
            var served: [UInt8?] = []
            for quota in Root.adversarialInts {
                for total in Root.adversarialInts where quota <= 0 || total <= 0 {
                    #expect(handoff.drain(perLaneQuota: quota, total: total) { _, _ in Issue.record("delivered") } == 0)
                    served.append(backlog.drain(quota: 1, total: 1).first?.lane)
                }
            }
            #expect(served == (0..<27).map { UInt8($0 % 2) })
            #expect(handoff.claimProducer() == nil)
            #expect(backlog.drain(quota: .max, total: .max).count == 40 - 27 && backlog.queued == [0, 0])
            #expect(handoff.claimProducer()?.lane == 1)

            // A non-positive drain does not free an empty retiring lane either; a real one does.
            let single = try Root.makeFanIn(faults, lanes: 1, laneCapacity: 17)
            let token = try #require(single.claimProducer())
            #expect(single.releaseProducer(token) == .ok)
            for budget in Root.adversarialInts where budget <= 0 {
                #expect(single.drain(perLaneQuota: budget, total: 1) { _, _ in } == 0)
                #expect(single.drain(perLaneQuota: 1, total: budget) { _, _ in } == 0)
            }
            #expect(single.claimProducer() == nil)
            #expect(Root.drained(single, quota: 1, total: 1).isEmpty && single.claimProducer()?.lane == 0)
        }

        @Test(arguments: [UInt64(1), 2, 3, 0x5EED, 0xFACE_FEED])
        func seededTrafficMatchesModel(seed: UInt64) throws {
            let lanes = 3
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: lanes, laneCapacity: 18)
            let elsewhere = try Root.makeFanIn(faults, lanes: lanes, laneCapacity: 18)
            var run = ModelRun(handoff: handoff, foreign: try claimAll(elsewhere), random: SeededMix(state: seed))
            for step in 0..<3_000 {
                switch run.random.below(20) {
                case 0..<3: run.claim(frame: Int64(step))
                case 3..<5: run.release()
                case 5..<13: run.push(UInt64(step), frame: Int64(step))
                default: run.drain()
                }
            }
            let model = run.model
            #expect(handoff.refusedNotOwnerCount == model.refusedNotOwner)
            #expect(handoff.refusedClaimCount == model.refusedClaims)
            for lane in 0..<lanes {
                #expect(handoff.refusedCount(lane: lane, class: .general) == model.refusedGeneral[lane])
                #expect(handoff.refusedCount(lane: lane, class: .critical) == model.refusedCritical[lane])
            }
            #expect(Root.fanInRecord(faults, Root.fanInCriticalScope) == model.criticalFault)
            #expect(Root.fanInRecord(faults, Root.fanInSlotsScope) == model.slotsFault)
            #expect(model.refusedClaims > 0 && model.refusedNotOwner > 0 && model.refusedGeneral.reduce(0, +) > 0)
            #expect(Root.drained(handoff, quota: 64, total: 256) == run.model.drain(quota: 64, total: 256))
        }
    }
}
