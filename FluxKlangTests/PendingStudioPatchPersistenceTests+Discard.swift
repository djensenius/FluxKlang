import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PendingStudioPatchPersistenceTests {
    @Test(arguments: ["saved", "absent", "blocked"])
    func discardAcknowledgementDetailedAndLegacy(storage: String) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            #expect(fixture.owner.openReview(ofDraft: built.id))
            if storage == "absent" { #expect(await fixture.store.save(nil) == .deleteCompleted) }
            let bytes = try Self.blockValidationParent(fixture, blocked: storage == "blocked")
            let outcome = await fixture.owner.discardPendingStudioDraftResult()
            #expect(outcome == Self.discardOutcome(storage))
            #expect(fixture.owner.pendingStudioDraft == nil && fixture.owner.navigationTarget == nil)
            await fixture.owner.discardPendingStudioDraft()
            #expect(try fixture.attempt().observation == .mutation(
                snapshot: nil, outcome: Self.discardOutcome(storage == "saved" ? "absent" : storage)))
            #expect(await fixture.forwarding.snapshots == [built, nil, nil], "one save per API entry")
            #expect(await fixture.forwarding.loads == 0, "no confirmation read")
            if storage == "blocked" {
                #expect(try Data(contentsOf: fixture.file.deletingLastPathComponent()) == bytes)
            } else {
                #expect(await fixture.store.load() == .absent)
            }
        }
    }

    @Test(arguments: ["saved", "absent", "blocked"])
    func discardAcknowledgementActualPresentation(storage: String) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            #expect(fixture.owner.openReview(ofDraft: built.id))
            if storage == "absent" { #expect(await fixture.store.save(nil) == .deleteCompleted) }
            let bytes = try Self.blockValidationParent(fixture, blocked: storage == "blocked")
            let held = await fixture.forwarding.hold(.beforeSave(2))
            let presentation = fixture.discardPresentation
            presentation.discard(using: fixture.owner)
            try #require(await held.waitForEntry())
            #expect(fixture.owner.pendingStudioDraft == nil && fixture.owner.navigationTarget == nil)
            #expect(presentation.warning == nil)
            await held.release()
            await presentation.awaitOwnedWorkSnapshot()
            #expect(presentation.warning == (storage == "blocked" ? .removalUnconfirmed : nil))
            if let warning = presentation.warning {
                #expect(warning.message ==
                    "Removing the saved draft was not confirmed. It may reappear after restarting.")
            }
            #expect(try fixture.attempt().observation == .mutation(
                snapshot: nil, outcome: Self.discardOutcome(storage)))
            #expect(await fixture.forwarding.snapshots == [built, nil])
            #expect(await fixture.forwarding.loads == 0)
            if storage == "blocked" {
                #expect(try Data(contentsOf: fixture.file.deletingLastPathComponent()) == bytes)
            } else {
                #expect(await fixture.store.load() == .absent)
            }
        }
    }

    @Test func discardAcknowledgementNewPendingSuppressesFailure() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            _ = try Self.blockValidationParent(fixture)
            let held = await fixture.forwarding.hold(.afterSave(2))
            fixture.discardPresentation.discard(using: fixture.owner)
            try #require(await held.waitForEntry())
            let original = try fixture.attempt()
            try FileManager.default.removeItem(at: fixture.file.deletingLastPathComponent())
            let newer = try await fixture.build(1)
            #expect(fixture.owner.openReview(ofDraft: newer.id))
            await held.release()
            await fixture.discardPresentation.awaitOwnedWorkSnapshot()
            #expect(fixture.discardPresentation.warning == nil)
            #expect(fixture.owner.pendingStudioDraft == newer)
            #expect(fixture.owner.navigationTarget == .reviewPendingDraft)
            #expect(original.observation == .mutation(
                snapshot: nil, outcome: .mutationFailedEffectUnconfirmed(.notDirectory)))
            #expect(await fixture.forwarding.snapshots == [built, nil, newer], "failure stops catch-up")
            #expect(await fixture.store.load() == .loaded(newer))
        }
    }

    @Test(arguments: [false, true])
    func discardAcknowledgementReverseCompletion(olderFails: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            _ = try Self.blockValidationParent(fixture, blocked: olderFails)
            let held = await fixture.forwarding.hold(.afterSave(2))
            let presentation = fixture.discardPresentation
            let older = presentation.discard(using: fixture.owner)
            try #require(await held.waitForEntry())
            let original = try fixture.attempt()
            if olderFails {
                try FileManager.default.removeItem(at: fixture.file.deletingLastPathComponent())
            } else {
                _ = try Self.blockValidationParent(fixture)
            }
            let newer = presentation.discard(using: fixture.owner)
            await newer.value
            let expected: StudioDraftDiscardPresentation.Warning? = olderFails ? nil : .removalUnconfirmed
            #expect(presentation.warning == expected)
            await held.release()
            await older.value
            await presentation.awaitOwnedWorkSnapshot()
            #expect(presentation.warning == expected, "older completion cannot show OR clear newer presentation")
            #expect(original.observation == .mutation(
                snapshot: nil, outcome: Self.discardOutcome(olderFails ? "blocked" : "saved")))
            #expect(fixture.owner.pendingStudioDraft == nil)
            #expect(await fixture.forwarding.snapshots == [built, nil, nil], "overlap is not queued")
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test func discardAcknowledgementNewClickClearsWarningImmediately() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            _ = try Self.blockValidationParent(fixture)
            let presentation = fixture.discardPresentation
            await presentation.discard(using: fixture.owner).value
            #expect(presentation.warning == .removalUnconfirmed)
            try FileManager.default.removeItem(at: fixture.file.deletingLastPathComponent())
            let held = await fixture.forwarding.hold(.beforeSave(3))
            presentation.discard(using: fixture.owner)
            #expect(presentation.warning == nil, "cleared synchronously at click, not after IO")
            try #require(await held.waitForEntry())
            #expect(presentation.warning == nil)
            await held.release()
            await presentation.awaitOwnedWorkSnapshot()
            #expect(presentation.warning == nil)
            #expect(await fixture.forwarding.snapshots == [built, nil, nil])
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test func discardAcknowledgementDismissAndDisappearanceArePresentationOnly() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let bytes = try Self.blockValidationParent(fixture)
            let presentation = fixture.discardPresentation
            await presentation.discard(using: fixture.owner).value
            #expect(presentation.warning == .removalUnconfirmed)
            presentation.dismiss()
            await presentation.awaitOwnedWorkSnapshot()
            #expect(presentation.warning == nil)
            #expect(await fixture.forwarding.snapshots == [built, nil])
            // Joining/dismissal do not close admission; a fresh click can warn again.
            await presentation.discard(using: fixture.owner).value
            #expect(presentation.warning == .removalUnconfirmed)
            presentation.disappear()
            presentation.pendingDraftChanged(nil) // A retained @State owner on reappearance.
            await presentation.awaitOwnedWorkSnapshot()
            #expect(presentation.warning == nil)
            #expect(await fixture.forwarding.snapshots == [built, nil, nil])
            #expect(await fixture.forwarding.loads == 0)
            #expect(try Data(contentsOf: fixture.file.deletingLastPathComponent()) == bytes)
        }
    }

    @Test(arguments: [false, true])
    func discardAcknowledgementDisappearanceDoesNotCancelStorage(blocked: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            _ = try Self.blockValidationParent(fixture, blocked: blocked)
            let held = await fixture.forwarding.hold(.beforeSave(2))
            let presentation = fixture.discardPresentation
            presentation.discard(using: fixture.owner)
            try #require(await held.waitForEntry())
            presentation.disappear()
            presentation.pendingDraftChanged(nil)
            await held.release()
            await presentation.awaitOwnedWorkSnapshot()
            #expect(presentation.warning == nil, "no late completion or reappearance replay")
            #expect(try fixture.attempt().observation == .mutation(
                snapshot: nil, outcome: Self.discardOutcome(blocked ? "blocked" : "saved")))
            #expect(fixture.owner.pendingStudioDraft == nil && fixture.owner.navigationTarget == nil)
            #expect(await fixture.forwarding.snapshots == [built, nil])
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test func discardAcknowledgementObservedDraftClearsButUnrelatedSuccessDoesNot() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            _ = try Self.blockValidationParent(fixture)
            let presentation = fixture.discardPresentation
            await presentation.discard(using: fixture.owner).value
            #expect(presentation.warning == .removalUnconfirmed)
            _ = await fixture.owner.perform(.inspectConnectionState, context: fixture.context)
            presentation.pendingDraftChanged(nil)
            #expect(presentation.warning == .removalUnconfirmed)
            #expect(await fixture.forwarding.snapshots == [built, nil])
            try FileManager.default.removeItem(at: fixture.file.deletingLastPathComponent())
            let newer = try await fixture.build(1)
            presentation.pendingDraftChanged(newer)
            #expect(presentation.warning == nil)
            #expect(fixture.owner.pendingStudioDraft == newer)
            #expect(await fixture.forwarding.snapshots == [built, nil, newer], "observation adds no IO")
            await fixture.owner.discardPendingStudioDraft()
            presentation.pendingDraftChanged(nil)
            await presentation.awaitOwnedWorkSnapshot()
            #expect(presentation.warning == nil, "cleared warning never replays")
            #expect(await fixture.forwarding.snapshots == [built, nil, newer, nil])
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test func discardAcknowledgementNilABAKeepsHistoricalFailure() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            _ = try Self.blockValidationParent(fixture)
            let held = await fixture.forwarding.hold(.afterSave(2))
            let presentation = fixture.discardPresentation
            presentation.discard(using: fixture.owner)
            try #require(await held.waitForEntry())
            let original = try fixture.attempt()
            try FileManager.default.removeItem(at: fixture.file.deletingLastPathComponent())
            let newer = try await fixture.build(1)
            presentation.pendingDraftChanged(newer)
            #expect(await fixture.owner.discardPendingStudioDraftResult() == .deleteCompleted)
            presentation.pendingDraftChanged(nil)
            await fixture.owner.load() // Deliberately replace latest diagnostics, never the saved outcome.
            #expect(try fixture.attempt().observation == .load(.absent))
            await held.release()
            await presentation.awaitOwnedWorkSnapshot()
            #expect(presentation.warning == .removalUnconfirmed)
            #expect(original.observation == .mutation(
                snapshot: nil, outcome: .mutationFailedEffectUnconfirmed(.notDirectory)))
            #expect(fixture.owner.pendingStudioDraft == nil)
            #expect(await fixture.forwarding.snapshots == [built, nil, newer, nil])
            #expect(await fixture.forwarding.loads == 1)
            #expect(await fixture.store.load() == .absent, "other nil-save does not acknowledge this failure")
        }
    }

    @Test(arguments: [false, true], [false, true])
    func discardAcknowledgementCancellationKeepsOutcome(preCancelled: Bool, blocked: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            #expect(fixture.owner.openReview(ofDraft: built.id))
            let bytes = try Self.blockValidationParent(fixture, blocked: blocked)
            let held = await fixture.forwarding.hold(.beforeSave(2))
            let discard = fixture.start { await fixture.owner.discardPendingStudioDraftResult() }
            if preCancelled { discard.cancel() }
            try #require(await held.waitForEntry())
            if !preCancelled { discard.cancel() }
            #expect(fixture.owner.pendingStudioDraft == nil && fixture.owner.navigationTarget == nil)
            await held.release()
            #expect(await discard.value == Self.discardOutcome(blocked ? "blocked" : "saved"))
            #expect(await fixture.forwarding.snapshots == [built, nil])
            #expect(await fixture.forwarding.loads == 0)
            if blocked {
                #expect(try Data(contentsOf: fixture.file.deletingLastPathComponent()) == bytes)
            } else {
                #expect(await fixture.store.load() == .absent)
            }
        }
    }

    @Test func discardAcknowledgementClearsSettledRollback() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            await fixture.discardPresentation.discard(using: fixture.owner).value
            let newer = fixture.draft(1)
            let held = await fixture.forwarding.hold(.beforeSave(3))
            let commit = fixture.start { await fixture.commitResult(newer) }
            try #require(await held.waitForEntry())
            commit.cancel()
            await held.release()
            #expect(await commit.value == .notPublished)
            #expect(fixture.owner.pendingStudioDraft == nil, "cancelled commit cannot resurrect discarded settled A")
            #expect(fixture.discardPresentation.warning == nil)
            #expect(await fixture.forwarding.snapshots == [built, nil, newer, nil])
            #expect(await fixture.store.load() == .absent)
        }
    }

    @Test func discardAcknowledgementDifferentCatchUpKeepsNilOutcome() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let held = await fixture.forwarding.hold(.afterSave(2))
            let discard = fixture.start { await fixture.owner.discardPendingStudioDraftResult() }
            try #require(await held.waitForEntry())
            var newer = fixture.draft(1)
            newer.fragment.nodes[0].node.position.x = .infinity
            #expect(await fixture.commitResult(newer) == .staged(draft: newer, storageOutcome: .encodingFailed))
            await held.release()
            #expect(await discard.value == .deleteCompleted, "B's failed catch-up is not nil's result")
            #expect(fixture.owner.pendingStudioDraft == newer)
            #expect(await fixture.forwarding.snapshots == [built, nil, newer, newer])
            #expect(try fixture.attempt().observation == .mutation(snapshot: newer, outcome: .encodingFailed))
        }
    }

    @Test func discardAcknowledgementLatestNilCatchUpOutcomeWins() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let held = await fixture.forwarding.hold(.afterSave(2))
            let presentation = fixture.discardPresentation
            presentation.discard(using: fixture.owner)
            try #require(await held.waitForEntry())
            let original = try fixture.attempt()
            let newer = try await fixture.build(1)
            let catchUp = await fixture.forwarding.hold(.afterSave(4))
            await held.release()
            try #require(await catchUp.waitForEntry())
            #expect(await fixture.owner.discardPendingStudioDraftResult() == .deleteCompleted)
            let bytes = try Self.blockValidationParent(fixture)
            await catchUp.release()
            await presentation.awaitOwnedWorkSnapshot()
            #expect(presentation.warning == .removalUnconfirmed)
            #expect(original.observation == .mutation(snapshot: nil, outcome: .deleteCompleted))
            #expect(try fixture.attempt().observation == .mutation(
                snapshot: nil, outcome: .mutationFailedEffectUnconfirmed(.notDirectory)))
            #expect(await fixture.forwarding.snapshots == [built, nil, newer, newer, nil, nil])
            #expect(fixture.owner.pendingStudioDraft == nil)
            #expect(try Data(contentsOf: fixture.file.deletingLastPathComponent()) == bytes)
        }
    }

    private static func discardOutcome(_ storage: String) -> PendingStudioPatchMutationOutcome {
        switch storage {
        case "saved": .deleteCompleted
        case "absent": .alreadyAbsent
        default: .mutationFailedEffectUnconfirmed(.notDirectory)
        }
    }
}
