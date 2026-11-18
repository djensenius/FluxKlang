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

    @Test func supersededAbsentLoadDoesNotClearNewerBuild() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let gate = await fixture.forwarding.hold(.afterLoad(1))
            let load = fixture.start { await fixture.owner.load() }
            try #require(await gate.waitForEntry())
            let read = try fixture.attempt()
            let built = try await fixture.build()
            let build = try fixture.attempt()
            await gate.release()
            await load.value
            #expect(read.observation == .load(.absent))
            #expect(fixture.owner.latestStorageAttempt === build)
            #expect(fixture.owner.pendingStudioDraft == built)
            // A cancelled commit restores the settled draft, which must still be the newer build.
            let other = fixture.draft(1)
            let saveGate = await fixture.forwarding.hold(.afterSave(2))
            let commit = fixture.start { await fixture.commit(other) }
            try #require(await saveGate.waitForEntry())
            commit.cancel()
            await saveGate.release()
            #expect(await commit.value == false)
            #expect(fixture.owner.pendingStudioDraft == built, "settled build survives the absent read")
            #expect(await fixture.forwarding.snapshots == [built, other, built])
            #expect(await fixture.store.load() == .loaded(built))
        }
    }

    @Test func failedNewerLoadSupersedesOlderSuccessfulLoad() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let stale = fixture.draft(1)
            #expect(await fixture.store.save(stale) == .writeCompleted)
            let gate = await fixture.forwarding.hold(.afterLoad(1))
            let first = fixture.start { await fixture.owner.load() }
            try #require(await gate.waitForEntry())
            let older = try fixture.attempt()
            try Data("{".utf8).write(to: fixture.file)
            await fixture.owner.load()
            let newer = try fixture.attempt()
            #expect(newer !== older)
            #expect(newer.observation == .load(.malformedOrUnsupported))
            await gate.release()
            await first.value
            #expect(older.observation == .load(.loaded(stale)))
            #expect(fixture.owner.latestStorageAttempt === newer)
            #expect(fixture.owner.pendingStudioDraft == built, "older read is not published after a failed newer read")
            let saveGate = await fixture.forwarding.hold(.afterSave(2))
            let commit = fixture.start { await fixture.commit(stale) }
            try #require(await saveGate.waitForEntry())
            commit.cancel()
            await saveGate.release()
            #expect(await commit.value == false)
            #expect(fixture.owner.pendingStudioDraft == built, "settled draft is still the pre-load build")
            #expect(await fixture.forwarding.snapshots == [built, stale, built])
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
