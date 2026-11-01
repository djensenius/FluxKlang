import Foundation
import Synchronization
import Testing
@testable import FluxKlang

private typealias Root = RealtimeHandoffTests

/// A 16-byte stamp whose `check` word exposes a torn or forged copy.
private struct FanStamp: BitwiseCopyable, Sendable, Equatable {
    let producer: UInt32
    let sequence: UInt32
    let check: UInt64

    init(producer: Int, sequence: Int) {
        self.producer = UInt32(truncatingIfNeeded: producer)
        self.sequence = UInt32(truncatingIfNeeded: sequence)
        check = Self.mix(self.producer, self.sequence)
    }

    var isConsistent: Bool { check == Self.mix(producer, sequence) }

    private static func mix(_ producer: UInt32, _ sequence: UInt32) -> UInt64 {
        (UInt64(producer) << 32 | UInt64(sequence)) &* 0x9E37_79B9_7F4A_7C15 ^ 0xA5A5_5A5A_0F0F_F0F0
    }
}

/// Start flag, cancel flag and joins for dedicated stress `Thread`s.
private final class StressRun: @unchecked Sendable {
    /// Every controller wait (arrival, each join) and every worker's start wait is bounded by this.
    static let waitLimit: Duration = .seconds(15)
    let arrived = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    let cancelled = Atomic<Bool>(false)
    /// A relaxed counter for a test's own worker handshake; relaxed so it adds no happens-before edges.
    let handshake = Atomic<Int>(0)
    /// Signalled once per finished worker. `@unchecked Sendable` covers this `DispatchSemaphore`.
    let joined = DispatchSemaphore(value: 0)

    var shouldStop: Bool { cancelled.load(ordering: .acquiring) }

    /// Worker side: counts this worker in, then waits (bounded) for the start flag. `false` means return now.
    func arriveAndWait() -> Bool {
        arrived.add(1, ordering: .acquiringAndReleasing)
        return spin { started.load(ordering: .acquiring) }
    }

    /// Worker side: spins until `condition` holds; `false` on cancel or after `waitLimit`.
    func spin(until condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + Self.waitLimit
        var spins = 0
        while !condition() {
            spins &+= 1
            if shouldStop || (spins & 1_023 == 0 && ContinuousClock.now >= deadline) { return false }
        }
        return !shouldStop
    }
}

/// Runs each worker on its own `Thread`. The start flag is released only after every worker has arrived (and
/// that is asserted at that point); then each worker is joined with a 15 s deadline. On any timeout this records
/// an `Issue`, sets the shared cancel flag and returns `false`, so callers `try #require` the result before
/// reading anything a worker wrote.
private func runWorkers(_ workers: [@Sendable (StressRun) -> Void]) -> Bool {
    let run = StressRun()
    for worker in workers {
        Thread {
            worker(run)
            run.joined.signal()
        }.start()
    }
    let arrival = ContinuousClock.now + StressRun.waitLimit
    while run.arrived.load(ordering: .acquiring) < workers.count, ContinuousClock.now < arrival {
        Thread.sleep(forTimeInterval: 0.001)
    }
    let arrived = run.arrived.load(ordering: .acquiring)
    #expect(arrived == workers.count, "start flag released only after every worker arrived")
    guard arrived == workers.count else {
        run.cancelled.store(true, ordering: .releasing)
        Issue.record("only \(arrived) of \(workers.count) stress workers arrived within 15 s; cancelled")
        return false
    }
    run.started.store(true, ordering: .releasing)
    for index in workers.indices where run.joined.wait(timeout: .now() + 15) == .timedOut {
        run.cancelled.store(true, ordering: .releasing)
        Issue.record("stress join \(index) timed out after 15 s; workers cancelled, post-run checks skipped")
        return false
    }
    return true
}

/// Per-worker result slots, written by each worker before it signals `joined`.
private final class Slots<Value: Sendable>: Sendable {
    private let values: Mutex<[Value?]>
    init(_ count: Int) { values = Mutex(Array(repeating: nil, count: count)) }
    func set(_ index: Int, _ value: Value) { values.withLock { $0[index] = value } }
    func get(_ index: Int) -> Value? { values.withLock { $0[index] } }
}

private struct ProducerReport: Sendable {
    var lane: UInt8?
    var refusedGeneral: UInt64 = 0
    var refusedCritical: UInt64 = 0
    var wrongStatus = 0
    var released: KernelStatus?
    var finished = false
}

