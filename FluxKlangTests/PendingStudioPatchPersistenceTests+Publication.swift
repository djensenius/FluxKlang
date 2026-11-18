import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// A load publishes only while it is still this coordinator's latest storage attempt.
extension PendingStudioPatchPersistenceTests {
    @Test func supersededLoadDoesNotUndoDiscard() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            _ = await fixture.owner.perform(.openReview, context: fixture.context)
            let gate = await fixture.forwarding.hold(.afterLoad(1))
            let load = fixture.start { await fixture.owner.load() }
            try #require(await gate.waitForEntry())
            let read = try fixture.attempt()
            await fixture.owner.discardPendingStudioDraft()
            let deletion = try fixture.attempt()
            #expect(deletion.observation == .mutation(snapshot: nil, outcome: .deleteCompleted))
            await gate.release()
            await load.value
            #expect(read.observation == .load(.loaded(built)))
            #expect(fixture.owner.latestStorageAttempt === deletion)
            #expect(fixture.owner.pendingStudioDraft == nil)
            #expect(fixture.owner.navigationTarget == nil)
            #expect(await fixture.store.load() == .absent)
            #expect(await fixture.forwarding.snapshots == [built, nil])
        }
    }

    @Test func supersededLoadDoesNotOverwriteNewerLoad() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let gate = await fixture.forwarding.hold(.afterLoad(1))
            let first = fixture.start { await fixture.owner.load() }
            try #require(await gate.waitForEntry())
            let older = try fixture.attempt()
            #expect(await fixture.store.save(nil) == .deleteCompleted)
            await fixture.owner.load()
            let newer = try fixture.attempt()
            #expect(newer !== older)
            #expect(newer.observation == .load(.absent))
            #expect(fixture.owner.pendingStudioDraft == nil)
            await gate.release()
            await first.value
            #expect(older.observation == .load(.loaded(built)))
            #expect(fixture.owner.latestStorageAttempt === newer)
            #expect(fixture.owner.pendingStudioDraft == nil)
            #expect(await fixture.forwarding.snapshots == [built])
        }
    }

    @Test func supersededLoadKeepsNewerSettledDraftForRestoration() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let readGate = await fixture.forwarding.hold(.afterLoad(1))
            let load = fixture.start { await fixture.owner.load() }
            try #require(await readGate.waitForEntry())
            let read = try fixture.attempt()
            let newer = fixture.draft(1)
            #expect(await fixture.commit(newer))
            var third = fixture.draft()
            try #require(!third.fragment.nodes.isEmpty)
            third.fragment.nodes[0].node.position.x += 40
            try #require(third != built && third != newer)
            let saveGate = await fixture.forwarding.hold(.afterSave(3))
            let commit = fixture.start { await fixture.commit(third) }
            try #require(await saveGate.waitForEntry())
            let mutation = try fixture.attempt()
            await readGate.release()
            await load.value
            #expect(read.observation == .load(.loaded(built)))
            #expect(fixture.owner.latestStorageAttempt === mutation)
            #expect(fixture.owner.pendingStudioDraft == third)
            commit.cancel()
            await saveGate.release()
            #expect(await commit.value == false)
            #expect(mutation.observation == .mutation(snapshot: third, outcome: .writeCompleted))
            #expect(fixture.owner.pendingStudioDraft == newer)
            #expect(try fixture.attempt().observation == .mutation(snapshot: newer, outcome: .writeCompleted))
            #expect(await fixture.forwarding.snapshots == [built, newer, third, newer])
            #expect(await fixture.store.load() == .loaded(newer))
            // The first rollback was captured before the stale load; this one reads the retained settled draft.
            let nextGate = await fixture.forwarding.hold(.afterSave(5))
            let next = fixture.start { await fixture.commit(third) }
            try #require(await nextGate.waitForEntry())
            next.cancel()
            await nextGate.release()
            #expect(await next.value == false)
            #expect(fixture.owner.pendingStudioDraft == newer, "second restoration uses retained settled draft")
            #expect(await fixture.forwarding.snapshots == [built, newer, third, newer, third, newer])
        }
    }
}

