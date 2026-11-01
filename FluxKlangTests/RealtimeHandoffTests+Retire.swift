import Foundation
import Synchronization
import Testing
@testable import FluxKlang

private typealias Root = RealtimeHandoffTests

/// Where every `RetireProbe` `deinit` ran. The control thread is the creating thread unless a stress test moves it;
/// `asRender` marks the calling thread as render for the duration of `body`.
final class RetireLedger: Sendable {
    let created = Atomic<Int>(0)
    let deinited = Atomic<Int>(0)
    let renderDeinits = Atomic<Int>(0)
    let controlDeinits = Atomic<Int>(0)
    let renderThread = Atomic<UInt>(0)
    let controlThread = Atomic<UInt>(0)

    init() { controlThread.store(Self.currentThread(), ordering: .releasing) }

    static func currentThread() -> UInt { UInt(bitPattern: pthread_self()) }

    func asRender<R>(_ body: () -> R) -> R {
        renderThread.store(Self.currentThread(), ordering: .releasing)
        defer { renderThread.store(0, ordering: .releasing) }
        return body()
    }

    func noteDeinit() {
        let thread = Self.currentThread()
        if renderThread.load(ordering: .acquiring) == thread {
            renderDeinits.add(1, ordering: .relaxed)
        } else if controlThread.load(ordering: .acquiring) == thread {
            controlDeinits.add(1, ordering: .relaxed)
        }
        deinited.add(1, ordering: .releasing)
    }

    var live: Int { created.load(ordering: .acquiring) - deinited.load(ordering: .acquiring) }
    var allOnControl: Bool {
        renderDeinits.load(ordering: .acquiring) == 0
            && controlDeinits.load(ordering: .acquiring) == deinited.load(ordering: .acquiring)
    }
}

/// A payload whose `deinit` records its thread and poisons `magic`, so a render read after free shows.
final class RetireProbe: @unchecked Sendable {
    static let alive: UInt64 = 0x464B_3634_4D36_4F4B
    static let dead: UInt64 = 0xDEAD_DEAD_DEAD_DEAD
    let serial: Int
    let ledger: RetireLedger
    /// Written only in `init` and `deinit`.
    var magic: UInt64

    init(_ serial: Int, _ ledger: RetireLedger) {
        self.serial = serial
        self.ledger = ledger
        magic = Self.alive
        ledger.created.add(1, ordering: .relaxed)
    }

    deinit {
        magic = Self.dead
        ledger.noteDeinit()
    }
}

typealias ProbeExchange = RetiringExchange<RetireProbe>

/// One exchange with its own retire queue and fault latch.
struct RetireFixture {
    let exchange: ProbeExchange
    let queue: DeferredReleaseQueue
    let faults: FaultLatch
}

extension RealtimeHandoffTests {
    struct RetireQueueing {
        static let scope = FaultScope(handoff: 6, target: 0)

        static func retirePolicy(capacity: Int = 4) -> HandoffPolicy {
            Root.policy(purpose: .retire, producer: .render, consumer: .control, capacity: capacity, deadline: .none)
        }

        static func makeQueue(capacity: Int) throws -> (DeferredReleaseQueue, FaultLatch) {
            let faults = try FaultLatch(scopes: [scope])
            return (try DeferredReleaseQueue(policy: retirePolicy(capacity: capacity), faults: faults, scope: scope),
                    faults)
        }

        static func preparationError(_ policy: HandoffPolicy) throws -> DeferredReleaseQueue.PreparationError? {
            let faults = try FaultLatch(scopes: [scope])
            do {
                _ = try DeferredReleaseQueue(policy: policy, faults: faults, scope: scope)
                return nil
            } catch {
                return error
            }
        }