private struct ConsumerReport: Sendable {
    var next: [UInt32]
    var lanes: [UInt8?]
    var torn = 0
    var outOfOrder = 0
    var laneMismatch = 0
    var count = 0
    var finished = false

    init(producers: Int) {
        next = Array(repeating: 0, count: producers)
        lanes = Array(repeating: nil, count: producers)
    }

    /// Exact per-producer FIFO: each producer's sequence must arrive as 0, 1, 2, … from one lane only.
    mutating func receive(_ lane: UInt8, _ stamp: FanStamp) {
        let producer = Int(stamp.producer)
        guard stamp.isConsistent, producer < next.count else {
            torn += 1
            return
        }
        if stamp.sequence != next[producer] { outOfOrder += 1 }
        next[producer] = stamp.sequence &+ 1
        if lanes[producer] == nil { lanes[producer] = lane }
        if lanes[producer] != lane { laneMismatch += 1 }
        count += 1
    }
}

private struct ChurnReport: Sendable {
    var blocks = 0
    var refusedClaims: UInt64 = 0
    var wrongStatus = 0
    /// Claims whose lane note did not end on a block's last step.
    var partialHandovers = 0
    var finished = false

    mutating func expectOK(_ status: KernelStatus) {
        if status != .ok { wrongStatus += 1 }
    }
}

/// The last block step (0...2) the consumer delivered on each lane. Plain memory on purpose: the consumer writes it
/// in `drain`'s body and the lane's next claimer reads it right after claiming, ordered only by the documented
/// chain (the consumer's work on a lane's old contents happens before the next claim returns). A missing release
/// or acquire on that chain makes the read a data race that TSan reports.
/// `@unchecked Sendable`: access is ordered by the claim protocol under test.
private final class LaneNotes: @unchecked Sendable {
    static let unused: UInt8 = .max
    private let steps: UnsafeMutablePointer<UInt8>
    private let count: Int

    init(_ count: Int) {
        self.count = count
        steps = .allocate(capacity: count)
        steps.initialize(repeating: Self.unused, count: count)
    }

    deinit { steps.deallocate() }

    func record(_ lane: UInt8, _ stamp: FanStamp) {
        if Int(lane) < count { steps[Int(lane)] = UInt8(truncatingIfNeeded: stamp.sequence & 3) }
    }

    /// Whether `lane` is unused or its last delivered step ended a block.
    func isWhole(_ lane: UInt8) -> Bool {
        Int(lane) < count && (steps[Int(lane)] == 2 || steps[Int(lane)] == Self.unused)
    }
}

/// Consumer-side check that every lane delivers whole three-event blocks, each block once.
private struct BlockReport: Sendable {
    /// The last stamp of the block in progress on each lane.
    private var open: [FanStamp?]
    private var seen: [[Bool]]
    var blocks: [Int]
    var torn = 0
    var interleaved = 0
    var duplicates = 0
    var finished = false

    init(lanes: Int, producers: Int, blocksEach: Int) {
        open = Array(repeating: nil, count: lanes)
        seen = Array(repeating: Array(repeating: false, count: blocksEach), count: producers)
        blocks = Array(repeating: 0, count: producers)
    }

    mutating func receive(_ lane: UInt8, _ stamp: FanStamp) {
        let (producer, block, step) = (Int(stamp.producer), Int(stamp.sequence >> 2), Int(stamp.sequence & 3))
        guard stamp.isConsistent, producer < blocks.count, block < seen[producer].count, step < 3,
              Int(lane) < open.count else {
            torn += 1
            return
        }
        if let last = open[Int(lane)] {
            if stamp.producer != last.producer || stamp.sequence != last.sequence &+ 1 { interleaved += 1 }
        } else if step != 0 {
            interleaved += 1
        }
        open[Int(lane)] = step == 2 ? nil : stamp
        guard step == 2 else { return }
        if seen[producer][block] {
            duplicates += 1
        } else {
            seen[producer][block] = true
            blocks[producer] += 1
        }
    }
}