// A load that starts while any pending-draft mutation is in flight records its read but never publishes.
extension PendingStudioPatchPersistenceTests {
    @Test func loadDuringCommitDoesNotLoseCommit() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let newer = fixture.draft(1)
            let gate = await fixture.forwarding.hold(.beforeSave(2))
            let commit = fixture.start { await fixture.commit(newer) }
            try #require(await gate.waitForEntry())
            await fixture.owner.load()
            let read = try fixture.attempt()
            #expect(read.observation == .load(.loaded(built)))
            #expect(fixture.owner.pendingStudioDraft == newer)
            await gate.release()
            #expect(await commit.value)
            #expect(fixture.owner.latestStorageAttempt === read)
            #expect(fixture.owner.pendingStudioDraft == newer)
            #expect(await fixture.store.load() == .loaded(newer))
            #expect(await fixture.forwarding.snapshots == [built, newer])
        }
    }

    @Test func loadDuringDiscardDoesNotResurrectDraft() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let gate = await fixture.forwarding.hold(.beforeSave(2))
            let discard = fixture.start { await fixture.owner.discardPendingStudioDraft() }
            try #require(await gate.waitForEntry())
            await fixture.owner.load()
            let read = try fixture.attempt()
            #expect(read.observation == .load(.loaded(built)))
            #expect(fixture.owner.pendingStudioDraft == nil)
            await gate.release()
            await discard.value
            #expect(fixture.owner.latestStorageAttempt === read)
            #expect(fixture.owner.pendingStudioDraft == nil)
            #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
            #expect(await fixture.store.load() == .absent)
            #expect(await fixture.forwarding.snapshots == [built, nil])
        }
    }

    @Test func loadDuringCancelledCommitKeepsRollback() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let newer = fixture.draft(1)
            let gate = await fixture.forwarding.hold(.afterSave(2))
            let commit = fixture.start { await fixture.commit(newer) }
            try #require(await gate.waitForEntry())
            await fixture.owner.load()
            let read = try fixture.attempt()
            #expect(read.observation == .load(.loaded(newer)))
            commit.cancel()
            await gate.release()
            #expect(await commit.value == false)
            #expect(fixture.owner.pendingStudioDraft == built, "cancel restores the settled draft")
            #expect(try fixture.attempt().observation == .mutation(snapshot: built, outcome: .writeCompleted))
            #expect(await fixture.store.load() == .loaded(built))
            #expect(await fixture.forwarding.snapshots == [built, newer, built])
        }
    }

    @Test func loadStartedDuringMutationStaysSkippedAfterItCompletes() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let newer = fixture.draft(1)
            let saveGate = await fixture.forwarding.hold(.beforeSave(2))
            let commit = fixture.start { await fixture.commit(newer) }
            try #require(await saveGate.waitForEntry())
            let readGate = await fixture.forwarding.hold(.afterLoad(1))
            let load = fixture.start { await fixture.owner.load() }
            try #require(await readGate.waitForEntry())
            let read = try fixture.attempt()
            await saveGate.release()
            #expect(await commit.value)
            await readGate.release()
            await load.value
            #expect(read.observation == .load(.loaded(built)))
            #expect(fixture.owner.latestStorageAttempt === read)
            #expect(fixture.owner.pendingStudioDraft == newer, "quiescence is decided before the read")
            #expect(await fixture.store.load() == .loaded(newer))
            #expect(await fixture.forwarding.snapshots == [built, newer])
        }
    }

    @Test func failedMutationOverlappingLoadLeavesMemoryAheadOfDisk() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let newer = fixture.draft(1)
            var invalid = newer
            try #require(!invalid.fragment.nodes.isEmpty)
            invalid.fragment.nodes[0].node.position.x = .infinity
            let gate = await fixture.forwarding.hold(.afterSave(2))
            let commit = fixture.start { await fixture.commit(newer) }
            try #require(await gate.waitForEntry())
            // An overlapping mutation fails and finishes while the first is still in flight.
            #expect(await fixture.commit(invalid)) // Pinned: commit success ignores the persist outcome today.
            #expect(try fixture.attempt().observation == .mutation(snapshot: invalid, outcome: .encodingFailed))
            await fixture.owner.load()
            let read = try fixture.attempt()
            #expect(read.observation == .load(.loaded(newer)))
            #expect(fixture.owner.pendingStudioDraft == invalid, "one finished mutation does not end the window")
            await gate.release()
            #expect(await commit.value == false)
            #expect(try fixture.attempt().observation == .mutation(snapshot: invalid, outcome: .encodingFailed))
            #expect(fixture.owner.pendingStudioDraft == invalid)
            #expect(await fixture.store.load() == .loaded(newer))
            #expect(await fixture.forwarding.snapshots == [built, newer, invalid, invalid])
            // Failed writes still leave the window; a later quiescent load publishes disk again.
            await fixture.owner.load()
            #expect(fixture.owner.pendingStudioDraft == newer)
        }
    }
}
