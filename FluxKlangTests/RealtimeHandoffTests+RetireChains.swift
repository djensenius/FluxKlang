import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Root = RealtimeHandoffTests

/// Shared state for the two-thread retire chain-token stress (#190 FLP5).
private final class RetireChainStressState: Sendable {
    let arrived = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    let exited = Atomic<Int>(0)
    let pushed = Atomic<UInt64>(0)
    let full = Atomic<UInt64>(0)
    let contended = Atomic<UInt64>(0)
    let unexpected = Atomic<UInt64>(0)
}

extension RealtimeHandoffTests {
    /// #190 FLP5: `DeferredReleaseQueue.retire` raises only through the one fault chain the queue mints, holding the
    /// token for the whole call.
    struct RetireChaining {
        static let scope = RetireQueueing.scope

        static func authority(budget: Int = 1) throws -> FaultChainAuthority {
            try FaultChainAuthority(scopes: [scope], chainBudget: budget)
        }

        static func queue(_ faults: FaultChainAuthority, capacity: Int = 2,
                          scope: FaultScope = RetireQueueing.scope) throws -> DeferredReleaseQueue {
            try DeferredReleaseQueue(policy: RetireQueueing.retirePolicy(capacity: capacity), faults: faults,
                                     scope: scope)
        }

        static func preparation(_ faults: FaultChainAuthority,
                                _ policy: HandoffPolicy) -> DeferredReleaseQueue.PreparationError? {
            do {
                _ = try DeferredReleaseQueue(policy: policy, faults: faults, scope: scope)
                return nil
            } catch {
                return error
            }
        }

        static func retained(_ serial: Int, _ ledger: RetireLedger) -> Unmanaged<AnyObject> {
            Unmanaged.passRetained(RetireProbe(serial, ledger) as AnyObject)
        }

        /// T1. Kills: minting no chain, or more than one.
        @Test func initMintsExactlyOneChain() throws {
            let faults = try Self.authority(budget: 3)
            #expect(faults.mintedChains == 0)
            let first = try Self.queue(faults)
            #expect(faults.mintedChains == 1)
            let second = try Self.queue(faults)
            #expect(faults.mintedChains == 2)
            withExtendedLifetime((first, second)) {}
        }

        /// T2. Kills: minting before the policy checks or the ring build; no budget check.
        @Test func chainBudgetIsCheckedLast() throws {
            let faults = try Self.authority(budget: 1)
            let refusals: [(HandoffPolicy, DeferredReleaseQueue.PreparationError)] = [
                (Root.policy(purpose: .events, producer: .render, consumer: .control, deadline: .none),
                 .requires(.retirePurpose)),
                (Root.policy(purpose: .retire, producer: .render, consumer: .control, deadline: .none,
                             overflow: .reservedCritical(reserved: 1)), .requires(.refuseProducer)),
                (RetireQueueing.retirePolicy(capacity: 0), .policy(.violates(.r3Capacity)))
            ]
            for (policy, expected) in refusals {
                #expect(Self.preparation(faults, policy) == expected)
                #expect(faults.mintedChains == 0)
            }
            #expect(Self.preparation(faults, RetireQueueing.retirePolicy()) == nil)
            #expect(faults.mintedChains == 1)
            #expect(Self.preparation(faults, RetireQueueing.retirePolicy()) == .chainBudgetExhausted)
            #expect(faults.mintedChains == 1)
            // With the budget gone, every policy refusal still wins.
            for (policy, expected) in refusals {
                #expect(Self.preparation(faults, policy) == expected)
            }
        }