/// Per-lane holder flags plus a finished-claimer count. The flags are relaxed on purpose: they count overlapping
/// holders without adding happens-before edges that would hide a missing acquire or release from TSan.
/// `@unchecked Sendable`: the flag storage is a fixed buffer of atomics, initialised in `init`.
private final class OwnerFlags: @unchecked Sendable {
    let overlaps = Atomic<Int>(0)
    let finished = Atomic<Int>(0)
    private let flags: UnsafeMutablePointer<Atomic<Int>>
    private let count: Int

    init(_ count: Int) {
        self.count = count
        flags = .allocate(capacity: count)
        for index in 0..<count { (flags + index).initialize(to: Atomic(0)) }
    }

    deinit {
        flags.deinitialize(count: count)
        flags.deallocate()
    }

    func enter(_ lane: Int, _ holder: Int) { exchange(lane, from: 0, to: holder &+ 1) }
    func leave(_ lane: Int, _ holder: Int) { exchange(lane, from: holder &+ 1, to: 0) }

    private func exchange(_ lane: Int, from: Int, to: Int) {
        guard lane >= 0, lane < count else {
            overlaps.add(1, ordering: .relaxed)
            return
        }
        if !(flags + lane).pointee.compareExchange(expected: from, desired: to, ordering: .relaxed).exchanged {
            overlaps.add(1, ordering: .relaxed)
        }
    }
}

private final class PublishedFlag: Sendable {
    let done = Atomic<Bool>(false)
}

/// Retries `value` until admitted, counting refusals; `false` if cancelled first. Every 16th sequence number is
/// critical; the frame is the sequence number.
private func push(_ handoff: FanInHandoff<FanStamp>, _ value: FanStamp, _ token: ProducerToken,
                  _ report: inout ProducerReport, _ run: StressRun) -> Bool {
    let eventClass: EventClass = value.sequence % 16 == 15 ? .critical : .general
    while true {
        let status = handoff.tryPush(value, class: eventClass, frame: Int64(value.sequence), token: token)
        switch (status, eventClass) {
        case (.ok, _): return true
        case (.refused(.full), .general): report.refusedGeneral += 1
        case (.refused(.criticalExhausted), .critical): report.refusedCritical += 1
        default: report.wrongStatus += 1
        }
        if run.shouldStop { return false }
    }
}

extension RealtimeHandoffTests {
    /// Dedicated `Thread`s (not a `TaskGroup`, whose runtime annotations would hide a missing acquire or release
    /// from TSan). Run under TSan with `--filter Stress`.
    struct FanInStress {
        /// After one start flag, producers claim lanes and wait until all four claims are held (a handshake, so
        /// the claims overlap and must be distinct), then push a mixed-class sequence (retrying refusals) and
        /// release while one consumer drains fairly. Every event arrives exactly once, untorn, in per-producer
        /// order, from its producer's lane.
        @Test(.timeLimit(.minutes(1)))
        func stressConcurrentProducersConserveMultiset() throws {
            let producers = 4
            let perProducer = 50_000
            let faults = try Root.fanInLatch()
            let handoff = try FanInHandoff<FanStamp>(
                policy: Root.fanInPolicy(lanes: producers, laneCapacity: 32), laneCapacity: 32, reserved: 16,
                faults: faults, criticalScope: Root.fanInCriticalScope, producerSlotsScope: Root.fanInSlotsScope)
            let produced = Slots<ProducerReport>(producers)
            let consumed = Slots<ConsumerReport>(1)
            var workers: [@Sendable (StressRun) -> Void] = (0..<producers).map { producer in
                { run in
                    var report = ProducerReport()
                    defer { produced.set(producer, report) }
                    guard run.arriveAndWait() else { return }
                    guard let token = handoff.claimProducer() else {
                        return run.cancelled.store(true, ordering: .releasing)
                    }
                    report.lane = token.lane
                    // Handshake: no producer pushes until all hold a claim, so the claims overlap and must differ.
                    run.handshake.add(1, ordering: .relaxed)
                    guard run.spin(until: { run.handshake.load(ordering: .relaxed) == producers }) else { return }
                    for sequence in 0..<perProducer {
                        let stamp = FanStamp(producer: producer, sequence: sequence)
                        guard push(handoff, stamp, token, &report, run) else { return }
                    }
                    report.released = handoff.releaseProducer(token)
                    report.finished = true
                }
            }
            workers.append { run in
                var report = ConsumerReport(producers: producers)
                defer { consumed.set(0, report) }
                guard run.arriveAndWait() else { return }
                while report.count < producers * perProducer, !run.shouldStop {
                    handoff.drain(perLaneQuota: 3, total: 8) { report.receive($0, $1) }
                }
                report.finished = report.count == producers * perProducer
            }
            try #require(runWorkers(workers))

            let reports = (0..<producers).compactMap { produced.get($0) }
            let consumer = try #require(consumed.get(0))
            #expect(reports.count == producers && reports.allSatisfy { $0.finished && $0.wrongStatus == 0 })
            #expect(reports.allSatisfy { $0.released == .ok })
            #expect(consumer.finished && consumer.torn == 0 && consumer.outOfOrder == 0 && consumer.laneMismatch == 0)
            #expect(consumer.next == Array(repeating: UInt32(perProducer), count: producers))
            #expect(Set(reports.compactMap(\.lane)).count == producers)
            #expect(consumer.lanes == reports.map(\.lane))
            for report in reports {
                let lane = Int(report.lane ?? .max)
                #expect(handoff.refusedCount(lane: lane, class: .general) == report.refusedGeneral)
                #expect(handoff.refusedCount(lane: lane, class: .critical) == report.refusedCritical)
            }
            #expect(handoff.refusedNotOwnerCount == 0 && handoff.refusedClaimCount == 0)
            let criticalRefusals = reports.reduce(0) { $0 + $1.refusedCritical }
            print("FanInStress general refusals \(reports.map(\.refusedGeneral)), critical \(criticalRefusals)")
            #expect(Root.fanInRecord(faults, Root.fanInCriticalScope)?.count ?? 0 == criticalRefusals)
            #expect(!faults.isLatched(Root.fanInSlotsScope))
            // The joins order every worker before this thread, which is now the only consumer: an empty drain
            // frees every retiring lane, and all lanes can be claimed again.
            #expect(handoff.drain(perLaneQuota: 1, total: producers) { _, _ in Issue.record("leftover") } == 0)
            #expect((0..<producers).compactMap { _ in handoff.claimProducer() }.count == producers)
        }

