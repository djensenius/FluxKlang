import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PendingStudioPatchPersistenceTests {
    @Test(arguments: [false, true], [false, true])
    func validationAcknowledgementCompatibility(blockedParent: Bool, validationErrors: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await Self.seedValidation(fixture, errors: validationErrors)
            let bytes = try Self.blockValidationParent(fixture, blocked: blockedParent)
            let result = await fixture.owner.validatePendingStudioDraftResult(context: fixture.context)
            let draft = try #require(fixture.owner.pendingStudioDraft)
            guard case .staged(let reported, let outcome) = result else {
                Issue.record("Revalidation must remain reviewable")
                return
            }
            #expect(reported == draft && result.draft == draft)
            Self.expectValidationOutcome(outcome, blocked: blockedParent)
            #expect(draft.hasErrors == validationErrors)
            #expect(draft.id == built.id && draft.createdAt == built.createdAt)
            #expect(draft.liveReferences == built.liveReferences)
            #expect(draft.outputReferences == built.outputReferences)
            #expect(draft.nameReferences == built.nameReferences)
            #expect(await fixture.forwarding.snapshots == [built, draft], "one detailed-entry save")
            let legacy = await fixture.owner.perform(.validatePendingStudioDraft, context: fixture.context)
            let refreshed = try #require(fixture.owner.pendingStudioDraft)
            guard case .pendingDraft(let legacyDraft) = legacy else {
                Issue.record("Legacy shape must remain pendingDraft")
                return
            }
            #expect(legacyDraft == refreshed)
            #expect(refreshed.hasErrors == validationErrors)
            #expect(await fixture.forwarding.snapshots == [built, draft, refreshed], "one legacy-entry save")
            #expect(await fixture.forwarding.loads == 0, "neither entry performs a confirmation read")
            #expect(fixture.owner.openReview(ofDraft: refreshed.id))
            if blockedParent {
                #expect(try Data(contentsOf: fixture.file.deletingLastPathComponent()) == bytes)
            } else {
                #expect(await fixture.store.load() == .loaded(refreshed))
            }
        }
    }

    @Test func validationAcknowledgementNoDraftDoesNoIO() async throws {
        try await Self.withValidationChat { fixture, chat in
            let result = await fixture.owner.validatePendingStudioDraftResult(context: fixture.context)
            #expect(result == .notPublished && result.draft == nil)
            let legacy = await fixture.owner.perform(.validatePendingStudioDraft, context: fixture.context)
            guard case .pendingDraft(nil) = legacy else {
                Issue.record("Expected legacy no-draft result")
                return
            }
            let fallback = await Self.collectReply(fixture)
            #expect(!fallback.failed && fallback.texts == ["There is no pending Studio draft."])
            #expect(fallback.cards.isEmpty)
            chat.composer = "Show the pending draft"
            chat.send(context: fixture.context)
            await chat.awaitOwnedWorkSnapshot()
            await fixture.fallbackWork.join()
            let reply = try #require(chat.selectedConversation?.messages.last)
            #expect(reply.text == "There is no pending Studio draft." && reply.cards.isEmpty)
            #expect(reply.role == .assistant && reply.state == .complete)
            #expect(fixture.owner.latestStorageAttempt == nil)
            #expect(fixture.owner.pendingStudioDraft == nil && fixture.owner.navigationTarget == nil)
            #expect(await fixture.forwarding.snapshots.isEmpty)
            #expect(await fixture.forwarding.loads == 0)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        }
    }

    @Test func validationAcknowledgementDiscardDuringSaveDoesNotPublish() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let held = await fixture.forwarding.hold(.beforeSave(2))
            let validate = fixture.start {
                await fixture.owner.validatePendingStudioDraftResult(context: fixture.context)
            }
            try #require(await held.waitForEntry())
            let entry = try #require(fixture.owner.pendingStudioDraft)
            await fixture.owner.discardPendingStudioDraft()
            await held.release()
            let result = await validate.value
            #expect(result == .notPublished && result.draft == nil)
            #expect(fixture.owner.pendingStudioDraft == nil)
            #expect(await fixture.forwarding.snapshots == [built, entry, nil, nil])
            #expect(await fixture.store.load() == .absent)
        }
    }

    @Test(arguments: [false, true])
    func validationAcknowledgementDifferentCatchUpKeepsEntryOutcome(returnToEntry: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let held = await fixture.forwarding.hold(.afterSave(2))
            let validate = fixture.start {
                await fixture.owner.validatePendingStudioDraftResult(context: fixture.context)
            }
            try #require(await held.waitForEntry())
            let entry = try #require(fixture.owner.pendingStudioDraft)
            var other = fixture.draft(1)
            try #require(!other.fragment.nodes.isEmpty)
            other.fragment.nodes[0].node.position.x = .infinity
            #expect(await fixture.commitResult(other) == .staged(draft: other, storageOutcome: .encodingFailed))
            let catchUp = await fixture.forwarding.hold(.afterSave(4))
            await held.release()
            try #require(await catchUp.waitForEntry())
            let attempt = try fixture.attempt()
            if returnToEntry {
                #expect(await fixture.commitResult(entry) == .staged(draft: entry, storageOutcome: .writeCompleted))
            }
            await catchUp.release()
            #expect(await validate.value == (returnToEntry
                ? .staged(draft: entry, storageOutcome: .writeCompleted) : .notPublished))
            #expect(attempt.observation == .mutation(snapshot: other, outcome: .encodingFailed))
            #expect(await fixture.forwarding.snapshots ==
                (returnToEntry ? [built, entry, other, other, entry] : [built, entry, other, other]))
            #expect(fixture.owner.pendingStudioDraft == (returnToEntry ? entry : other))
            #expect(await fixture.store.load() == .loaded(entry))
        }
    }

    @Test func validationAcknowledgementLatestSameSnapshotOutcomeWins() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let held = await fixture.forwarding.hold(.afterSave(2))
            let validate = fixture.start {
                await fixture.owner.validatePendingStudioDraftResult(context: fixture.context)
            }
            try #require(await held.waitForEntry())
            let entry = try #require(fixture.owner.pendingStudioDraft)
            let originalAttempt = try fixture.attempt()
            let other = fixture.draft(1)
            #expect(await fixture.commitResult(other) == .staged(draft: other, storageOutcome: .writeCompleted))
            let catchUp = await fixture.forwarding.hold(.afterSave(4))
            await held.release()
            try #require(await catchUp.waitForEntry())
            #expect(await fixture.commitResult(entry) == .staged(draft: entry, storageOutcome: .writeCompleted))
            let bytes = try Self.blockValidationParent(fixture)
            await catchUp.release()
            let result = await validate.value
            guard case .staged(let reported, let outcome) = result else {
                Issue.record("Equal entry must publish its latest same-snapshot outcome")
                return
            }
            #expect(reported == entry)
            Self.expectValidationOutcome(outcome, blocked: true)
            #expect(originalAttempt.observation == .mutation(snapshot: entry, outcome: .writeCompleted))
            #expect(fixture.owner.pendingStudioDraft == entry)
            #expect(await fixture.forwarding.snapshots == [built, entry, other, other, entry, entry])
            #expect(try Data(contentsOf: fixture.file.deletingLastPathComponent()) == bytes)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func validationAcknowledgementCancellationStillSettles(preCancelled: Bool, blockedParent: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let bytes = try Self.blockValidationParent(fixture, blocked: blockedParent)
            var changed = fixture.context
            changed.equipment = []
            let context = changed
            let held = await fixture.forwarding.hold(.afterSave(2))
            let validate = fixture.start {
                if preCancelled { withUnsafeCurrentTask { $0?.cancel() } }
                return await fixture.owner.validatePendingStudioDraftResult(context: context)
            }
            try #require(await held.waitForEntry())
            let entry = try #require(fixture.owner.pendingStudioDraft)
            try #require(entry != built && entry.hasErrors)
            validate.cancel()
            await held.release()
            let result = await validate.value
            guard case .staged(let draft, let outcome) = result else {
                Issue.record("Coordinator cancellation must not revoke revalidation")
                return
            }
            #expect(draft == entry)
            Self.expectValidationOutcome(outcome, blocked: blockedParent)
            #expect(await fixture.forwarding.snapshots == [built, entry], "no revalidation rollback save")
            if blockedParent {
                let parent = fixture.file.deletingLastPathComponent()
                #expect(try Data(contentsOf: parent) == bytes)
                try FileManager.default.removeItem(at: parent)
            }
            let nextGate = await fixture.forwarding.hold(.afterSave(3))
            let other = fixture.draft(1)
            let commit = fixture.start { await fixture.commitResult(other) }
            try #require(await nextGate.waitForEntry())
            commit.cancel()
            await nextGate.release()
            #expect(await commit.value == .notPublished)
            #expect(fixture.owner.pendingStudioDraft == entry, "settled revalidation is the rollback target")
            #expect(await fixture.forwarding.snapshots == [built, entry, other, entry])
            #expect(await fixture.store.load() == .loaded(entry))
        }
    }

    @Test func validationAcknowledgementUnsettledCommitStillRestores() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let settled = try await fixture.build()
            let other = fixture.draft(1)
            let held = await fixture.forwarding.hold(.afterSave(2))
            let commit = fixture.start { await fixture.commitResult(other) }
            try #require(await held.waitForEntry())
            var context = fixture.context
            context.equipment = []
            let result = await fixture.owner.validatePendingStudioDraftResult(context: context)
            let refreshed = try #require(result.draft)
            try #require(refreshed != other && refreshed.hasErrors)
            #expect(result == .staged(draft: refreshed, storageOutcome: .writeCompleted))
            commit.cancel()
            await held.release()
            #expect(await commit.value == .notPublished)
            #expect(fixture.owner.pendingStudioDraft == settled)
            #expect(await fixture.forwarding.snapshots == [settled, other, refreshed, refreshed, settled])
            // A second restoration must read the original settled state, not the unsettled refresh.
            let nextGate = await fixture.forwarding.hold(.afterSave(6))
            let next = fixture.start { await fixture.commitResult(other) }
            try #require(await nextGate.waitForEntry())
            next.cancel()
            await nextGate.release()
            #expect(await next.value == .notPublished)
            #expect(fixture.owner.pendingStudioDraft == settled)
            #expect(await fixture.forwarding.snapshots ==
                [settled, other, refreshed, refreshed, settled, other, settled])
            #expect(await fixture.store.load() == .loaded(settled))
        }
    }

    @Test func provenanceFollowsActualEqualWritesAndForwardedObservations() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let draft = fixture.draft()
            let first = UUID()
            let second = UUID()
            let third = UUID()
            let delayedSave = await fixture.forwarding.hold(.afterSave(1))
            let saving = fixture.start { await fixture.forwarding.save(draft, provenance: first) }
            try #require(await delayedSave.waitForEntry())
            #expect(await fixture.forwarding.save(draft, provenance: second) == .writeCompleted)
            await delayedSave.release()
            #expect(await saving.value == .writeCompleted)

            let delayedLoad = await fixture.forwarding.hold(.afterLoad(1))
            let loading = fixture.start { await fixture.forwarding.loadWithProvenance() }
            try #require(await delayedLoad.waitForEntry())
            #expect(await fixture.forwarding.save(draft, provenance: third) == .writeCompleted)
            #expect(await fixture.forwarding.loadWithProvenance() == .init(
                outcome: .loaded(draft), provenance: third))
            await delayedLoad.release()
            #expect(await loading.value == .init(outcome: .loaded(draft), provenance: second))
        }
    }

    @Test func provenanceTracksMutationOrderNotSubmissionOrder() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let draft = fixture.draft()
            let first = UUID()
            let second = UUID()
            let gate = await fixture.forwarding.hold(.beforeSave(1))
            let saving = fixture.start { await fixture.forwarding.save(draft, provenance: first) }
            try #require(await gate.waitForEntry())
            #expect(await fixture.forwarding.save(draft, provenance: second) == .writeCompleted)
            await gate.release()
            #expect(await saving.value == .writeCompleted)
            #expect(await fixture.store.loadWithProvenance() == .init(
                outcome: .loaded(draft), provenance: first))
        }
    }

    @Test func provenanceUnknownAndDeletionTransitions() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let draft = fixture.draft()
            let token = UUID()
            let store = fixture.store
            #expect(await store.loadWithProvenance() == .init(outcome: .absent, provenance: nil))
            #expect(await store.save(draft, provenance: token) == .writeCompleted)
            #expect(await store.load() == .loaded(draft))
            #expect(await store.loadWithProvenance() == .init(outcome: .loaded(draft), provenance: token))
            let other = PendingStudioPatchStore(fileURL: fixture.file)
            #expect(await other.loadWithProvenance() == .init(outcome: .loaded(draft), provenance: nil))
            #expect(await store.save(draft) == .writeCompleted)
            #expect(await store.loadWithProvenance() == .init(outcome: .loaded(draft), provenance: nil))
            #expect(await store.save(draft, provenance: token) == .writeCompleted)
            let beforeMismatch = try Data(contentsOf: fixture.file)
            let different = fixture.draft(1)
            try JSONEncoder().encode(different).write(to: fixture.file)
            #expect(await store.loadWithProvenance() == .init(outcome: .loaded(different), provenance: nil))
            try beforeMismatch.write(to: fixture.file)
            #expect(await store.loadWithProvenance() == .init(outcome: .loaded(draft), provenance: nil))
            #expect(await store.save(draft, provenance: token) == .writeCompleted)
            let beforeMalformed = try Data(contentsOf: fixture.file)
            try Data("{".utf8).write(to: fixture.file)
            #expect(await store.load() == .malformedOrUnsupported)
            try beforeMalformed.write(to: fixture.file)
            #expect(await store.loadWithProvenance() == .init(outcome: .loaded(draft), provenance: nil))
            #expect(await store.save(draft, provenance: token) == .writeCompleted)
            let beforeDeletion = try Data(contentsOf: fixture.file)
            #expect(await store.save(nil, provenance: UUID()) == .deleteCompleted)
            try beforeDeletion.write(to: fixture.file)
            #expect(await store.loadWithProvenance() == .init(outcome: .loaded(draft), provenance: nil))
            #expect(await store.save(draft, provenance: token) == .writeCompleted)
            let beforeAbsentDelete = try Data(contentsOf: fixture.file)
            try FileManager.default.removeItem(at: fixture.file)
            #expect(await store.save(nil) == .alreadyAbsent)
            try beforeAbsentDelete.write(to: fixture.file)
            #expect(await store.loadWithProvenance() == .init(outcome: .loaded(draft), provenance: nil))
            #expect(await store.save(draft, provenance: token) == .writeCompleted)
            let beforeAbsentLoad = try Data(contentsOf: fixture.file)
            try FileManager.default.removeItem(at: fixture.file)
            #expect(await store.load() == .absent)
            try beforeAbsentLoad.write(to: fixture.file)
            #expect(await store.loadWithProvenance() == .init(outcome: .loaded(draft), provenance: nil))
        }
    }

    @Test func provenancePreservesPremutationFailureAndForgetsUnconfirmedEffects() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let store = fixture.store
            let draft = fixture.draft()
            let token = UUID()
            #expect(await store.save(draft, provenance: token) == .writeCompleted)
            var invalid = draft
            invalid.fragment.nodes[0].node.position.x = .infinity
            #expect(await store.save(invalid, provenance: UUID()) == .encodingFailed)
            #expect(await store.loadWithProvenance() == .init(outcome: .loaded(draft), provenance: token))

            let manager = FileManager.default
            let parent = fixture.file.deletingLastPathComponent()
            let backup = fixture.root.appendingPathComponent("backup")
            try manager.moveItem(at: parent, to: backup)
            try Data("blocker".utf8).write(to: parent)
            guard case .directoryPreparationFailed = await store.save(draft, provenance: UUID()) else {
                Issue.record("Expected directory preparation failure")
                return
            }
            try manager.removeItem(at: parent)
            try manager.moveItem(at: backup, to: parent)
            #expect(await store.loadWithProvenance() == .init(outcome: .loaded(draft), provenance: token))
            try manager.moveItem(at: parent, to: backup)
            try Data("blocker".utf8).write(to: parent)
            #expect(await store.load() == .readFailed(.notDirectory))
            try manager.removeItem(at: parent)
            try manager.moveItem(at: backup, to: parent)
            #expect(await store.loadWithProvenance() == .init(outcome: .loaded(draft), provenance: nil))
            #expect(await store.save(draft, provenance: token) == .writeCompleted)
            let beforeWriteFailure = try Data(contentsOf: fixture.file)
            try manager.removeItem(at: fixture.file)
            try manager.createDirectory(at: fixture.file, withIntermediateDirectories: false)
            guard case .mutationFailedEffectUnconfirmed = await store.save(draft, provenance: UUID()) else {
                Issue.record("Expected unconfirmed write failure")
                return
            }
            try manager.removeItem(at: fixture.file)
            try beforeWriteFailure.write(to: fixture.file)
            #expect(await store.loadWithProvenance() == .init(outcome: .loaded(draft), provenance: nil))
            #expect(await store.save(draft, provenance: token) == .writeCompleted)
            let beforeDeleteFailure = try Data(contentsOf: fixture.file)
            try manager.removeItem(at: fixture.file)
            try manager.createDirectory(at: fixture.file, withIntermediateDirectories: false)
            #expect(!(await store.save(nil)).completed)
            try manager.removeItem(at: fixture.file)
            try beforeDeleteFailure.write(to: fixture.file)
            #expect(await store.loadWithProvenance() == .init(outcome: .loaded(draft), provenance: nil))
        }
    }

    static func expectValidationOutcome(_ outcome: PendingStudioPatchMutationOutcome, blocked: Bool) {
        if blocked {
            guard case .directoryPreparationFailed = outcome else {
                Issue.record("Expected real blocked-parent failure, got \(outcome)")
                return
            }
            #expect(!outcome.completed)
        } else {
            #expect(outcome == .writeCompleted)
        }
    }
}
