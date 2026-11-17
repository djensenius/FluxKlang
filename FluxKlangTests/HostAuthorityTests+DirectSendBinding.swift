import Foundation
import Synchronization
import Testing
@testable import FluxKlang

private let targetA = DirectSendTarget("target.a")
private let targetB = DirectSendTarget("target.b")
private let targetC = DirectSendTarget("target.c")

private func staleLive() throws -> HostLiveState {
    try AuthorityBench.liveState(epoch: try DirectSendBench.nextEpoch())
}

private func grant(_ authority: HostAuthority, _ targets: [DirectSendTarget] = [targetA, targetB, targetC]) async throws
    -> DirectWriteAuthorization {
    try await DirectSendBench.grant(authority, targets: targets)
}

private enum SendAttempt: Equatable {
    case sent
    case refused(DirectWriteRefusal)
    /// A refusal after the body ran, or an unexpected error: always a failure.
    case broken
}

/// Consumes `target` of `grant` with a body that only records that it ran.
private func attempt(_ grant: DirectWriteAuthorization, _ target: DirectSendTarget) -> SendAttempt {
    var runs = 0
    do {
        try grant.consume(target) { runs += 1 }
    } catch let refused as DirectWriteRefusal {
        return runs == 0 ? .refused(refused) : .broken
    } catch {
        return .broken
    }
    return runs == 1 ? .sent : .broken
}

private final class Flag: Sendable {
    private let value = Atomic(false)
    func set() { value.store(true, ordering: .releasing) }
    var isSet: Bool { value.load(ordering: .acquiring) }
}

/// A monotonic counter shared by threads; each `Stamp.record` takes the next tick (0: not yet).
private final class Ticker: Sendable {
    private let count = Atomic(0)
    func tick() -> Int { count.add(1, ordering: .sequentiallyConsistent).newValue }
}

private final class Stamp: Sendable {
    private let value = Atomic(0)
    func record(_ ticker: Ticker) { value.store(ticker.tick(), ordering: .sequentiallyConsistent) }
    var tick: Int { value.load(ordering: .sequentiallyConsistent) }
}

/// Polls `condition` every 5 ms for at most 10 s.
private func eventually(_ condition: () -> Bool) async throws -> Bool {
    let limit = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(5)) }
    return condition()
}

extension HostAuthorityTests {
    /// Bindings `authorizeDirectSend` refuses with `.invalidBinding`.
    enum InvalidDirectSendBinding: CaseIterable, Sendable {
        case empty, duplicate, overLimit

        var targets: [DirectSendTarget] {
            switch self {
            case .empty: []
            case .duplicate: [targetA, targetB, targetA]
            case .overLimit: (0...HostAuthority.directSendBatchLimit).map { DirectSendTarget("target.\($0)") }
            }
        }
    }

    /// AU4: a send grant binds a set of targets; each sends at most once, anything
    /// else revokes the grant, and a batch holds one capacity slot.
    struct DirectSendBinding {
        @Test func aBoundGrantSendsEachTargetOnce() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let issued = try await grant(authority)
            // Any order: the binding is a set.
            #expect(attempt(issued, targetB) == .sent)
            #expect(attempt(issued, targetA) == .sent)
            #expect(issued.isArmed)
            #expect(await authority.outstandingDirectSendCount() == 1)
            #expect(attempt(issued, targetC) == .sent)
            #expect(!issued.isArmed)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(attempt(issued, targetA) == .refused(.notOutstanding))
        }