        @Test func initRejectsAnythingButRenderToControlRefusingRetire() throws {
            #expect(try Self.preparationError(Self.retirePolicy()) == nil)
            let cases: [(HandoffPolicy, DeferredReleaseQueue.PreparationError)] = [
                (Root.policy(purpose: .events, producer: .render, consumer: .control, deadline: .none),
                 .requires(.retirePurpose)),
                (Root.policy(purpose: .retire, producer: .control, consumer: .control, deadline: .none),
                 .requires(.renderProducer)),
                (Root.policy(purpose: .retire, producer: .render, consumer: .control, deadline: .none,
                             overflow: .reservedCritical(reserved: 1)), .requires(.refuseProducer)),
                (Root.policy(purpose: .retire, producer: .render, consumer: .ui, deadline: .none),
                 .policy(.violates(.r5TelemetryNotRender))),
                (Root.policy(purpose: .retire, producer: .render, consumer: .render, deadline: .none),
                 .policy(.violates(.r5TelemetryNotRender))),
                (Root.policy(purpose: .retire, producer: .render, producers: .init(maximum: 2, evidence: .appOwned),
                             consumer: .control, deadline: .none), .policy(.violates(.r2Cardinality))),
                (Root.policy(purpose: .retire, producer: .render, consumer: .control, consumers: 2, deadline: .none),
                 .policy(.violates(.r1SingleConsumer))),
                (Self.retirePolicy(capacity: 0), .policy(.violates(.r3Capacity)))
            ]
            for (policy, expected) in cases {
                #expect(try Self.preparationError(policy) == expected)
            }
        }

        /// The defensive path: an unreserved push past capacity raises `.retireBacklog`, refuses and keeps the +1
        /// with the caller; nothing is released on render.
        @Test func overflowingPushRaisesBacklogAndNeverReleases() throws {
            let ledger = RetireLedger()
            let (queue, faults) = try Self.makeQueue(capacity: 2)
            weak var weakRefused: RetireProbe?
            let refused: Unmanaged<AnyObject> = {
                let probe = RetireProbe(2, ledger)
                weakRefused = probe
                return Unmanaged.passRetained(probe as AnyObject)
            }()
            let statuses = ledger.asRender {
                [Unmanaged.passRetained(RetireProbe(0, ledger) as AnyObject),
                 Unmanaged.passRetained(RetireProbe(1, ledger) as AnyObject),
                 refused].map { queue.retire($0, frame: 41) }
            }
            #expect(statuses == [.ok, .ok, .refused(.full)])
            #expect(ledger.deinited.load(ordering: .acquiring) == 0)
            #expect(weakRefused != nil)
            let record = try #require(faults.acknowledge(Self.scope))
            #expect(record.kind == .retireBacklog)
            #expect(record.count == 1)
            #expect(record.firstFrame == 41)
            #expect(queue.reclaim() == 2)
            #expect(queue.reclaim() == 0)
            #expect(queue.reservedCount == 0)  // reclaiming unreserved retires clamps at 0
            refused.release()
            #expect(weakRefused == nil)
            #expect(ledger.live == 0)
            #expect(ledger.allOnControl)
        }

        @Test func reservationsAreBoundedAndReturned() throws {
            let (queue, _) = try Self.makeQueue(capacity: 2)
            #expect(queue.reserve())
            #expect(queue.reserve())
            #expect(!queue.reserve())
            #expect(queue.reservedCount == 2)
            queue.cancelReservation()
            #expect(queue.reservedCount == 1)
            queue.cancelReservation()
            queue.cancelReservation()
            #expect(queue.reservedCount == 0)
        }
    }

    struct RetiringExchanging {
        static func make(capacity: Int, initial: RetireProbe?) throws -> RetireFixture {
            let (queue, faults) = try RetireQueueing.makeQueue(capacity: capacity)
            return RetireFixture(exchange: ProbeExchange(initial: initial, retire: queue), queue: queue, faults: faults)
        }

        static func current(_ exchange: ProbeExchange, _ ledger: RetireLedger) -> Int? {
            ledger.asRender {
                exchange.withCurrent { probe in
                    guard let probe else { return nil }
                    return probe.magic == RetireProbe.alive ? probe.serial : -1
                }
            }
        }

