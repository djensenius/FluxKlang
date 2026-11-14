import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Action-set scope sweep and outcome round trip", .productionAccessAudit)
struct ActionSetSubmissionCancelTests {
    private typealias Harness = ActionSetSubmissionHarness
    private static let sceneKey = ActionSetSubmissionHarness.sceneKey
    private static let otherKey = ActionSetSubmissionHarness.otherKey

    /// Two sets share the scene scope, one uses another scope.
    private static func threeSets(_ harness: inout Harness) throws -> [ActionSetFireRecord] {
        let ids = harness.ids
        return try [
            harness.fire(harness.resolved([ids[0], ids[1]], set: "set.a"), "trg.a"),
            harness.fire(harness.resolved([ids[2]], set: "set.c", scope: ActionSetFixture.other), "trg.c"),
            harness.fire(harness.resolved([ids[3], ids[2]], set: "set.b"), "trg.b")
        ]
    }

    @Test
    func scopeCancelReturnsExactlyItsMembersHandlesOnce() throws {
        var harness = try Harness(members: 4)
        let records = try Self.threeSets(&harness)
        let handles = try harness.cancel(ActionSetFixture.scene)
        #expect(handles == records[0].handles + records[2].handles)
        #expect(harness.scheduler.pendingCount == 1 && harness.pending.count == 1)
        #expect(harness.pending.pending(in: ActionSetFixture.other) == records[1].handles.map(\.trigger))
        #expect(harness.fixture.ledger.generation(Self.sceneKey)?.value == 2)
        #expect(harness.fixture.ledger.generation(Self.otherKey)?.value == 1)
        let outcomes = harness.scheduler.drain()
        #expect(outcomes.map(\.handle) == handles)
        #expect(outcomes.allSatisfy {
            $0.outcome.result == .cancelled && $0.outcome.stale == .generation(Self.sceneKey)
        })
        #expect(harness.settle(outcomes).isEmpty)
        // Repeating is idempotent: it bumps again but cancels nothing.
        let before = try harness.snapshot()
        #expect(try harness.cancel(ActionSetFixture.scene).isEmpty)
        #expect(harness.fixture.ledger.generation(Self.sceneKey)?.value == 3)
        #expect(harness.scheduler.pendingCount == before.schedulerPending && harness.pending.count == 1)
        #expect(harness.scheduler.drain().isEmpty)
        #expect(try harness.cancel(ActionSetFixture.other) == records[1].handles)
        #expect(harness.scheduler.pendingCount == 0 && harness.pending.count == 0)
    }

    @Test
    func sweepCancelsOtherStaleWorkButReturnsOnlyTheScope() throws {
        var harness = try Harness(members: 2)
        let other = try harness.fire(harness.resolved([harness.ids[1]], set: "set.c", scope: ActionSetFixture.other),
                                     "trg.c")
        let scene = try harness.fire(harness.resolved([harness.ids[0]]), "trg.a")
        try harness.fixture.ledger.bump(ActionSetFixture.context, reason: .contextChange)
        let handles = try harness.cancel(ActionSetFixture.scene)
        #expect(handles == scene.handles)
        // The other scope's request was already stale; the sweep completes it too, in admission order.
        let outcomes = harness.scheduler.drain()
        #expect(outcomes.map(\.handle) == other.handles + scene.handles)
        #expect(outcomes.map(\.outcome.stale) == [.generation(ActionSetFixture.context),
                                                  .generation(ActionSetFixture.context)])
        #expect(harness.pending.count == 1)
        #expect(harness.settle(outcomes) == other.handles.map(\.trigger))
        #expect(harness.pending.count == 0)
    }

    @Test
    func cancelAfterAPartialCommitReturnsOnlyStillPendingMembers() throws {
        var harness = try Harness()
        try harness.observe()
        let record = try harness.fire(harness.resolved())
        let horizon = SampleStamp(clock: ActionSetFixture.primary, generation: .initial, frame: 480)
        try harness.scheduler.commit(record.handles[0], at: horizon, nominalRate: 48_000,
                                     ledger: harness.fixture.ledger, readiness: harness.fixture.readiness)
        let handles = try harness.cancel(ActionSetFixture.scene)
        #expect(handles == Array(record.handles.dropFirst()))
        let outcomes = harness.scheduler.drain()
        #expect(outcomes.map(\.outcome.result) == [.fired, .cancelled, .cancelled])
        #expect(harness.pending.count == 0)
        #expect(harness.settle(outcomes).isEmpty)
    }

    @Test
    func oldEpochResubmissionNeverBecomesAFreshPendingHandle() throws {
        var harness = try Harness()
        let resolved = try harness.resolved()
        let old = try harness.decide(resolved)
        _ = try harness.submit(old, of: resolved)
        #expect(try harness.cancel(ActionSetFixture.scene).count == 3)
        let outcomes = harness.scheduler.drain()
        harness.settle(outcomes)
        let before = try harness.snapshot()
        let stale = Harness.refusal { () throws(ActionSetSubmitRefusal) in try harness.submit(old, of: resolved) }
        guard case .staleRequirement(index: 0, Self.sceneKey) = stale else {
            Issue.record("Expected staleRequirement(0, scene), got \(String(describing: stale))")
            return
        }
        #expect(try harness.snapshot() == before)
        // Re-deciding under the old trigger IDs is still refused by the scheduler's session identity.
        let reused = try harness.decide(resolved)
        let duplicate = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try harness.submit(reused, of: resolved)
        }
        guard case .scheduler(index: 0, let error) = duplicate else {
            Issue.record("Expected scheduler(0), got \(String(describing: duplicate))")
            return
        }
        #expect(error as? TriggerSessionError == .duplicateID)
        #expect(try harness.snapshot() == before)
        let fresh = try harness.fire(resolved, "trg.again")
        #expect(fresh.cancelScope.generation.value == 2 && harness.scheduler.pendingCount == 3)
    }

    @Test
    func refusedCancelChangesNothing() throws {
        var harness = try Harness(scopes: [ActionSetFixture.scene])
        _ = try harness.fire(harness.resolved())
        let before = try harness.snapshot()
        let refusal = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try harness.cancel(ActionSetFixture.other)
        }
        guard case .cancel(.cancelFailed(.undeclaredCounter(Self.otherKey))) = refusal else {
            Issue.record("Expected cancel(cancelFailed), got \(String(describing: refusal))")
            return
        }
        #expect(refusal?.memberIndex == nil && refusal?.underlyingError == nil)
        #expect(try harness.snapshot() == before)
    }

    @Test
    func commitAndDrainYieldAnOutcomeForEveryMemberInMemberOrder() throws {
        var harness = try Harness(members: 4)
        try harness.observe()
        let record = try harness.fire(harness.resolved(Array(harness.ids.reversed())))
        let horizon = SampleStamp(clock: ActionSetFixture.primary, generation: .initial, frame: 480)
        for handle in record.handles {
            try harness.scheduler.commit(handle, at: horizon, nominalRate: 48_000, ledger: harness.fixture.ledger,
                                         readiness: harness.fixture.readiness)
        }
        let outcomes = harness.scheduler.drain()
        #expect(outcomes.map(\.handle) == record.handles)
        #expect(outcomes.allSatisfy { $0.outcome.result == .fired && $0.outcome.frame == 480 })
        let settled = harness.settle(outcomes)
        #expect(settled == record.handles.map(\.trigger))
        #expect(harness.pending.count == 0 && harness.scheduler.pendingCount == 0)
        #expect(harness.scheduler.reservedOutcomeCount == 0)
        #expect(harness.settle(outcomes).isEmpty)
    }

    /// Settle matches the full handle: a late outcome from before a session rotation never removes the
    /// refired trigger's live entry, so the next scope cancel still returns the live handle.
    @Test
    func lateSettleFromARotatedSessionKeepsTheRefiredEntry() throws {
        var harness = try Harness(members: 1)
        try harness.observe()
        let resolved = try harness.resolved()
        let first = try harness.fire(resolved)
        let horizon = SampleStamp(clock: ActionSetFixture.primary, generation: .initial, frame: 480)
        try harness.scheduler.commit(first.handles[0], at: horizon, nominalRate: 48_000,
                                     ledger: harness.fixture.ledger, readiness: harness.fixture.readiness)
        let late = harness.scheduler.drain()
        #expect(late.map(\.handle) == first.handles && late.map(\.outcome.result) == [.fired])
        // Not settled: the cancel forgets the scope's entry, then the session goes quiescent and rotates.
        #expect(try harness.cancel(ActionSetFixture.scene).isEmpty)
        #expect(harness.pending.count == 0)
        #expect(harness.scheduler.drain().isEmpty)
        let oldSession = harness.scheduler.currentToken
        _ = try harness.scheduler.rotateSession(expected: oldSession)
        let refired = try harness.fire(resolved)
        #expect(refired.handles.map(\.trigger) == first.handles.map(\.trigger) && refired.handles != first.handles)
        #expect(harness.settle(late).isEmpty)
        #expect(harness.pending.pending(in: ActionSetFixture.scene) == refired.handles.map(\.trigger))
        #expect(try harness.cancel(ActionSetFixture.scene) == refired.handles)
        #expect(harness.pending.count == 0)
    }

    /// Drain, settle, then rotate through the submitter; rotating with an unsettled entry is refused.
    @Test
    func rotationWaitsForSettleThenTheSameSetRefires() throws {
        var harness = try Harness(members: 1)
        try harness.observe()
        let resolved = try harness.resolved()
        let first = try harness.fire(resolved)
        let token = harness.scheduler.currentToken
        // The registry is checked first: with the member still pending in the scheduler (not quiescent)...
        try Self.expectNotSettled(&harness, expected: token)
        let horizon = SampleStamp(clock: ActionSetFixture.primary, generation: .initial, frame: 480)
        try harness.scheduler.commit(first.handles[0], at: horizon, nominalRate: 48_000,
                                     ledger: harness.fixture.ledger, readiness: harness.fixture.readiness)
        // ...and before the drain with a token that is not current (another scheduler's), it is not settled.
        try Self.expectNotSettled(&harness, expected: Harness(members: 1).scheduler.currentToken)
        let outcomes = harness.scheduler.drain()
        // (a) The scheduler is quiescent but the registry is not: refused, nothing changes.
        let before = try harness.snapshot()
        let refusal = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try ActionSetSubmitter.rotateSession(expected: token, scheduler: &harness.scheduler,
                                                 pending: harness.pending)
        }
        guard case .pendingNotSettled(count: 1) = refusal else {
            Issue.record("Expected pendingNotSettled(1), got \(String(describing: refusal))")
            return
        }
        #expect(refusal?.memberIndex == nil && refusal?.underlyingError == nil)
        #expect(try harness.snapshot() == before)
        // (c) A raw scheduler rotation skips the old session's outcomes and leaves the entry behind.
        var raw = harness
        _ = try raw.scheduler.rotateSession(expected: token)
        #expect(raw.settle(outcomes).isEmpty && raw.pending.count == 1)
        let request = try ActionSetFixture.request()
        let blocked = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try ActionSetSubmitter.fire(resolved, request: request, context: raw.submitContext,
                                        scheduler: &raw.scheduler, pending: &raw.pending)
        }
        guard case .registry(index: 0, .duplicatePending(first.handles[0].trigger)) = blocked else {
            Issue.record("Expected registry(0, duplicatePending), got \(String(describing: blocked))")
            return
        }
        // (b) Settle, then rotate: the same set refires under the same trigger IDs.
        #expect(harness.settle(outcomes) == first.handles.map(\.trigger))
        let next = try ActionSetSubmitter.rotateSession(expected: token, scheduler: &harness.scheduler,
                                                        pending: harness.pending)
        #expect(next != token && harness.scheduler.currentToken == next)
        // The scheduler's own refusal (here a stale token) is kept as thrown.
        let stale = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try ActionSetSubmitter.rotateSession(expected: token, scheduler: &harness.scheduler,
                                                 pending: harness.pending)
        }
        guard case .rotation(let error) = stale else {
            Issue.record("Expected rotation(staleSession), got \(String(describing: stale))")
            return
        }
        #expect(error as? TriggerSessionError == .staleSession && stale?.memberIndex == nil)
        #expect(stale?.underlyingError as? TriggerSessionError == .staleSession)
        #expect(harness.scheduler.currentToken == next)
        let refired = try harness.fire(resolved)
        #expect(refired.handles.map(\.trigger) == first.handles.map(\.trigger) && refired.handles != first.handles)
        #expect(harness.pending.pending(in: ActionSetFixture.scene) == refired.handles.map(\.trigger))
    }

    /// Rotating through the submitter with one unsettled entry is `.pendingNotSettled(count: 1)` and changes
    /// nothing, whatever the scheduler's own token and quiescence checks would say.
    private static func expectNotSettled(_ harness: inout Harness, expected: TriggerSessionToken,
                                         sourceLocation: SourceLocation = #_sourceLocation) throws {
        let before = try harness.snapshot()
        let refusal = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try ActionSetSubmitter.rotateSession(expected: expected, scheduler: &harness.scheduler,
                                                 pending: harness.pending)
        }
        guard case .pendingNotSettled(count: 1) = refusal else {
            Issue.record("Expected pendingNotSettled(1), got \(String(describing: refusal))",
                         sourceLocation: sourceLocation)
            return
        }
        #expect(try harness.snapshot() == before, sourceLocation: sourceLocation)
    }
}
