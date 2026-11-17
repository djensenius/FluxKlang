import Observation
import Testing
@testable import FluxKlang

private typealias Gestures = HostUserPermissionOwner

extension HostAuthorityTests {
    @MainActor
    struct PermissionGestureRaces {
        @Test func synchronousBusyWillSetMustNotAdmitAnotherGesture() async throws {
            let owner = try await OwnerBench.owner(granted: false)
            _ = await owner.opened.value
            let facade = Gestures(owner: owner)
            let callback = PermissionObservationCapture()
            withObservationTracking {
                _ = facade.isBusy
            } onChange: {
                MainActor.assumeIsolated {
                    callback.resubmitOnce(.grant, on: facade)
                }
            }
            let outer = facade.submit(.grant)
            #expect(callback.invocations == 1, "The callback ran synchronously on MainActor")
            #expect(callback.refused, "A synchronous busy willSet callback must be refused")
            #expect(callback.accepted.isEmpty, "No nested work may be accepted")
            if case .accepted(let completion) = outer {
                _ = await completion.value
            } else {
                Issue.record("The original explicit gesture was refused")
            }
            for completion in callback.accepted { _ = await completion.value }
            let revision = await owner.grantRevision
            #expect(revision == 1, "Exactly one explicit operation may be admitted")
            #expect(!facade.isBusy)
        }

        @Test func consumersShareBusyAndAcceptedWorkSurvivesRecreation() async throws {
            let pause = PermissionGesturePause(permissionPresent: true)
            let owner = try HostAuthorityOwner(publicationCheckpoint: { await pause.visit($0) })
            let facade = Gestures(owner: owner)
            var initiating: StudioHostPermissionView? = StudioHostPermissionView(owner: facade)
            let second = StudioHostPermissionView(owner: facade)
            var unexpected: [Gestures.Completion] = []
            let submission = initiating?.owner.submit(.grant)
            guard case .accepted(let completion) = submission else {
                Issue.record("Initial grant refused")
                return
            }
            #expect(facade.isBusy, "Busy must be reserved synchronously")
            expectBusy(second.owner.submit(.grant), pending: &unexpected)
            initiating = nil
            let recreated = StudioHostPermissionView(owner: facade)
            let joined = Task {
                let report = await completion.value
                await pause.finished()
                return report
            }
            for expected in [PermissionGesturePause.Event.captured, .published] {
                #expect(await pause.next() == expected)
                #expect(recreated.owner.isBusy)
                #expect(recreated.owner.report == nil)
                expectBusy(recreated.owner.submit(.revoke), pending: &unexpected)
                expectBusy(second.owner.submit(.grant), pending: &unexpected)
                #expect(await owner.grantRevision == 1)
                await pause.resume()
            }
            await pause.releaseAll()
            let report = await joined.value
            for completion in unexpected { _ = await completion.value }
            #expect(report == .init(outcome: .granted, lastChecked: .present))
            #expect(facade.report == report && !facade.isBusy)
            #expect(await owner.grantRevision == 1)
            #expect(await owner.authority.snapshot().live.permission != nil)
        }

        @Test func revokeRemainsBusyUntilCanonicalPublicationCompletes() async throws {
            let pause = PermissionGesturePause(permissionPresent: false)
            let owner = try HostAuthorityOwner(publicationCheckpoint: { await pause.visit($0) })
            _ = try await owner.grant(.host).get()
            let facade = Gestures(owner: owner)
            var unexpected: [Gestures.Completion] = []
            guard case .accepted(let completion) = facade.submit(.revoke) else {
                Issue.record("Initial revoke refused")
                return
            }
            let joined = Task {
                let report = await completion.value
                await pause.finished()
                return report
            }
            #expect(await pause.next() == .captured)
            #expect(await owner.authority.snapshot().live.permission != nil)
            #expect(facade.isBusy && facade.report == nil)
            expectBusy(facade.submit(.grant), pending: &unexpected)
            await pause.resume()
            #expect(await pause.next() == .published)
            #expect(await owner.authority.snapshot().live.permission == nil)
            #expect(facade.isBusy && facade.report == nil)
            expectBusy(facade.submit(.revoke), pending: &unexpected)
            await pause.releaseAll()
            #expect(await joined.value == .init(outcome: .revoked, lastChecked: .absent))
            for completion in unexpected { _ = await completion.value }
            #expect(!facade.isBusy && facade.report?.outcome == .revoked)
            #expect(await owner.grantRevision == 1)
        }

        @Test func delayedGrantReportsCanonicalObservationNotReturnedFingerprint() async throws {
            let pause = PermissionGesturePause(permissionPresent: true)
            let owner = try HostAuthorityOwner(publicationCheckpoint: { await pause.visit($0) })
            let facade = Gestures(owner: owner)
            guard case .accepted(let completion) = facade.submit(.grant) else {
                Issue.record("Initial grant refused")
                return
            }
            let joined = Task {
                let report = await completion.value
                await pause.finished()
                return report
            }
            #expect(await pause.next() == .captured)
            await pause.resume()
            #expect(await pause.next() == .published)
            let revoke = Task {
                await owner.revoke()
                await pause.finished()
            }
            #expect(await pause.next() == .joining)
            #expect(facade.isBusy)
            await pause.releaseAll()
            let report = await joined.value
            await revoke.value
            #expect(report == .init(outcome: .granted, lastChecked: .absent))
            #expect(facade.report == report && !facade.isBusy)
            #expect(await owner.authority.snapshot().live.permission == nil)
            #expect(await owner.grantRevision == 1)
        }

        private func expectBusy(_ submission: Gestures.Submission, pending: inout [Gestures.Completion]) {
            if case .accepted(let completion) = submission {
                Issue.record("Competing gesture was accepted, not refused")
                // Mutation cleanup: even erroneously accepted work must be joined.
                pending.append(completion)
            }
        }
    }
}

/// Failure-only watchdog releases controlled continuations; success ordering uses events, never sleeps.
private actor PermissionGesturePause {
    enum Event { case captured, published, joining, finished }
    private let events = AsyncStream<Event>.makeStream()
    private let permissionPresent: Bool
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(permissionPresent: Bool) { self.permissionPresent = permissionPresent }

    func visit(_ point: HostAuthorityOwner.PublicationCheckpoint) async {
        guard !released else { return }
        switch point {
        case .captured(let permission) where (permission != nil) == permissionPresent:
            await suspend(at: .captured)
        case .published(let permission) where (permission != nil) == permissionPresent:
            await suspend(at: .published)
        case .joining: events.continuation.yield(.joining)
        default: break
        }
    }

    private func suspend(at event: Event) async {
        await withCheckedContinuation {
            continuations.append($0)
            events.continuation.yield(event)
        }
    }

    func next() async -> Event? {
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            Issue.record("Timed out waiting for permission event; releasing publication pauses")
            releaseAll()
            events.continuation.finish()
        }
        var iterator = events.stream.makeAsyncIterator()
        let event = await iterator.next()
        watchdog.cancel()
        await watchdog.value
        return event
    }

    func finished() { events.continuation.yield(.finished) }

    func resume() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func releaseAll() {
        released = true
        resume()
    }
}
