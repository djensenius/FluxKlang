import Foundation
import Synchronization
import Testing
@testable import FluxKlang

private let projectA = AuthorityBench.projectA
private let projectB = AuthorityBench.projectB
private let windowA = AuthorityBench.windowA
private let windowA2 = AuthorityBench.windowA2
private let windowB = AuthorityBench.windowB
private let liveParameter = ParameterID(validated: "parameter.live")
/// Every grant here binds this one target.
private let target = DirectSendTarget("target.direct")

private func nextEpoch() throws -> HostEpoch {
    HostEpoch(host: AuthorityBench.host, generation: try Generation.initial.next())
}

private func live(epoch: HostEpoch = AuthorityBench.hostEpoch) throws -> HostLiveState {
    try AuthorityBench.liveState(epoch: epoch)
}

/// Admits a running-set `.set` of `liveParameter` (as in `HostAuthorityTests+DirectWrite.swift`).
private func admission() throws -> AdmissionContext {
    let descriptor = try ParameterDescriptor(.init(
        id: liveParameter, unit: .normalized, lower: 0, upper: 1, defaultValue: 0.5, ceiling: 0.8, curve: .linear,
        ramp: ParameterRamp(.init(kind: .linear, minimumMilliseconds: 10, maximumMilliseconds: 100)),
        controlClass: .live, verification: .reported
    ))
    return AdmissionContext(hostEpoch: AuthorityBench.hostEpoch, connectionEpoch: nil, revisions: CommandRevisions(),
                            permission: AuthorityBench.permission, allowedScopes: [.parameter(liveParameter)],
                            allowedClasses: Set(ControlClass.allCases), catalog: try ParameterCatalog([descriptor]))
}

private func intent() throws -> CommandIntent {
    try CommandIntent(.init(
        id: CommandID(validated: "command.direct"), commandClass: .live, origin: .human,
        hostEpoch: AuthorityBench.hostEpoch, connectionEpoch: nil, revisions: CommandRevisions(),
        operation: .set(liveParameter, ParameterValue(value: 0.5, unit: .normalized)),
        permission: AuthorityBench.permission
    ))
}

private func ticket(_ authority: HostAuthority, window: WindowID = windowA) async throws -> DirectWriteTicket {
    try #require(try await authority.admitDirect(try intent(), admission: try admission(),
                                                 project: projectA, window: window).get())
}

private func grant(_ authority: HostAuthority, window: WindowID = windowA) async throws -> DirectWriteAuthorization {
    try await authority.authorizeDirectSend(try await ticket(authority, window: window), targets: [target]).get()
}

private func refusal<Success>(_ result: Result<Success, DirectWriteRefusal>) -> DirectWriteRefusal? {
    if case .failure(let refusal) = result { return refusal }
    return nil
}

private enum SendAttempt: Equatable {
    case sent
    case refused(DirectWriteRefusal)
    /// A refusal after the body ran, or an unexpected error: always a failure.
    case broken
}

