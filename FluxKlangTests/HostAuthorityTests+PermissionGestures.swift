import Foundation
import Observation
import Testing
@testable import FluxKlang

private typealias Owner = OwnerBench
private typealias Gestures = HostUserPermissionOwner

extension HostAuthorityTests {
    @MainActor
    struct PermissionGestures {
        @Test(arguments: [PermissionObservationTransition.report, .idle])
        fileprivate func completionNotificationsDoNotAdmitAnotherGesture(
            _ transition: PermissionObservationTransition
        ) async throws {
            let owner = try await Owner.owner(granted: false)
            _ = await owner.opened.value
            let facade = Gestures(owner: owner)
            let callback = PermissionObservationCapture()
            guard case .accepted(let completion) = facade.submit(.grant) else {
                Issue.record("Initial grant refused")
                return
            }
            withObservationTracking {
                switch transition {
                case .report: _ = facade.report
                case .idle: _ = facade.isBusy
                }
            } onChange: {
                MainActor.assumeIsolated {
                    callback.resubmitOnce(.revoke, on: facade)
                }
            }
            let report = await completion.value
            for completion in callback.accepted { _ = await completion.value }
            #expect(callback.invocations == 1)
            #expect(callback.refused, "Admission remains reserved during completion notifications")
            #expect(callback.accepted.isEmpty)
            #expect(report == .init(outcome: .granted, lastChecked: .present))
            #expect(facade.report == report && !facade.isBusy)
            #expect(await owner.grantRevision == 1)
            #expect(await owner.authority.snapshot().live.permission != nil)
        }

        @Test func constructionAndConsumerRecreationDoNothing() async throws {
            let owner = try await Owner.owner(granted: false)
            _ = await owner.opened.value
            let before = await owner.authority.snapshot()
            let facade = Gestures(owner: owner)
            for _ in 0..<3 {
                let consumer = StudioHostPermissionView(owner: facade)
                #expect(consumer.owner === facade)
                #expect(consumer.owner.report == nil && !consumer.owner.isBusy)
            }
            #expect(Gestures.shared === Gestures.shared)
            #expect(await owner.grantRevision == 0)
            #expect(await owner.permission == nil)
            #expect(await owner.session == nil)
            let after = await owner.authority.snapshot()
            #expect(after == before)
            #expect(after.lease == nil && after.queue.isEmpty)
            #expect(AuthorityBench.context(after) == AuthorityBench.context(before))
            #expect(await owner.authority.nextEngineCommand() == nil)
        }

        @Test func explicitGrantChangesOnlyPermissionAndCannotRender() async throws {
            let owner = try await Owner.owner(granted: false)
            _ = await owner.opened.value
            let facade = Gestures(owner: owner)
            let before = await owner.authority.snapshot()
            let report = try await finish(facade.submit(.grant))
            #expect(report == .init(outcome: .granted, lastChecked: .present))
            #expect(facade.report == report && !facade.isBusy)
            #expect(await owner.grantRevision == 1)
            let after = await owner.authority.snapshot()
            #expect(after.live.permission != nil)
            #expect(after.live.hostEpoch == before.live.hostEpoch)
            #expect(after.live.capabilities == before.live.capabilities)
            #expect(after.projects == before.projects && after.ledger == before.ledger)
            #expect(after.lease == nil && after.queue.isEmpty)
            #expect(AuthorityBench.context(after) == AuthorityBench.context(before))
            #expect(await owner.session == nil)
            #expect(await owner.authority.nextEngineCommand() == nil)
            #expect(Owner.refusal(try await Owner.admit(owner, Owner.windowOne)) == .windowCannotWrite(.stopped))
            #expect(await owner.beginApply(window: Owner.windowOne) == .failure(.noSession))
            await owner.connected(session: UUID())
            _ = try await owner.beginApply(window: Owner.windowOne).get()
            let other = try await Owner.admit(owner, Owner.windowTwo)
            #expect(Owner.refusal(other) == .gate(.unavailable(.heldByOther(owner.studio))))
            let ticket = try await Owner.ticket(owner, Owner.windowOne)
            #expect(Owner.refusal(await owner.authority.redeemDirect(ticket)) == nil)
        }

