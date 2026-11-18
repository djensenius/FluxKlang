import Darwin
import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Unsafe only for the test witness: all accesses during worker execution require the caller token.
private final class RefusalCallerWitness: @unchecked Sendable {
    var turn = 0
    var value = 0
    var lastWorker = -1
    var crossings = 0
}

private final class RefusalCallerWorkerBody: Sendable {
    let body: @Sendable () -> Void
    init(_ body: @escaping @Sendable () -> Void) { self.body = body }
}

/// Owned pthreads are joined on every path. Readiness precedes all witness writes; cancellation is relaxed.
private final class RefusalCallerWorkers: Sendable {
    let arrived = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    let cancelled = Atomic<Bool>(false)
    let failures = Atomic<Int>(0)
    static let deadline: Duration = .seconds(15)

    func run(_ body: @escaping @Sendable (Int) -> Void) {
        var threads: [pthread_t] = []
        defer {
            for thread in threads { #expect(pthread_join(thread, nil) == 0) }
        }
        for index in 0..<2 {
            let box = RefusalCallerWorkerBody {
                self.arrived.add(1, ordering: .releasing)
                let end = ContinuousClock.now + Self.deadline
                while !self.started.load(ordering: .acquiring) {
                    if self.cancelled.load(ordering: .relaxed) || ContinuousClock.now >= end {
                        self.failures.add(1, ordering: .relaxed)
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.0001)
                }
                body(index)
            }
            let context = Unmanaged.passRetained(box).toOpaque()
            var thread: pthread_t?
            let status = pthread_create(&thread, nil, { context in
                Unmanaged<RefusalCallerWorkerBody>.fromOpaque(context).takeRetainedValue().body()
                return nil
            }, context)
            guard status == 0, let thread else {
                Unmanaged<RefusalCallerWorkerBody>.fromOpaque(context).release()
                cancelled.store(true, ordering: .relaxed)
                Issue.record("pthread_create failed: \(status)")
                return
            }
            threads.append(thread)
        }
        let end = ContinuousClock.now + Self.deadline
        while arrived.load(ordering: .acquiring) != 2 && ContinuousClock.now < end {
            Thread.sleep(forTimeInterval: 0.0001)
        }
        guard arrived.load(ordering: .acquiring) == 2 else {
            cancelled.store(true, ordering: .relaxed)
            Issue.record("refusal caller workers did not reach start barrier")
            return
        }
        started.store(true, ordering: .releasing)
    }
}

extension RealtimeHandoffTests {
    struct RefusalCallerTransfer {
        @Test(.timeLimit(.minutes(1))) func simultaneousTakeHasExactlyOneWinner() throws {
            let role = try #require(RefusalCaller.prepare())
            let workers = RefusalCallerWorkers()
            let attempted = Atomic<Int>(0)
            let winners = Atomic<Int>(0)
            workers.run { _ in
                let token = role.take()
                attempted.add(1, ordering: .relaxed)
                guard let token else { return }
                winners.add(1, ordering: .relaxed)
                let end = ContinuousClock.now + RefusalCallerWorkers.deadline
                while attempted.load(ordering: .relaxed) != 2 && ContinuousClock.now < end {
                    Thread.sleep(forTimeInterval: 0.0001)
                }
                if attempted.load(ordering: .relaxed) != 2 { workers.failures.add(1, ordering: .relaxed) }
                if role.put(token) != .ok { workers.failures.add(1, ordering: .relaxed) }
            }
            #expect(attempted.load(ordering: .relaxed) == 2)
            #expect(winners.load(ordering: .relaxed) == 1)
            #expect(workers.failures.load(ordering: .relaxed) == 0)
            #expect(!RefusalCalling.isEmpty(role))
        }