/// Consumes `grant` with a body that only records that it ran.
private func attempt(_ grant: DirectWriteAuthorization) -> SendAttempt {
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

private struct SendFailed: Error, Equatable {}

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
    /// AU2: redeemed tickets become lock-guarded, single-use send grants that the
    /// authority revokes in the same actor turn that stales them.
    struct DirectWriteSend {
        @Test func aFreshGrantSendsOnceThenRefuses() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let issued = try await grant(authority)
            #expect(issued.isArmed)
            #expect(await authority.outstandingDirectSendCount() == 1)
            #expect(attempt(issued) == .sent)
            #expect(!issued.isArmed)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(attempt(issued) == .refused(.notOutstanding))
        }

        @Test func liveChangeRevokesBeforeUpdateReturns() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let issued = try await grant(authority)
            await authority.updateLive(try live(epoch: try nextEpoch()))
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(attempt(issued) == .refused(.staleLive))
            // Revocation is permanent, even once the live state is valid again.
            await authority.updateLive(try live())
            #expect(attempt(issued) == .refused(.staleLive))
        }

        @Test func leaseTransferAndDetachRevoke() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transferred = try await grant(authority)
            _ = try await authority.transfer(to: projectB, window: windowB).get()
            #expect(attempt(transferred) == .refused(.staleLease))
            _ = try await authority.transfer(to: projectA, window: windowA).get()

            _ = try await authority.attach(windowA2, project: projectA).get()
            let detached = try await grant(authority)
            let kept = try await grant(authority, window: windowA2)
            _ = try await authority.detach(windowA).get()
            #expect(await authority.outstandingDirectSendCount() == 1)
            #expect(attempt(detached) == .refused(.windowCannotWrite(.editAndPrepareOnly(heldBy: projectA))))
            #expect(attempt(kept) == .sent)
        }

        @Test func deliveredCommitRevokes() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await AuthorityBench.makeAuthority(&engine)
            let issued = try await grant(authority)
            _ = try await AuthorityBench.commitQueued(authority, &engine)
            // A queued commit changes no fence input.
            #expect(issued.isArmed)
            await engine.drain(authority)
            #expect(await authority.snapshot().inFlight[projectA] != nil)
            #expect(attempt(issued) == .refused(.commitInFlight))
        }

        /// `HostCommandGate.redeemRefusal` checks `.recovering` before the lease.
        @Test func leaseLossRevokes() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let issued = try await grant(authority)
            _ = try await authority.leaseLost(try await AuthorityBench.leaseToken(authority)).get()
            #expect(await authority.lifecycle(of: projectA, window: windowA) == .recovering)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(attempt(issued) == .refused(.recovering))
        }

        /// `.degraded` still accepts running-set changes and `redeemRefusal` has no
        /// capability check, so the fence is unchanged and the grant stays armed.
        @Test func capabilityLossKeepsTheGrant() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let issued = try await grant(authority)
            try await authority.capabilityLost(AuthorityBench.audio, project: projectA,
                                               token: try await AuthorityBench.leaseToken(authority)).get()
            #expect(await authority.lifecycle(of: projectA, window: windowA) == .degraded([AuthorityBench.audio]))
            #expect(await authority.outstandingDirectSendCount() == 1)
            #expect(attempt(issued) == .sent)
        }

        @Test func aRefusedTicketMintsNoGrant() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let stale = try await ticket(authority)
            await authority.updateLive(try live(epoch: try nextEpoch()))
            let before = await authority.snapshot()
            #expect(refusal(await authority.authorizeDirectSend(stale, targets: [target])) == .staleLive)
            #expect(await authority.snapshot() == before)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(await authority.outstandingDirectWriteCount() == 0)

            await authority.updateLive(try live())
            let redeemed = try await ticket(authority)
            let armed = try await authority.authorizeDirectSend(redeemed, targets: [target]).get()
            let after = await authority.snapshot()
            #expect(refusal(await authority.authorizeDirectSend(redeemed, targets: [target])) == .notOutstanding)
            #expect(await authority.snapshot() == after)
            #expect(await authority.outstandingDirectSendCount() == 1)
            #expect(armed.isArmed)
        }

        @Test func aThrowingSendStillConsumes() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let issued = try await grant(authority)
            #expect(throws: SendFailed()) { try issued.consume(target) { throw SendFailed() } }
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(attempt(issued) == .refused(.notOutstanding))
        }

        @Test func capacityPrunesSpentGrants() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            var grants: [DirectWriteAuthorization] = []
            for _ in 0..<HostAuthority.directSendCapacity { grants.append(try await grant(authority)) }
            #expect(await authority.outstandingDirectSendCount() == HostAuthority.directSendCapacity)
            // Spent grants no longer hold the cap.
            #expect(attempt(try #require(grants.first)) == .sent)
            #expect(attempt(try #require(grants.last)) == .sent)
            grants.append(try await grant(authority))
            grants.append(try await grant(authority))
            #expect(await authority.outstandingDirectSendCount() == HostAuthority.directSendCapacity)

            let refused = try await ticket(authority)
            #expect(await authority.outstandingDirectWriteCount() == 1)
            #expect(refusal(await authority.authorizeDirectSend(refused, targets: [target])) == .tooManyOutstanding)
            // Fails closed: the ticket is spent.
            #expect(await authority.outstandingDirectWriteCount() == 0)
            #expect(refusal(await authority.redeemDirect(refused)) == .notOutstanding)

            // Revoked grants no longer hold the cap either.
            await authority.updateLive(try live(epoch: try nextEpoch()))
            await authority.updateLive(try live())
            #expect(await authority.outstandingDirectSendCount() == 0)
            let fresh = try await grant(authority)
            #expect(await authority.outstandingDirectSendCount() == 1)
            #expect(attempt(fresh) == .sent)
        }

        /// A correct revocation blocks on the lock the running send holds. One-sided:
        /// `updateLive` cannot have returned 50 ms later, and whatever the
        /// scheduling, the body's exit is stamped before the update's return.
        @Test func anInFlightSendDelaysRevocation() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let held = try await grant(authority)
            let fresh = try await grant(authority)
            let entered = Flag(), release = Flag(), exited = Flag()
            let ticker = Ticker(), bodyExit = Stamp(), updateReturn = Stamp()
            defer { release.set() }
            Thread {
                try? held.consume(target) {
                    entered.set()
                    let limit = ContinuousClock.now + .seconds(10)
                    while !release.isSet, ContinuousClock.now < limit { Thread.sleep(forTimeInterval: 0.001) }
                    bodyExit.record(ticker)
                }
                exited.set()
            }.start()
            try #require(try await eventually { entered.isSet })

            let stale = try live(epoch: try nextEpoch())
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
            #expect(attempt(fresh) == .refused(.staleLive))
            #expect(try await eventually { exited.isSet })
        }
    }
}