        /// Six claimers churn three lanes until each has pushed 400 three-event blocks, one block per claim,
        /// retrying refused claims. Relaxed owner flags count overlapping holders, and each lane's output must be
        /// whole blocks, so a lane never changes hands before its previous owner's events are drained. A claimed
        /// lane is always empty, so every push in a block is admitted, and a new claimer finds the consumer's
        /// plain lane note at its previous owner's last step. Under TSan, that note and the non-atomic producer
        /// state each lane hands over (M4 `pushed`, the M2 write cursor and slots) check the claim/release/drain
        /// happens-before chain in both directions.
        @Test(.timeLimit(.minutes(1)))
        func stressClaimChurnKeepsLanesExclusive() throws {
            let lanes = 3
            let claimers = 6
            let blocksEach = 400
            let faults = try Root.fanInLatch()
            let handoff = try FanInHandoff<FanStamp>(
                policy: Root.fanInPolicy(lanes: lanes, laneCapacity: 20), laneCapacity: 20, reserved: 16,
                faults: faults, criticalScope: Root.fanInCriticalScope, producerSlotsScope: Root.fanInSlotsScope)
            let flags = OwnerFlags(lanes)
            let notes = LaneNotes(lanes)
            let churned = Slots<ChurnReport>(claimers)
            let consumed = Slots<BlockReport>(1)
            var workers: [@Sendable (StressRun) -> Void] = (0..<claimers).map { claimer in
                { run in
                    var report = ChurnReport()
                    defer {
                        churned.set(claimer, report)
                        flags.finished.add(1, ordering: .releasing)
                    }
                    guard run.arriveAndWait() else { return }
                    while report.blocks < blocksEach, !run.shouldStop {
                        guard let token = handoff.claimProducer(frame: Int64(claimer)) else {
                            report.refusedClaims += 1
                            continue
                        }
                        flags.enter(Int(token.lane), claimer)
                        if !notes.isWhole(token.lane) { report.partialHandovers += 1 }
                        for step in 0..<3 {
                            let stamp = FanStamp(producer: claimer, sequence: report.blocks << 2 | step)
                            report.expectOK(handoff.tryPush(stamp, class: .general, frame: 0, token: token))
                        }
                        flags.leave(Int(token.lane), claimer)
                        report.expectOK(handoff.releaseProducer(token))
                        report.blocks += 1
                    }
                    report.finished = report.blocks == blocksEach
                }
            }
            workers.append { run in
                var report = BlockReport(lanes: lanes, producers: claimers, blocksEach: blocksEach)
                defer { consumed.set(0, report) }
                guard run.arriveAndWait() else { return }
                while !run.shouldStop {
                    // Acquire `finished` before draining: an empty drain after it means every push was seen.
                    let done = flags.finished.load(ordering: .acquiring) == claimers
                    let drained = handoff.drain(perLaneQuota: 2, total: 4) {
                        notes.record($0, $1)
                        report.receive($0, $1)
                    }
                    if drained == 0, done {
                        report.finished = true
                        return
                    }
                }
            }
            try #require(runWorkers(workers))

            let reports = (0..<claimers).compactMap { churned.get($0) }
            let consumer = try #require(consumed.get(0))
            #expect(reports.count == claimers && reports.allSatisfy { $0.finished && $0.wrongStatus == 0 })
            #expect(reports.allSatisfy { $0.partialHandovers == 0 })
            #expect(flags.overlaps.load(ordering: .relaxed) == 0)
            #expect(consumer.finished && consumer.torn == 0 && consumer.interleaved == 0 && consumer.duplicates == 0)
            #expect(consumer.blocks == reports.map(\.blocks) && consumer.blocks.allSatisfy { $0 == blocksEach })
            let refused = reports.reduce(0) { $0 + $1.refusedClaims }
            print("FanInStress churn blocks \(reports.map(\.blocks)), refused claims \(refused)")
            #expect(handoff.refusedClaimCount == refused && handoff.refusedNotOwnerCount == 0)
            if refused > 0 {
                #expect(Root.fanInRecord(faults, Root.fanInSlotsScope)?.kind == .producerSlotsExhausted)
                #expect(Root.fanInRecord(faults, Root.fanInSlotsScope)?.count == refused)
            } else {
                #expect(!faults.isLatched(Root.fanInSlotsScope))
            }
            #expect(!faults.isLatched(Root.fanInCriticalScope))
            #expect((0..<lanes).compactMap { _ in handoff.claimProducer() }.count == lanes)
        }

