import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Action-set scope sweep and outcome round trip")
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
        #expect(ActionSetSubmitter.settle(outcomes, pending: &harness.pending).isEmpty)
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
        #expect(ActionSetSubmitter.settle(outcomes, pending: &harness.pending) == other.handles.map(\.trigger))
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
        #expect(ActionSetSubmitter.settle(outcomes, pending: &harness.pending).isEmpty)
    }

    @Test
    func oldEpochResubmissionNeverBecomesAFreshPendingHandle() throws {
        var harness = try Harness()
        let resolved = try harness.resolved()
        let old = try harness.decide(resolved)
        _ = try harness.submit(old, of: resolved.set)
        #expect(try harness.cancel(ActionSetFixture.scene).count == 3)
        let outcomes = harness.scheduler.drain()
        ActionSetSubmitter.settle(outcomes, pending: &harness.pending)
        let before = try harness.snapshot()
        let stale = Harness.refusal { () throws(ActionSetSubmitRefusal) in try harness.submit(old, of: resolved.set) }
        guard case .staleRequirement(index: 0, Self.sceneKey) = stale else {
            Issue.record("Expected staleRequirement(0, scene), got \(String(describing: stale))")
            return
        }
        #expect(try harness.snapshot() == before)
        // Re-deciding under the old trigger IDs is still refused by the scheduler's session identity.
        let reused = try harness.decide(resolved)
        let duplicate = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try harness.submit(reused, of: resolved.set)
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
        let settled = ActionSetSubmitter.settle(outcomes, pending: &harness.pending)
        #expect(settled == record.handles.map(\.trigger))
        #expect(harness.pending.count == 0 && harness.scheduler.pendingCount == 0)
        #expect(harness.scheduler.reservedOutcomeCount == 0)
        #expect(ActionSetSubmitter.settle(outcomes, pending: &harness.pending).isEmpty)
    }
}