        @Test func publishAdoptRetireAndReclaimOnControl() throws {
            let ledger = RetireLedger()
            weak var weakOld: RetireProbe?
            weak var weakNew: RetireProbe?
            let fixture: RetireFixture = try {
                let old = RetireProbe(0, ledger)
                let next = RetireProbe(1, ledger)
                (weakOld, weakNew) = (old, next)
                let made = try Self.make(capacity: 2, initial: old)
                #expect(made.exchange.publish(next) == .ok)
                return made
            }()
            let (exchange, queue, faults) = (fixture.exchange, fixture.queue, fixture.faults)
            #expect(Self.current(exchange, ledger) == 0)
            #expect(ledger.asRender { exchange.beginCycle(frame: 5) } == .ok)
            #expect(Self.current(exchange, ledger) == 1)
            #expect(weakOld != nil)
            #expect(ledger.deinited.load(ordering: .acquiring) == 0)
            #expect(queue.reservedCount == 1)
            #expect(exchange.reclaim() == 1)
            #expect(weakOld == nil)
            #expect(weakNew != nil)
            #expect(queue.reservedCount == 0)
            #expect(ledger.asRender { exchange.beginCycle(frame: 6) } == .empty)
            #expect(Self.current(exchange, ledger) == 1)
            #expect(!faults.isLatched(RetireQueueing.scope))
            #expect(ledger.allOnControl)
        }

        @Test func supersededPendingIsReleasedOnControlAndNeverReachesRender() throws {
            let ledger = RetireLedger()
            weak var weakFirst: RetireProbe?
            let fixture = try Self.make(capacity: 1, initial: RetireProbe(0, ledger))
            let exchange = fixture.exchange
            let queue = fixture.queue
            do {
                let first = RetireProbe(1, ledger)
                weakFirst = first
                #expect(exchange.publish(first) == .ok)
            }
            #expect(queue.reservedCount == 1)
            #expect(exchange.publish(RetireProbe(2, ledger)) == .ok)
            #expect(weakFirst == nil)
            #expect(queue.reservedCount == 1)
            #expect(exchange.publish(RetireProbe(3, ledger)) == .ok)
            #expect(ledger.deinited.load(ordering: .acquiring) == 2)
            #expect(ledger.asRender { exchange.beginCycle(frame: 0) } == .ok)
            #expect(Self.current(exchange, ledger) == 3)
            #expect(exchange.reclaim() == 1)
            #expect(ledger.live == 1)
            #expect(ledger.allOnControl)
        }

        @Test func publishRefusedAtBacklogBoundWithoutFault() throws {
            let ledger = RetireLedger()
            let fixture = try Self.make(capacity: 2, initial: RetireProbe(0, ledger))
            let exchange = fixture.exchange
            let queue = fixture.queue
            let faults = fixture.faults
            for serial in 1...2 {
                #expect(exchange.publish(RetireProbe(serial, ledger)) == .ok)
                #expect(ledger.asRender { exchange.beginCycle(frame: 0) } == .ok)
            }
            #expect(queue.reservedCount == 2)
            #expect(exchange.publish(RetireProbe(3, ledger)) == .refused(.full))
            #expect(ledger.deinited.load(ordering: .acquiring) == 1)  // the refused probe, dropped by the caller
            #expect(Self.current(exchange, ledger) == 2)
            #expect(exchange.reclaim() == 2)
            #expect(exchange.publish(RetireProbe(4, ledger)) == .ok)
            #expect(ledger.asRender { exchange.beginCycle(frame: 0) } == .ok)
            #expect(Self.current(exchange, ledger) == 4)
            #expect(!faults.isLatched(RetireQueueing.scope))
            #expect(ledger.allOnControl)
        }

        @Test func nilInitialAdoptionRetiresNothingAndHoldsNoReservation() throws {
            let ledger = RetireLedger()
            let fixture = try Self.make(capacity: 1, initial: nil)
            let exchange = fixture.exchange
            let queue = fixture.queue
            #expect(Self.current(exchange, ledger) == nil)
            #expect(ledger.asRender { exchange.beginCycle(frame: 0) } == .empty)
            #expect(exchange.publish(RetireProbe(1, ledger)) == .ok)
            #expect(queue.reservedCount == 0)
            #expect(exchange.publish(RetireProbe(2, ledger)) == .ok)
            #expect(queue.reservedCount == 0)
            #expect(ledger.asRender { exchange.beginCycle(frame: 0) } == .ok)
            #expect(Self.current(exchange, ledger) == 2)
            #expect(exchange.reclaim() == 0)
            #expect(exchange.publish(RetireProbe(3, ledger)) == .ok)
            #expect(queue.reservedCount == 1)
            #expect(exchange.publish(RetireProbe(4, ledger)) == .ok)
            #expect(ledger.asRender { exchange.beginCycle(frame: 0) } == .ok)
            #expect(exchange.reclaim() == 1)
            #expect(ledger.live == 1)
            #expect(ledger.allOnControl)
        }