        @Test(.timeLimit(.minutes(1))) func prestartedWorkersTransferPlainWitness() throws {
            let role = try #require(RefusalCaller.prepare())
            let workers = RefusalCallerWorkers()
            let witness = RefusalCallerWitness()
            let rounds = 1_000
            workers.run { index in
                let end = ContinuousClock.now + RefusalCallerWorkers.deadline
                var completed = 0
                while completed < rounds && ContinuousClock.now < end {
                    if workers.cancelled.load(ordering: .relaxed) { break }
                    guard let token = role.take() else { continue }
                    if witness.turn == index {
                        // This read is before any join or post-write auxiliary synchronization.
                        if witness.value != completed * 2 + index {
                            workers.failures.add(1, ordering: .relaxed)
                        }
                        if witness.lastWorker != -1 && witness.lastWorker != index { witness.crossings += 1 }
                        witness.lastWorker = index
                        witness.value += 1
                        witness.turn = 1 - index
                        completed += 1
                    }
                    if role.put(token) != .ok { workers.failures.add(1, ordering: .relaxed) }
                }
                if completed != rounds {
                    workers.failures.add(1, ordering: .relaxed)
                    workers.cancelled.store(true, ordering: .relaxed)
                }
            }
            #expect(workers.failures.load(ordering: .relaxed) == 0)
            #expect(witness.value == rounds * 2)
            #expect(witness.crossings == rounds * 2 - 1)
            #expect(!RefusalCalling.isEmpty(role))
        }

