import Foundation
import Synchronization
import Testing
@testable import FluxKlang

private let inside = DirectSendTarget("target.in")
private let outside = DirectSendTarget("target.out")

/// Admits only `admitted`, under any scope.
private struct AdmitOnly: DirectSendScopePolicy {
    let admitted: Set<DirectSendTarget>

    func admits(_ target: DirectSendTarget, under scope: CommandScope) -> Bool { admitted.contains(target) }
}

/// Admits every target and records each question it is asked.
private final class RecordingScope: DirectSendScopePolicy {
    struct Question: Hashable {
        let target: DirectSendTarget
        let scope: CommandScope
    }

    private let asked = Mutex<[Question]>([])

    var questions: [Question] { asked.withLock { $0 } }

    func admits(_ target: DirectSendTarget, under scope: CommandScope) -> Bool {
        asked.withLock { $0.append(Question(target: target, scope: scope)) }
        return true
    }
}

private func scoped() async throws -> HostAuthority {
    try await AuthorityBench.makeAuthority(sendScope: AdmitOnly(admitted: [inside]))
}

private func staleLive() throws -> HostLiveState {
    try AuthorityBench.liveState(epoch: try DirectSendBench.nextEpoch())
}

extension HostAuthorityTests {
    /// AU5: `authorizeDirectSend` mints a grant only if the authority's
    /// `DirectSendScopePolicy` admits every target under the ticket's scope. The
    /// check follows the redeem and binding checks and precedes capacity; the
    /// ticket is always spent.
    struct DirectSendScope {
        @Test func aTargetOutsideTheScopeIsRefusedAndSpendsTheTicket() async throws {
            let authority = try await scoped()
            let held = try await DirectSendBench.grant(authority, targets: [inside])
            let ticket = try await DirectSendBench.ticket(authority)
            let before = await authority.snapshot()
            let result = await authority.authorizeDirectSend(ticket, targets: [inside, outside])
            #expect(DirectSendBench.refusal(result) == .outOfScope)
            #expect(await authority.snapshot() == before)
            #expect(await authority.outstandingDirectWriteCount() == 0)
            #expect(await authority.outstandingDirectSendCount() == 1)
            #expect(DirectSendBench.refusal(await authority.redeemDirect(ticket)) == .notOutstanding)
            #expect(held.isArmed)

            let reversed = try await DirectSendBench.ticket(authority)
            #expect(DirectSendBench.refusal(await authority.authorizeDirectSend(reversed, targets: [outside, inside]))
                == .outOfScope)
            #expect(await authority.outstandingDirectSendCount() == 1)
        }

        @Test func anInvalidBindingIsReportedBeforeScope() async throws {
            let authority = try await scoped()
            let ticket = try await DirectSendBench.ticket(authority)
            #expect(DirectSendBench.refusal(await authority.authorizeDirectSend(ticket, targets: [outside, outside]))
                == .invalidBinding)
            #expect(DirectSendBench.refusal(await authority.redeemDirect(ticket)) == .notOutstanding)
            #expect(await authority.outstandingDirectSendCount() == 0)
        }

        /// Scope precedes capacity: at capacity, an out-of-scope binding is
        /// `.outOfScope`, the ticket is spent, and the held grants stay armed.
        @Test func anOutOfScopeBindingAtCapacityIsOutOfScopeNotFull() async throws {
            let authority = try await scoped()
            var grants: [DirectWriteAuthorization] = []
            for _ in 0..<HostAuthority.directSendCapacity {
                grants.append(try await DirectSendBench.grant(authority, targets: [inside]))
            }
            let ticket = try await DirectSendBench.ticket(authority)
            #expect(DirectSendBench.refusal(await authority.authorizeDirectSend(ticket, targets: [outside]))
                == .outOfScope)
            #expect(DirectSendBench.refusal(await authority.redeemDirect(ticket)) == .notOutstanding)
            #expect(await authority.outstandingDirectSendCount() == HostAuthority.directSendCapacity)
            #expect(grants.allSatisfy { $0.isArmed })
        }

        @Test func aStaleTicketIsRefusedBeforeScope() async throws {
            let authority = try await scoped()
            let ticket = try await DirectSendBench.ticket(authority)
            await authority.updateLive(try staleLive())
            #expect(DirectSendBench.refusal(await authority.authorizeDirectSend(ticket, targets: [outside]))
                == .staleLive)
            #expect(DirectSendBench.refusal(await authority.redeemDirect(ticket)) == .notOutstanding)
        }

        /// An authority built without `sendScope` mints no grant, for any target.
        @Test func theDefaultPolicyRefusesEveryTarget() async throws {
            let ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.main"), musicalClock: nil,
                                              nominalRate: 48_000)
            let authority = try HostAuthority(host: ledger, live: try AuthorityBench.liveState())
            try await authority.open(project: AuthorityBench.projectA,
                                     running: RunningGraph(revision: .initial, prepared: nil)).get()
            _ = try await authority.acquire(project: AuthorityBench.projectA, window: AuthorityBench.windowA).get()

            let targets = [inside, DirectSendTarget(WingAddress.mute(.channel, 1)),
                           DirectSendTarget(WingAddress.fader(.channel, 1))]
            let parameters = [DirectSendBench.liveParameter, ParameterCatalog.wingMute,
                              ParameterCatalog.wingFaderDecibels]
            for parameter in parameters {
                for target in targets {
                    let ticket = try await DirectSendBench.ticket(authority, parameter: parameter)
                    #expect(DirectSendBench.refusal(await authority.authorizeDirectSend(ticket, targets: [target]))
                        == .outOfScope)
                }
            }
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(await authority.outstandingDirectWriteCount() == 0)
        }

        @Test func thePolicySeesTheTicketScope() async throws {
            let recorder = RecordingScope()
            let authority = try await AuthorityBench.makeAuthority(sendScope: recorder)
            let targets = [inside, outside, DirectSendTarget("target.third")]
            _ = try await DirectSendBench.grant(authority, targets: targets)
            let live = CommandScope.parameter(DirectSendBench.liveParameter)
            #expect(recorder.questions.count == targets.count)
            #expect(Set(recorder.questions) == Set(targets.map { RecordingScope.Question(target: $0, scope: live) }))

            _ = try await DirectSendBench.grant(authority, targets: [inside], parameter: ParameterCatalog.wingMute)
            #expect(recorder.questions.last == RecordingScope.Question(
                target: inside, scope: .parameter(ParameterCatalog.wingMute)))
            #expect(recorder.questions.count == targets.count + 1)
        }
    }
}