        /// Defensive path: a retire queue overfilled by an unreserved push makes `beginCycle` adopt (`.ok`) but
        /// stall the old payload on render (fault raised). The next cycle retries it and, while that is still
        /// refused, adopts nothing (`.refused(.full)`). Nothing is released on render or lost.
        @Test func stalledRetireIsKeptRetriedAndNeverReleasedOnRender() throws {
            let ledger = RetireLedger()
            weak var weakOld: RetireProbe?
            let fixture: RetireFixture = try {
                let old = RetireProbe(0, ledger)
                weakOld = old
                return try Self.make(capacity: 1, initial: old)
            }()
            let (exchange, queue, faults) = (fixture.exchange, fixture.queue, fixture.faults)
            #expect(exchange.publish(RetireProbe(1, ledger)) == .ok)
            let intruder = Unmanaged.passRetained(RetireProbe(9, ledger) as AnyObject)
            #expect(ledger.asRender { queue.retire(intruder, frame: 3) } == .ok)
            #expect(ledger.asRender { exchange.beginCycle(frame: 7) } == .ok)  // adopted; the old payload stalled
            #expect(Self.current(exchange, ledger) == 1)
            #expect(weakOld != nil)
            #expect(queue.refusedCount == 1)
            #expect(faults.acknowledge(RetireQueueing.scope)?.kind == .retireBacklog)
            #expect(ledger.asRender { exchange.beginCycle(frame: 8) } == .refused(.full))  // nothing adopted
            #expect(Self.current(exchange, ledger) == 1)
            #expect(faults.acknowledge(RetireQueueing.scope)?.firstFrame == 8)
            #expect(exchange.reclaim() == 1)  // the intruder
            #expect(weakOld != nil)
            #expect(ledger.asRender { exchange.beginCycle(frame: 9) } == .empty)
            #expect(exchange.reclaim() == 1)
            #expect(weakOld == nil)
            #expect(queue.reservedCount == 0)  // the intruder was unreserved: the clamp absorbs it
            #expect(!faults.isLatched(RetireQueueing.scope))
            #expect(ledger.allOnControl)
        }

        /// Builds two exchanges sharing one queue in every holding state (current, retired, stalled, pending,
        /// superseded), drops them and the queue, and returns weak references to every payload.
        fileprivate static func buildAndDrop(_ ledger: RetireLedger) throws -> [() -> RetireProbe?] {
            let probes = (0..<6).map { RetireProbe($0, ledger) }
            let fixture = try Self.make(capacity: 2, initial: probes[0])
            let exchange = fixture.exchange
            let queue = fixture.queue
            let other = ProbeExchange(initial: nil, retire: queue)
            #expect(exchange.publish(probes[1]) == .ok)
            #expect(ledger.asRender { exchange.beginCycle(frame: 0) } == .ok)  // probes[0] retired
            let intruder = Unmanaged.passRetained(probes[5] as AnyObject)
            #expect(ledger.asRender { queue.retire(intruder, frame: 0) } == .ok)  // queue now full
            #expect(exchange.publish(probes[2]) == .ok)
            #expect(ledger.asRender { exchange.beginCycle(frame: 0) } == .ok)  // adopted probes[2]; probes[1] stalled
            #expect(other.publish(probes[3]) == .ok)  // pending without a reservation
            #expect(other.publish(probes[4]) == .ok)  // supersedes probes[3]
            return probes.map { probe in { [weak probe] in probe } }
        }

        @Test func teardownReleasesEveryPayloadExactlyOnceOnControl() throws {
            let ledger = RetireLedger()
            let weakProbes = try Self.buildAndDrop(ledger)
            #expect(weakProbes.allSatisfy { $0() == nil })
            #expect(ledger.created.load(ordering: .acquiring) == 6)
            #expect(ledger.deinited.load(ordering: .acquiring) == 6)
            #expect(ledger.allOnControl)
        }