        /// K-RC2: two workers, each borrowing its own role's token, push and release through stale tokens of this
        /// handoff and live tokens of another. Every attempt is refused `.notOwner` and counted once on this handoff
        /// only; no lane ring counts. Kills: a lost or doubled `refusedNotOwner` bump; a refusal counted on a lane
        /// or on the other handoff.
        @Test(.timeLimit(.minutes(1))) func concurrentStaleAndForeignRefusalsCountExactly() throws {
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let rig = try CycleRig(lanes: 2)
            let other = try CycleRig(lanes: 2)
            let stale = try (0..<2).map { _ in try RefusalCalling.claim(rig.events, &caller!) }
            for token in stale { #expect(rig.events.releaseProducer(token, caller: &caller!) == .ok) }
            let foreign = try (0..<2).map { _ in try RefusalCalling.claim(other.events, &caller!) }
            let roles = try (0..<2).map { _ in try #require(RefusalCaller.prepare()) }
            let workers = RefusalCallerWorkers()
            let rounds = 1_000
            workers.run { index in
                var caller: RefusalCallerToken? = try? RefusalCalling.take(roles[index])
                defer { RefusalCalling.giveBack(roles[index], &caller) }
                guard caller != nil else { workers.failures.add(1, ordering: .relaxed); return }
                let event = cycleEvent(100, .control(channel: 0, controller: 7, value: 0))
                for _ in 0..<rounds {
                    for token in [stale[index], foreign[index]] {
                        let pushed = rig.events.tryPush(event, class: .general, frame: 100, token: token,
                                                        caller: &caller!)
                        let released = rig.events.releaseProducer(token, caller: &caller!)
                        if pushed != .refused(.notOwner) || released != .refused(.notOwner) {
                            workers.failures.add(1, ordering: .relaxed)
                        }
                    }
                }
            }
            #expect(workers.failures.load(ordering: .relaxed) == 0)
            #expect(rig.events.refusedNotOwnerCount == UInt64(2 * rounds * 4))
            #expect(other.events.refusedNotOwnerCount == 0 && rig.events.refusedClaimCount == 0)
            for lane in 0..<2 {
                #expect(rig.events.refusedCount(lane: lane, class: .general) == 0)
                #expect(other.events.refusedCount(lane: lane, class: .general) == 0)
            }
            #expect(roles.allSatisfy { !RefusalCalling.isEmpty($0) })
        }

        /// K-RC2: two workers, each with its own role and worker-local `ProducerAdmission`s over one table, count
        /// every admission kind on their live lane, a stale token's refusals on its old lane, another handoff's in
        /// `unattributed`, and nothing for other statuses. An admissible stale push passes admission and is refused
        /// `.notOwner` by the fan-in. Kills: a lost or doubled admission bump; a stale refusal moved off its lane or
        /// into `unattributed`; ownership checked before admission; an ignored status counted.
        @Test(.timeLimit(.minutes(1))) func concurrentAdmissionRefusalsCountPerLaneAndKind() throws {
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let rig = try CycleRig(lanes: 4)
            let other = try CycleRig(lanes: 2)
            let live = try (0..<2).map { _ in try RefusalCalling.claim(rig.events, &caller!) }
            let stale = try (0..<2).map { _ in try RefusalCalling.claim(rig.events, &caller!) }
            for token in stale { #expect(rig.events.releaseProducer(token, caller: &caller!) == .ok) }
            let foreign = try (0..<2).map { _ in try RefusalCalling.claim(other.events, &caller!) }
            let refusals = rig.cycle.admissionRefusals
            let deadline = rig.cycle.deadline
            let roles = try (0..<2).map { _ in try #require(RefusalCaller.prepare()) }
            let workers = RefusalCallerWorkers()
            let rounds = 1_000
            workers.run { index in
                var caller: RefusalCallerToken? = try? RefusalCalling.take(roles[index])
                defer { RefusalCalling.giveBack(roles[index], &caller) }
                guard caller != nil else { workers.failures.add(1, ordering: .relaxed); return }
                var own = ProducerAdmission(deadline: deadline, refusals: refusals)
                var old = ProducerAdmission(deadline: deadline, refusals: refusals)
                var away = ProducerAdmission(deadline: deadline, refusals: refusals)
                let control = KernelEventPayload.control(channel: 0, controller: 7, value: 0)
                let nonFinite = KernelEventPayload.rampTo(parameter: 1, value: .nan, durationFrames: 8)
                var failures = 0
                func check(_ status: KernelStatus, _ expected: KernelStatus) { failures += status == expected ? 0 : 1 }
                check(own.push(cycleEvent(100, control), now: 0, into: rig.events, token: live[index],
                               caller: &caller!), .ok)
                for _ in 0..<rounds {
                    check(own.push(cycleEvent(96_001, control), now: 0, into: rig.events, token: live[index],
                                   caller: &caller!), .refused(.beyondLookahead))
                    check(own.push(cycleEvent(50, control), now: 0, into: rig.events, token: live[index],
                                   caller: &caller!), .refused(.nonMonotonic))
                    check(own.push(cycleEvent(200, nonFinite), now: 0, into: rig.events, token: live[index],
                                   caller: &caller!), .refused(.nonFinite))
                    check(old.push(cycleEvent(96_001, control), now: 0, into: rig.events, token: stale[index],
                                   caller: &caller!), .refused(.beyondLookahead))
                    check(old.push(cycleEvent(300, control), now: 0, into: rig.events, token: stale[index],
                                   caller: &caller!), .refused(.notOwner))
                    check(away.push(cycleEvent(96_001, control), now: 0, into: rig.events, token: foreign[index],
                                    caller: &caller!), .refused(.beyondLookahead))
                    for status in [KernelStatus.ok, .refused(.full), .refused(.notOwner)] {
                        refusals.record(status, token: live[index], caller: &caller!)
                    }
                }
                if failures != 0 || old.lastAdmittedFrame != nil { workers.failures.add(1, ordering: .relaxed) }
            }
            #expect(workers.failures.load(ordering: .relaxed) == 0)
            let count = UInt64(rounds)
            for token in live {
                let lane = Int(token.lane)
                #expect(refusals.count(lane: lane, .beyondLookahead) == count)
                #expect(refusals.count(lane: lane, .nonMonotonic) == count)
                #expect(refusals.count(lane: lane, .nonFinite) == count)
            }
            for token in stale {
                let lane = Int(token.lane)
                #expect(refusals.count(lane: lane, .beyondLookahead) == count)
                #expect(refusals.count(lane: lane, .nonMonotonic) == 0 && refusals.count(lane: lane, .nonFinite) == 0)
            }
            #expect(refusals.unattributed == 2 * count)
            #expect(rig.events.refusedNotOwnerCount == 2 * count && other.events.refusedNotOwnerCount == 0)
            #expect(roles.allSatisfy { !RefusalCalling.isEmpty($0) })
        }
    }
}