        /// One publisher, three consumers, one of them with a two-slot ring. Each consumer receives exactly the
        /// values its bit accepted, in order, and counts exactly the ones its bit refused.
        @Test(.timeLimit(.minutes(1)))
        func stressFanOutConsumersReceiveExactlyTheirAcceptedValues() throws {
            let total = 60_000
            let capacities = [64, 64, 2]
            let fanOut = try FanOutHandoff<UInt64>(policies: capacities.map { Root.policy(capacity: $0) })
            let publishedFlag = PublishedFlag()
            let published = Slots<[FanOutResult]>(1)
            let received = Slots<[UInt64]>(capacities.count)
            var workers: [@Sendable (StressRun) -> Void] = [{ run in
                var results: [FanOutResult] = []
                results.reserveCapacity(total)
                defer {
                    published.set(0, results)
                    publishedFlag.done.store(true, ordering: .releasing)
                }
                guard run.arriveAndWait() else { return }
                for value in 0..<total where !run.shouldStop { results.append(fanOut.publish(UInt64(value))) }
            }]
            for consumer in capacities.indices {
                workers.append { run in
                    var values: [UInt64] = []
                    defer { received.set(consumer, values) }
                    guard run.arriveAndWait(), let ring = fanOut.ring(consumer) else { return }
                    while !run.shouldStop {
                        let done = publishedFlag.done.load(ordering: .acquiring)
                        if ring.popAll(limit: 4, { values.append($0) }) == 0, done { return }
                    }
                }
            }
            try #require(runWorkers(workers))

            let results = try #require(published.get(0))
            #expect(results.count == total)
            #expect(results.allSatisfy { $0.accepted & $0.refused == 0 && $0.accepted | $0.refused == 0b111 })
            for consumer in capacities.indices {
                let bit = UInt64(1) << consumer
                let expected = results.indices.filter { results[$0].accepted & bit != 0 }.map { UInt64($0) }
                #expect(received.get(consumer) == expected)
                let refused = results.reduce(0) { $0 + ($1.refused & bit == 0 ? 0 : 1) }
                #expect(fanOut.refusedCount(consumer: consumer) == UInt64(refused))
            }
        }
    }
}