        @Test func teardownReturnsReservationsToASharedQueue() throws {
            let ledger = RetireLedger()
            let (queue, _) = try RetireQueueing.makeQueue(capacity: 2)
            do {
                let exchange = ProbeExchange(initial: RetireProbe(0, ledger), retire: queue)
                #expect(exchange.publish(RetireProbe(1, ledger)) == .ok)
                #expect(queue.reservedCount == 1)
            }
            #expect(queue.reservedCount == 0)
            #expect(ledger.live == 0)
            #expect(ledger.allOnControl)
        }

        /// Teardown returns exactly the reservations the exchange still holds. An adopted payload's reservation
        /// belongs to its retired predecessor (returned by `reclaim`, not teardown). A stalled payload's
        /// reservation is returned once, leaving other holders' reservations intact. An unadopted first payload of
        /// an initial-nil exchange holds none, so its teardown returns none.
        @Test func teardownAfterAdoptionOrStallReturnsExactlyItsReservations() throws {
            let ledger = RetireLedger()
            let (queue, faults) = try RetireQueueing.makeQueue(capacity: 2)
            do {
                let exchange = ProbeExchange(initial: RetireProbe(0, ledger), retire: queue)
                #expect(exchange.publish(RetireProbe(1, ledger)) == .ok)
                #expect(ledger.asRender { exchange.beginCycle(frame: 0) } == .ok)  // probe 0 retired, unreclaimed
            }
            #expect(queue.reservedCount == 1)
            #expect(queue.reclaim() == 1)
            #expect(queue.reservedCount == 0)
            #expect(queue.reserve())  // another holder sharing the queue
            do {
                let exchange = ProbeExchange(initial: RetireProbe(2, ledger), retire: queue)
                #expect(exchange.publish(RetireProbe(3, ledger)) == .ok)
                let intruders = [RetireProbe(8, ledger), RetireProbe(9, ledger)]
                    .map { Unmanaged.passRetained($0 as AnyObject) }
                #expect(ledger.asRender { intruders.map { queue.retire($0, frame: 1) } } == [.ok, .ok])
                #expect(ledger.asRender { exchange.beginCycle(frame: 2) } == .ok)  // probe 2 stalled
                #expect(queue.reservedCount == 2)
            }
            #expect(queue.reservedCount == 1)  // only the stalled payload's reservation came back
            do {
                // Initial-nil exchange, published but never adopted: its first adoption would retire nothing, so
                // it took no reservation and teardown must return none.
                let fresh = ProbeExchange(initial: nil, retire: queue)
                #expect(fresh.publish(RetireProbe(4, ledger)) == .ok)
                #expect(queue.reservedCount == 1)
            }
            #expect(queue.reservedCount == 1)
            #expect(faults.acknowledge(RetireQueueing.scope)?.kind == .retireBacklog)
            #expect(queue.reclaim() == 2)
            #expect(ledger.live == 0)
            #expect(ledger.allOnControl)
        }

        /// Plan row `withCurrentDoesNotRetain`: the lent reference carries no retain of its own. The retain count
        /// seen inside the body equals the same measurement, with the same argument shape (`RetireProbe?`), on
        /// the caller's own strong reference.
        /// (`isKnownUniquelyReferenced` cannot observe this: binding the lent reference to a `var` retains it.)
        @Test func withCurrentDoesNotRetain() throws {
            let ledger = RetireLedger()
            let held: RetireProbe? = RetireProbe(0, ledger)
            let fixture = try Self.make(capacity: 1, initial: held)
            let outside = Self.retainCount(held)
            let inside = ledger.asRender { fixture.exchange.withCurrent(Self.retainCount) }
            #expect(outside > 0)
            #expect(inside == outside)
            withExtendedLifetime(held) {}
        }

        @inline(never)
        static func retainCount(_ probe: RetireProbe?) -> UInt {
            guard let probe else { return 0 }
            return _getRetainCount(probe)
        }
    }
}