        /// T3. Kills: pushing before the take; a counted raise without the token; no `raiseContended`; no count.
        @Test func contendedRetirePushesNothingAndLatchesEveryScope() throws {
            let ledger = RetireLedger()
            let faults = try Self.authority()
            let queue = try Self.queue(faults)
            #expect(queue.reserve())
            weak var weakProbe: RetireProbe?
            let object: Unmanaged<AnyObject> = {
                let probe = RetireProbe(0, ledger)
                weakProbe = probe
                return Unmanaged.passRetained(probe as AnyObject)
            }()
            var statuses: [KernelStatus] = []
            #expect(queue.withChainTokenHeld {
                statuses.append(ledger.asRender { queue.retire(object, frame: 12) })
            })
            #expect(statuses == [.refused(.notOwner)])
            #expect(queue.contendedRetireCount == 1 && faults.hasContendedFault)
            #expect(queue.refusedCount == 0 && queue.reservedCount == 1)
            let unprepared = FaultScope(handoff: 99, target: 0)
            #expect([Self.scope, unprepared].allSatisfy(faults.isLatched))
            #expect(Root.FaultChaining.records(faults).isEmpty && faults.unknownScopeFaults == 0)
            #expect(weakProbe != nil && ledger.deinited.load(ordering: .acquiring) == 0)  // the +1 is the caller's
            #expect(queue.reclaim() == 0)  // nothing was pushed
            #expect(weakProbe != nil && queue.reservedCount == 1)
            // The caller still holds its +1, so a retry with the token free hands it over normally.
            #expect(ledger.asRender { queue.retire(object, frame: 13) } == .ok)
            #expect(queue.contendedRetireCount == 1)
            #expect(queue.reclaim() == 1)
            #expect(weakProbe == nil && ledger.live == 0 && ledger.allOnControl)
        }

        /// T4. After `.ok`, after `.refused(.full)` with its raise, and after a contended call, the token is back in
        /// its slot and the next retire is not contended. Kills: a missing `put` on any path.
        @Test func everyReturnPathPutsTheTokenBack() throws {
            let ledger = RetireLedger()
            let faults = try Self.authority()
            let queue = try Self.queue(faults, capacity: 1)
            let first = Self.retained(0, ledger)
            let second = Self.retained(1, ledger)
            #expect(ledger.asRender { queue.retire(first, frame: 1) } == .ok)
            #expect(queue.withChainTokenHeld {})
            #expect(ledger.asRender { queue.retire(second, frame: 2) } == .refused(.full))
            #expect(queue.withChainTokenHeld {})
            var contended: [KernelStatus] = []
            #expect(queue.withChainTokenHeld { contended.append(queue.retire(second, frame: 3)) })
            #expect(contended == [.refused(.notOwner)])
            #expect(ledger.asRender { queue.retire(second, frame: 4) } == .refused(.full))
            #expect(queue.contendedRetireCount == 1 && queue.refusedCount == 2)
            #expect(queue.reclaim() == 1)
            #expect(ledger.asRender { queue.retire(second, frame: 5) } == .ok)
            #expect(queue.withChainTokenHeld {})
            #expect(queue.contendedRetireCount == 1)
            let records = Root.FaultChaining.records(faults)
            #expect(records.map(\.kind) == [.retireBacklog] && records.map(\.count) == [2])
            #expect(queue.reclaim() == 1)
            #expect(ledger.live == 0 && ledger.allOnControl)
        }

        /// T5. Backlog parity with a plain `FaultLatch` raised by hand, and an unprepared scope counted in
        /// `unknownScopeFaults`. Kills: a wrong scope, kind or frame on the token path.
        @Test func backlogFaultsMatchAPlainLatch() throws {
            let ledger = RetireLedger()
            let faults = try Self.authority(budget: 2)
            let twin = try FaultLatch(scopes: [Self.scope])
            let prepared = try Self.queue(faults, capacity: 1)
            let stray = FaultScope(handoff: 98, target: 3)
            let unprepared = try Self.queue(faults, capacity: 1, scope: stray)
            let objects = (0..<4).map { Self.retained($0, ledger) }
            let statuses = ledger.asRender {
                [prepared.retire(objects[0], frame: 3), prepared.retire(objects[1], frame: 17),
                 prepared.retire(objects[1], frame: 18), unprepared.retire(objects[2], frame: 4),
                 unprepared.retire(objects[3], frame: 5)]
            }
            #expect(statuses == [.ok, .refused(.full), .refused(.full), .ok, .refused(.full)])
            _ = twin.raise(Self.scope, .retireBacklog, frame: 17)
            _ = twin.raise(Self.scope, .retireBacklog, frame: 18)
            _ = twin.raise(stray, .retireBacklog, frame: 5)
            let records = Root.FaultChaining.records(faults)
            #expect(records == Root.FaultChaining.records(twin))
            #expect(records.map(\.kind) == [.retireBacklog] && records.map(\.firstFrame) == [17])
            #expect(faults.unknownScopeFaults == 1 && faults.unknownScopeFaults == twin.unknownScopeFaults)
            let observed = try #require(faults.observe(Self.scope))
            let expected = try #require(twin.observe(Self.scope))
            #expect(faults.acknowledge(observed) == twin.acknowledge(expected))
            #expect(!faults.hasContendedFault && prepared.contendedRetireCount == 0)
            #expect(unprepared.contendedRetireCount == 0)
            #expect(prepared.reclaim() == 1 && unprepared.reclaim() == 1)
            objects[1].release()
            objects[3].release()
            #expect(ledger.live == 0 && ledger.allOnControl)
        }

        /// T6. `RetiringExchange.beginCycle` while the queue's token is held: the adoption still happens (`.ok`),
        /// the displaced payload stalls, a stalled retry under contention adopts nothing, and the next free cycle
        /// retries and adopts. Kills: a contended retire treated as `.ok` (the payload would be lost).
        @Test func exchangeCycleUnderContentionStallsAndRetries() throws {
            let ledger = RetireLedger()
            weak var weakOld: RetireProbe?
            let fixture: RetireFixture = try {
                let old = RetireProbe(0, ledger)
                weakOld = old
                return try RetiringExchanging.make(capacity: 2, initial: old)
            }()
            let (exchange, queue, faults) = (fixture.exchange, fixture.queue, fixture.faults)
            #expect(exchange.publish(RetireProbe(1, ledger)) == .ok)
            var statuses: [KernelStatus] = []
            #expect(queue.withChainTokenHeld {
                statuses.append(ledger.asRender { exchange.beginCycle(frame: 1) })  // adopts 1; 0 stalls
                statuses.append(ledger.asRender { exchange.beginCycle(frame: 2) })  // stalled retry contended
            })
            #expect(statuses == [.ok, .refused(.full)])
            #expect(RetiringExchanging.current(exchange, ledger) == 1)
            #expect(queue.contendedRetireCount == 2 && queue.refusedCount == 0 && faults.hasContendedFault)
            #expect(Root.FaultChaining.records(faults).isEmpty)
            #expect(exchange.reclaim() == 0 && weakOld != nil)
            #expect(exchange.publish(RetireProbe(2, ledger)) == .ok)
            #expect(ledger.asRender { exchange.beginCycle(frame: 3) } == .ok)  // retries 0, adopts 2, retires 1
            #expect(RetiringExchanging.current(exchange, ledger) == 2)
            #expect(queue.contendedRetireCount == 2)
            #expect(exchange.reclaim() == 2)
            #expect(weakOld == nil && queue.reservedCount == 0)
            #expect(ledger.live == 1 && ledger.allOnControl)
        }

        /// T7. Two `PreparedPlanSlot`s share one queue, so they share its chain. A cycle on one while the token is
        /// held (as by a concurrent cycle on the other) stalls the displaced entry: nothing is lost or released on
        /// render, and `reclaim` balances once the token is free.
        @Test func sharedQueuePlanSlotCycleUnderContentionLosesNothing() throws {
            let ledger = RetireLedger()
            let watch = ScratchArenaWatch()
            let faults = try Self.authority()
            let queue = try Self.queue(faults)
            do {
                let slot = ScratchProbeSlot(retire: queue)
                let other = ScratchProbeSlot(retire: queue)
                func publish(_ slot: ScratchProbeSlot, _ serial: Int) throws -> KernelStatus {
                    var plan: ScratchPlanProbe? = ScratchPlanProbe(serial, scratchBytes: 16, ledger, watch)
                    return try slot.publish(&plan, scratchBytes: 16, alignment: 8)
                }
                func current(_ slot: ScratchProbeSlot) -> Int? {
                    ledger.asRender { slot.withCurrent { plan, _ in plan.serial } }
                }
                #expect(try publish(slot, 1) == .ok)
                #expect(ledger.asRender { slot.beginCycle(frame: 0) } == .ok)
                #expect(try publish(slot, 2) == .ok)
                var statuses: [KernelStatus] = []
                #expect(queue.withChainTokenHeld {
                    statuses.append(ledger.asRender { slot.beginCycle(frame: 1) })  // adopts 2; 1 stalls
                    statuses.append(ledger.asRender { slot.beginCycle(frame: 2) })  // retry contended
                })
                #expect(statuses == [.ok, .refused(.full)])
                #expect(current(slot) == 2)
                #expect(queue.contendedRetireCount == 2 && faults.hasContendedFault)
                #expect(ledger.deinited.load(ordering: .acquiring) == 0)
                #expect(slot.reclaim() == 0)
                #expect(try publish(other, 7) == .ok)
                #expect(ledger.asRender { other.beginCycle(frame: 3) } == .ok)  // first adoption retires nothing
                #expect(ledger.asRender { slot.beginCycle(frame: 4) } == .empty)  // the retry retires plan 1
                #expect(current(slot) == 2 && current(other) == 7)
                #expect(other.reclaim() == 1)  // plan 1's entry, through the shared queue
                #expect(ledger.deinited.load(ordering: .acquiring) == 1)
                #expect(queue.reservedCount == 0 && queue.refusedCount == 0)
            }
            #expect(ledger.live == 0 && ledger.allOnControl)
            #expect(Root.FaultChaining.records(faults).isEmpty && faults.unknownScopeFaults == 0)
        }
    }

    /// T8 (#190 FLP5). Two `Thread`s call `retire` on one queue at once, outside its one-render-thread contract,
    /// while control reclaims: every call either pushes or refuses (full) while holding the chain token, or is
    /// refused once as contended, so the ring's producer state is never touched concurrently (TSan,
    /// `--filter Stress`) and every object is released exactly once. Kills: removing the take and put.
    struct RetireChainingStress {
        static let callsPerThread = 20_000

        @Test(.timeLimit(.minutes(1)))
        func concurrentRetiresArePushedOrRefusedAsContended() throws {
            let ledger = RetireLedger()
            let faults = try RetireChaining.authority()
            let queue = try RetireChaining.queue(faults, capacity: 64)
            let state = RetireChainStressState()
            for worker in 0..<2 {
                Thread {
                    state.arrived.add(1, ordering: .releasing)
                    let deadline = ContinuousClock.now + .seconds(20)
                    while !state.started.load(ordering: .acquiring), ContinuousClock.now < deadline {}
                    for call in 0..<Self.callsPerThread {
                        let object = RetireChaining.retained(worker * Self.callsPerThread + call, ledger)
                        switch queue.retire(object, frame: Int64(call)) {
                        case .ok:
                            state.pushed.add(1, ordering: .relaxed)
                        case .refused(.full):
                            state.full.add(1, ordering: .relaxed)
                            object.release()
                        case .refused(.notOwner):
                            state.contended.add(1, ordering: .relaxed)
                            object.release()
                        default:
                            state.unexpected.add(1, ordering: .relaxed)
                            object.release()
                        }
                    }
                    state.exited.add(1, ordering: .releasing)
                }.start()
            }
            let arrivalDeadline = ContinuousClock.now + .seconds(20)
            while state.arrived.load(ordering: .acquiring) < 2, ContinuousClock.now < arrivalDeadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            state.started.store(true, ordering: .releasing)
            var reclaimed = 0
            let exitDeadline = ContinuousClock.now + .seconds(30)
            while state.exited.load(ordering: .acquiring) < 2, ContinuousClock.now < exitDeadline {
                reclaimed += queue.reclaim()
            }
            guard state.exited.load(ordering: .acquiring) == 2 else {
                Issue.record("stress workers did not exit; post-run checks skipped")
                return
            }
            reclaimed += queue.reclaim()
            let pushed = state.pushed.load(ordering: .relaxed)
            let full = state.full.load(ordering: .relaxed)
            let contended = state.contended.load(ordering: .relaxed)
            print("RetireChainingStress contended retires: \(contended)")
            #expect(state.unexpected.load(ordering: .relaxed) == 0)
            #expect(pushed + full + contended == UInt64(2 * Self.callsPerThread))
            #expect(UInt64(reclaimed) == pushed && queue.reclaim() == 0)
            #expect(queue.refusedCount == full && queue.contendedRetireCount == contended)
            #expect(faults.hasContendedFault == (contended > 0))
            let records = Root.FaultChaining.records(faults)
            #expect(records.allSatisfy { $0.kind == .retireBacklog })
            #expect(records.reduce(0) { $0 + $1.count } == full && faults.unknownScopeFaults == 0)
            #expect(ledger.created.load(ordering: .acquiring) == 2 * Self.callsPerThread)
            #expect(ledger.live == 0)
            #expect(queue.withChainTokenHeld {})
        }
    }
}