        @Test func revokeRepeatAndRegrantPreserveIdentityAndStaleTickets() async throws {
            let owner = try await Owner.applying(granted: false)
            let facade = Gestures(owner: owner)
            _ = try await finish(facade.submit(.grant))
            let first = await owner.permission
            let old = try await Owner.ticket(owner, Owner.windowOne)
            let before = await owner.authority.snapshot()
            let session = await owner.session
            for _ in 0..<2 {
                let report = try await finish(facade.submit(.revoke))
                #expect(report == .init(outcome: .revoked, lastChecked: .absent))
                #expect(await owner.authority.snapshot().live.permission == nil)
                #expect(await owner.grantRevision == 1)
            }
            _ = try await finish(facade.submit(.grant))
            #expect(await owner.grantRevision == 2)
            #expect(await owner.permission != first)
            let after = await owner.authority.snapshot()
            #expect(after.live.hostEpoch == before.live.hostEpoch)
            #expect(after.lease == before.lease)
            #expect(after.projects == before.projects && after.ledger == before.ledger)
            #expect(AuthorityBench.context(after) == AuthorityBench.context(before))
            #expect(await owner.session == session)
            #expect(Owner.refusal(await owner.authority.redeemDirect(old)) == .staleLive)
            let fresh = try await Owner.ticket(owner, Owner.windowOne)
            #expect(Owner.refusal(await owner.authority.redeemDirect(fresh)) == nil)
        }

        @Test func historicalPresenceCannotAuthorizeAndAbsenceCannotBlock() async throws {
            let owner = try await Owner.applying(granted: false)
            let facade = Gestures(owner: owner)
            _ = try await finish(facade.submit(.grant))
            let old = try await Owner.ticket(owner, Owner.windowOne)
            let settings = try WingApplyBench.settings(3)
            let minter = WingApplyGrantMinter(
                authority: owner.authority, project: owner.studio, window: Owner.windowOne,
                budget: WingApplyTicketBudget(limit: 2), provider: owner.provider
            )
            await owner.revoke()
            #expect(facade.report?.lastChecked == .present)
            #expect(Owner.refusal(await owner.authority.redeemDirect(old)) == .staleLive)
            #expect(Owner.refusal(await minter.grant(for: .remaining, targets: WingApplyBench.targets(settings)))
                    == .gate(.refused(.rejected(.permissionDenied))))
            _ = try await finish(facade.submit(.revoke))
            _ = try await owner.grant(.host).get()
            #expect(facade.report?.lastChecked == .absent)
            let fresh = await minter.grant(for: .remaining, targets: WingApplyBench.targets(settings))
            #expect(Owner.refusal(fresh) == nil)
            _ = try await finish(facade.submit(.grant))
            #expect(facade.report?.lastChecked == .present)
            // Presence does not disable explicit regrant either.
            _ = try await finish(facade.submit(.grant))
            #expect(await owner.grantRevision == 4)
        }

        @Test func exhaustionPreservesGrantedAndRevokedState() async throws {
            let owner = try HostAuthorityOwner(host: Owner.host, resumingGrantsAfter: .max - 1)
            _ = await owner.opened.value
            let facade = Gestures(owner: owner)
            _ = try await finish(facade.submit(.grant))
            for presence in [Gestures.Presence.present, .absent] {
                let before = await owner.authority.snapshot()
                let report = try await finish(facade.submit(.grant))
                #expect(report == .init(outcome: .revisionExhausted, lastChecked: presence))
                #expect(!facade.isBusy && facade.report == report)
                let after = await owner.authority.snapshot()
                #expect(after == before)
                #expect(AuthorityBench.context(after) == AuthorityBench.context(before))
                #expect(await owner.grantRevision == .max)
                _ = try await finish(facade.submit(.revoke))
            }
        }

        private func finish(_ submission: Gestures.Submission) async throws -> Gestures.Report {
            guard case .accepted(let completion) = submission else {
                throw PermissionGestureFailure.busy
            }
            return await completion.value
        }
    }
}

private enum PermissionGestureFailure: Error { case busy }

private enum PermissionObservationTransition: Sendable { case report, idle }

@MainActor
final class PermissionObservationCapture {
    var invocations = 0
    var refused = false
    var accepted: [HostUserPermissionOwner.Completion] = []

    func resubmitOnce(_ gesture: HostUserPermissionOwner.Gesture, on facade: HostUserPermissionOwner) {
        guard invocations == 0 else { return }
        invocations += 1
        switch facade.submit(gesture) {
        case .busy: refused = true
        case .accepted(let completion): accepted.append(completion)
        }
    }
}