        @Test func anUnboundTargetIsRefusedAndRevokesTheRest() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let issued = try await grant(authority, [targetA, targetB])
            #expect(attempt(issued, targetC) == .refused(.notGranted))
            #expect(!issued.isArmed)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(attempt(issued, targetA) == .refused(.notGranted))
            #expect(attempt(issued, targetB) == .refused(.notGranted))
        }

        @Test func aRepeatedTargetIsRefused() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let issued = try await grant(authority, [targetA, targetB])
            #expect(attempt(issued, targetA) == .sent)
            #expect(attempt(issued, targetA) == .refused(.notGranted))
            #expect(!issued.isArmed)
            #expect(attempt(issued, targetB) == .refused(.notGranted))
        }

        /// Fails closed: the ticket is spent and nothing is minted. The redeem
        /// refusal comes first, and exactly `directSendBatchLimit` targets are allowed.
        @Test(arguments: InvalidDirectSendBinding.allCases)
        func anInvalidBindingSpendsTheTicket(_ binding: InvalidDirectSendBinding) async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let ticket = try await DirectSendBench.ticket(authority)
            let before = await authority.snapshot()
            let result = await authority.authorizeDirectSend(ticket, targets: binding.targets)
            #expect(DirectSendBench.refusal(result) == .invalidBinding)
            #expect(await authority.snapshot() == before)
            #expect(await authority.outstandingDirectWriteCount() == 0)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(DirectSendBench.refusal(await authority.redeemDirect(ticket)) == .notOutstanding)

            let stale = try await DirectSendBench.ticket(authority)
            await authority.updateLive(try staleLive())
            #expect(DirectSendBench.refusal(await authority.authorizeDirectSend(stale, targets: binding.targets))
                == .staleLive)

            await authority.updateLive(try AuthorityBench.liveState())
            let full = (0..<HostAuthority.directSendBatchLimit).map { DirectSendTarget("target.\($0)") }
            let largest = try await grant(authority, full)
            #expect(attempt(largest, try #require(full.last)) == .sent)
            #expect(largest.isArmed)
        }

        @Test func aBatchHoldsOneCapacitySlotUntilSpent() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            var grants: [DirectWriteAuthorization] = []
            for _ in 0..<HostAuthority.directSendCapacity {
                grants.append(try await grant(authority, [targetA, targetB]))
            }
            #expect(await authority.outstandingDirectSendCount() == HostAuthority.directSendCapacity)
            let partly = try #require(grants.first)
            #expect(attempt(partly, targetA) == .sent)
            // A partly sent batch still holds its slot.
            #expect(await authority.outstandingDirectSendCount() == HostAuthority.directSendCapacity)
            let refused = try await DirectSendBench.ticket(authority)
            #expect(DirectSendBench.refusal(await authority.authorizeDirectSend(refused, targets: [targetA]))
                == .tooManyOutstanding)

            #expect(attempt(partly, targetB) == .sent)
            #expect(await authority.outstandingDirectSendCount() == HostAuthority.directSendCapacity - 1)
            let fresh = try await grant(authority, [targetC])
            #expect(await authority.outstandingDirectSendCount() == HostAuthority.directSendCapacity)
            #expect(attempt(fresh, targetC) == .sent)
        }

        /// The binding is checked before capacity: at capacity, an invalid binding
        /// is still `.invalidBinding`, the ticket is spent, and the held grants stay armed.
        @Test(arguments: InvalidDirectSendBinding.allCases)
        func anInvalidBindingAtCapacityIsInvalidNotFull(_ binding: InvalidDirectSendBinding) async throws {
            let authority = try await AuthorityBench.makeAuthority()
            var grants: [DirectWriteAuthorization] = []
            for _ in 0..<HostAuthority.directSendCapacity {
                grants.append(try await grant(authority, [targetA, targetB]))
            }
            let ticket = try await DirectSendBench.ticket(authority)
            #expect(DirectSendBench.refusal(await authority.authorizeDirectSend(ticket, targets: binding.targets))
                == .invalidBinding)
            #expect(await authority.outstandingDirectWriteCount() == 0)
            #expect(DirectSendBench.refusal(await authority.redeemDirect(ticket)) == .notOutstanding)
            #expect(await authority.outstandingDirectSendCount() == HostAuthority.directSendCapacity)
            #expect(grants.allSatisfy { $0.isArmed })
        }

        @Test func aLiveChangeMidBatchRevokesTheRemaining() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let issued = try await grant(authority)
            #expect(attempt(issued, targetA) == .sent)
            await authority.updateLive(try staleLive())
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(attempt(issued, targetB) == .refused(.staleLive))
            #expect(attempt(issued, targetC) == .refused(.staleLive))
        }

        @Test func relinquishSpendsAllRemaining() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let issued = try await grant(authority)
            #expect(attempt(issued, targetA) == .sent)
            issued.relinquish()
            #expect(!issued.isArmed)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(attempt(issued, targetB) == .refused(.notOutstanding))
            #expect(attempt(issued, targetC) == .refused(.notOutstanding))

            // A revoked grant keeps its revocation's refusal.
            let revoked = try await grant(authority)
            await authority.updateLive(try staleLive())
            revoked.relinquish()
            #expect(attempt(revoked, targetA) == .refused(.staleLive))
        }

        /// The lock is held per entry: a revocation waits for the entry in flight
        /// (one-sided, as in `DirectWriteSend.anInFlightSendDelaysRevocation`), and
        /// the entries after it never send.
        @Test func anInFlightEntryDelaysRevocationByOneEntry() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let batch = try await grant(authority)
            let entered = Flag(), release = Flag(), exited = Flag()
            let ticker = Ticker(), bodyExit = Stamp(), updateReturn = Stamp()
            defer { release.set() }
            Thread {
                try? batch.consume(targetA) {
                    entered.set()
                    let limit = ContinuousClock.now + .seconds(10)
                    while !release.isSet, ContinuousClock.now < limit { Thread.sleep(forTimeInterval: 0.001) }
                    bodyExit.record(ticker)
                }
                exited.set()
            }.start()
            try #require(try await eventually { entered.isSet })

            let stale = try staleLive()
            let update = Task {
                await authority.updateLive(stale)
                updateReturn.record(ticker)
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(updateReturn.tick == 0)
            release.set()
            await update.value
            #expect(bodyExit.tick > 0)
            #expect(bodyExit.tick < updateReturn.tick)
            #expect(attempt(batch, targetB) == .refused(.staleLive))
            #expect(attempt(batch, targetC) == .refused(.staleLive))
            #expect(try await eventually { exited.isSet })
        }
    }
}
