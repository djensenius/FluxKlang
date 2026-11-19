import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PendingStudioPatchPersistenceTests {
    @Test(arguments: [false, true])
    func typedBuildAcknowledgementDetailedAndLegacyCompatibility(blockedParent: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let parent = fixture.file.deletingLastPathComponent()
            let bytes = Data("owned typed build obstruction".utf8)
            if blockedParent { try bytes.write(to: parent) }
            let request = try fixture.buildRequest()
            let result = await fixture.buildResult(request)
            let draft = try #require(fixture.owner.pendingStudioDraft)
            guard case .staged(let reported, let outcome) = result else {
                Issue.record("Expected in-memory staging")
                return
            }
            #expect(reported == draft && result.draft == draft)
            Self.expectTypedBuildOutcome(outcome, blockedParent: blockedParent)
            #expect(draft.liveReferences == request.liveReferences)
            #expect(draft.outputReferences == request.outputReferences)
            #expect(fixture.owner.navigationTarget == nil)
            #expect(await fixture.forwarding.snapshots == [draft], "one detailed-entry persistence delegation")
            let legacy = await fixture.owner.perform(.buildStudioDraft(request), context: fixture.context)
            let current = try #require(fixture.owner.pendingStudioDraft)
            guard case .pendingDraft(let legacyDraft) = legacy else {
                Issue.record("Legacy result must remain pendingDraft")
                return
            }
            #expect(legacyDraft == current, "legacy success still means staged, not saved")
            #expect(current.id == draft.id && current.request == draft.request)
            #expect(await fixture.forwarding.snapshots == [draft, current], "one legacy-entry delegation")
            #expect(fixture.owner.openReview(ofDraft: current.id))
            #expect(fixture.owner.navigationTarget == .reviewPendingDraft)
            if blockedParent {
                #expect(try Data(contentsOf: parent) == bytes)
                #expect(await fixture.store.load() == .readFailed(.notDirectory))
            } else {
                #expect(await fixture.store.load() == .loaded(current))
            }
        }
    }

    @Test func typedBuildAcknowledgementStillStagesValidationErrors() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let result = await fixture.buildResult(StudioWiringRequest(sourceInstrumentIDs: []))
            let draft = try #require(result.draft)
            #expect(draft.hasErrors, "typed admission is not prepared-commit admission")
            #expect(result == .staged(draft: draft, storageOutcome: .writeCompleted))
            #expect(fixture.owner.pendingStudioDraft == draft)
            #expect(await fixture.forwarding.snapshots == [draft])
            #expect(await fixture.store.load() == .loaded(draft))
        }
    }

    @Test func typedBuildAcknowledgementDiscardDuringSaveDoesNotPublish() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let request = try fixture.buildRequest()
            let held = await fixture.forwarding.hold(.beforeSave(1))
            let build = fixture.start { await fixture.buildResult(request) }
            try #require(await held.waitForEntry())
            let draft = try #require(fixture.owner.pendingStudioDraft)
            await fixture.owner.discardPendingStudioDraft()
            await held.release()
            let result = await build.value
            #expect(result == .notPublished)
            #expect(result.draft == nil)
            #expect(fixture.owner.pendingStudioDraft == nil)
            #expect(fixture.owner.navigationTarget == nil)
            #expect(await fixture.store.load() == .absent)
            #expect(await fixture.forwarding.snapshots == [draft, nil, nil])
        }
    }

    @Test(arguments: [false, true])
    func typedBuildAcknowledgementRealChatKeepsOwnCards(blockedParent: Bool) async throws {
        try await Self.withTypedBuildChat { fixture, generator, chat in
            let parent = fixture.file.deletingLastPathComponent()
            let bytes = Data("owned typed chat obstruction".utf8)
            if blockedParent { try bytes.write(to: parent) }
            let request = try fixture.buildRequest()
            chat.createWiringDraft(
                sourceIDs: request.sourceInstrumentIDs, effectIDs: [], destination: .finalMix, context: fixture.context)
            await chat.awaitOwnedWorkSnapshot()
            let draft = try #require(fixture.owner.pendingStudioDraft)
            let reply = try #require(chat.selectedConversation?.messages.last)
            #expect(reply.role == .assistant && reply.state == .complete)
            let text = try Self.typedBuildText(draft)
            #expect(reply.text == (blockedParent ? text + "\n\n" + Self.typedSaveWarning : text))
            #expect(reply.text.components(separatedBy: Self.typedSaveWarning).count == (blockedParent ? 2 : 1))
            #expect(reply.cards == Self.typedBuildCards(draft))
            #expect(await fixture.forwarding.snapshots == [draft])
            #expect(generator.calls == 0)
            #expect(fixture.owner.navigationTarget == nil)
            #expect(fixture.owner.openReview(ofDraft: draft.id), "failed saving does not revoke review")
            #expect(fixture.owner.navigationTarget == .reviewPendingDraft)
            if blockedParent {
                #expect(try Data(contentsOf: parent) == bytes)
                #expect(await fixture.store.load() == .readFailed(.notDirectory))
            } else {
                #expect(await fixture.store.load() == .loaded(draft))
            }
        }
    }

    @Test(arguments: [false, true])
    func typedBuildAcknowledgementHeldFailedChatKeepsHistoricalOutcome(equalValueABA: Bool) async throws {
        try await Self.withTypedBuildChat { fixture, generator, chat in
            let parent = fixture.file.deletingLastPathComponent()
            let bytes = Data("owned held typed chat obstruction".utf8)
            try bytes.write(to: parent)
            let held = await fixture.forwarding.hold(.afterSave(1))
            let request = try fixture.buildRequest()
            chat.createWiringDraft(
                sourceIDs: request.sourceInstrumentIDs, effectIDs: [], destination: .finalMix, context: fixture.context)
            try #require(await held.waitForEntry())
            let entry = try #require(fixture.owner.pendingStudioDraft)
            let attempt = try fixture.attempt()
            let preserved = fixture.root.appendingPathComponent("preserved")
            try FileManager.default.moveItem(at: parent, to: preserved)
            var other = entry
            other.createdAt = entry.createdAt.addingTimeInterval(1)
            try #require(other.id == entry.id && other != entry)
            #expect(await fixture.commitResult(other) == .staged(draft: other, storageOutcome: .writeCompleted))
            if equalValueABA {
                #expect(await fixture.commitResult(entry) == .staged(draft: entry, storageOutcome: .writeCompleted))
            }
            let latest = try fixture.attempt()
            await held.release()
            await chat.awaitOwnedWorkSnapshot()
            let reply = try #require(chat.selectedConversation?.messages.last)
            #expect(reply.role == .assistant && reply.state == .complete)
            let text = try Self.typedBuildText(entry)
            #expect(reply.text == (equalValueABA
                ? text + "\n\n" + Self.typedSaveWarning : "There is no pending Studio draft."))
            #expect(reply.text.components(separatedBy: Self.typedSaveWarning).count == (equalValueABA ? 2 : 1))
            #expect(reply.cards == (equalValueABA ? Self.typedBuildCards(entry) : []))
            #expect(fixture.owner.pendingStudioDraft == (equalValueABA ? entry : other))
            #expect(fixture.owner.navigationTarget == nil)
            #expect(await fixture.store.load() == .loaded(equalValueABA ? entry : other))
            #expect(fixture.owner.latestStorageAttempt === latest, "the newer diagnostic is not acknowledgement")
            guard case .mutation(entry, .some(.directoryPreparationFailed)) = attempt.observation else {
                Issue.record("Expected this typed invocation's real blocked-parent failure")
                return
            }
            #expect(await fixture.forwarding.snapshots ==
                (equalValueABA ? [entry, other, entry] : [entry, other]), "entry failure stops catch-up")
            #expect(try Data(contentsOf: preserved) == bytes)
            #expect(generator.calls == 0)
        }
    }

    @Test(arguments: [false, true])
    func typedBuildAcknowledgementDifferentCatchUpKeepsEntryOutcome(returnToEntry: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let request = try fixture.buildRequest()
            let held = await fixture.forwarding.hold(.afterSave(1))
            let build = fixture.start { await fixture.buildResult(request) }
            try #require(await held.waitForEntry())
            let entry = try #require(fixture.owner.pendingStudioDraft)
            var other = fixture.draft(1)
            try #require(!other.fragment.nodes.isEmpty)
            other.fragment.nodes[0].node.position.x = .infinity
            #expect(await fixture.commitResult(other) == .staged(draft: other, storageOutcome: .encodingFailed))
            let catchUp = await fixture.forwarding.hold(.afterSave(3))
            await held.release()
            try #require(await catchUp.waitForEntry())
            let attempt = try fixture.attempt()
            if returnToEntry {
                #expect(await fixture.commitResult(entry) == .staged(draft: entry, storageOutcome: .writeCompleted))
            }
            await catchUp.release()
            #expect(await build.value == (returnToEntry
                ? .staged(draft: entry, storageOutcome: .writeCompleted) : .notPublished))
            #expect(attempt.observation == .mutation(snapshot: other, outcome: .encodingFailed))
            #expect(await fixture.forwarding.snapshots ==
                (returnToEntry ? [entry, other, other, entry] : [entry, other, other]))
            #expect(fixture.owner.pendingStudioDraft == (returnToEntry ? entry : other))
            #expect(await fixture.store.load() == .loaded(entry))
        }
    }

    @Test func typedBuildAcknowledgementLatestSameSnapshotOutcomeWins() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let request = try fixture.buildRequest()
            let held = await fixture.forwarding.hold(.afterSave(1))
            let build = fixture.start { await fixture.buildResult(request) }
            try #require(await held.waitForEntry())
            let entry = try #require(fixture.owner.pendingStudioDraft)
            let originalAttempt = try fixture.attempt()
            let other = fixture.draft(1)
            #expect(await fixture.commitResult(other) == .staged(draft: other, storageOutcome: .writeCompleted))
            let catchUp = await fixture.forwarding.hold(.afterSave(3))
            await held.release()
            try #require(await catchUp.waitForEntry())
            #expect(await fixture.commitResult(entry) == .staged(draft: entry, storageOutcome: .writeCompleted))
            let parent = fixture.file.deletingLastPathComponent()
            try FileManager.default.removeItem(at: parent)
            let bytes = Data("owned typed same-snapshot obstruction".utf8)
            try bytes.write(to: parent)
            await catchUp.release()
            let result = await build.value
            guard case .staged(let draft, let outcome) = result else {
                Issue.record("Expected equal entry snapshot to publish")
                return
            }
            #expect(draft == entry)
            Self.expectTypedBuildOutcome(outcome, blockedParent: true)
            #expect(originalAttempt.observation == .mutation(snapshot: entry, outcome: .writeCompleted))
            #expect(fixture.owner.pendingStudioDraft == entry)
            #expect(await fixture.forwarding.snapshots == [entry, other, other, entry, entry])
            #expect(try Data(contentsOf: parent) == bytes)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func typedBuildAcknowledgementCancellationStillPublishes(preCancelled: Bool, blockedParent: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let parent = fixture.file.deletingLastPathComponent()
            let bytes = Data("owned typed cancellation obstruction".utf8)
            if blockedParent { try bytes.write(to: parent) }
            let request = try fixture.buildRequest()
            let held = await fixture.forwarding.hold(.afterSave(1))
            let build = fixture.start {
                if preCancelled { withUnsafeCurrentTask { $0?.cancel() } }
                return await fixture.buildResult(request)
            }
            try #require(await held.waitForEntry())
            let entry = try #require(fixture.owner.pendingStudioDraft)
            build.cancel()
            await held.release()
            let result = await build.value
            guard case .staged(let draft, let outcome) = result else {
                Issue.record("Typed cancellation must still publish")
                return
            }
            #expect(draft == entry)
            Self.expectTypedBuildOutcome(outcome, blockedParent: blockedParent)
            #expect(fixture.owner.pendingStudioDraft == entry, "typed cancellation does not roll back")
            #expect(await fixture.forwarding.snapshots == [entry], "no cancellation restoration save")
            if blockedParent {
                #expect(try Data(contentsOf: parent) == bytes)
                try FileManager.default.removeItem(at: parent)
            }
            // Typed staging also remains settled: a later cancelled prepared commit restores it.
            let nextGate = await fixture.forwarding.hold(.afterSave(2))
            let other = fixture.draft(1)
            let commit = fixture.start { await fixture.commitResult(other) }
            try #require(await nextGate.waitForEntry())
            commit.cancel()
            await nextGate.release()
            #expect(await commit.value == .notPublished)
            #expect(fixture.owner.pendingStudioDraft == entry)
            #expect(await fixture.forwarding.snapshots == [entry, other, entry])
            #expect(await fixture.store.load() == .loaded(entry))
        }
    }
}

extension PendingStudioPatchPersistenceTests {
    private static let typedSaveWarning = "The draft is ready to review, but its save was not confirmed. "
        + "It may be unavailable after restarting."

    private static func expectTypedBuildOutcome(
        _ outcome: PendingStudioPatchMutationOutcome, blockedParent: Bool
    ) {
        if blockedParent {
            guard case .directoryPreparationFailed = outcome else {
                Issue.record("Expected real blocked-parent failure, got \(outcome)")
                return
            }
            #expect(!outcome.completed)
        } else {
            #expect(outcome == .writeCompleted)
        }
    }

    private static func typedBuildText(_ draft: StudioPatchDraft) throws -> String {
        try AssistantFallbackResponder.response(
            to: .live("Build pending draft", requires: [.pendingDraft]), groundedBy: [.pendingDraft(draft)])
    }

    private static func typedBuildCards(_ draft: StudioPatchDraft) -> [AssistantCard] {
        var cards: [AssistantCard] = [
            .wiring(summary: draft.logicalRoutingSummary.map(\.value),
                    cableInstructions: draft.cableInstructions.map(\.instruction.value)),
            .pendingDraft(id: draft.id, summary: draft.logicalRoutingSummary.map(\.value).joined(separator: "\n"),
                          hasErrors: draft.hasErrors)
        ]
        if !draft.validation.isEmpty { cards.append(.conflicts(draft.validation.map(\.message))) }
        return cards
    }

    private static func withTypedBuildChat(
        _ body: @MainActor (
            PendingPersistenceFixture, AssistantFixtureReplyGenerator, AssistantChatController
        ) async throws -> Void
    ) async throws {
        try await PendingPersistenceFixture.run { fixture in
            try await withAssistantFixtureResources { resources in
                let generator = AssistantFixtureReplyGenerator()
                let chat = AssistantChatController(
                    coordinator: fixture.owner,
                    store: AssistantConversationStore(local: TypedBuildHistory(), cloud: nil),
                    generator: generator, actionInterpreter: TypedBuildInterpreter(),
                    spokenRepliesDefaults: try resources.defaults("typed-build-chat"))
                resources.onFinish {
                    generator.close()
                    chat.cancel()
                    await fixture.forwarding.finish()
                    await generator.join()
                    await chat.awaitOwnedWorkSnapshot()
                }
                try await body(fixture, generator, chat)
            }
        }
    }
}

// Only history is faked; typed chat must never ask an interpreter or provider to build its draft.
private struct TypedBuildInterpreter: AssistantActionInterpreting {
    func availability() async -> AssistantActionInterpreterAvailability { .available }
    func interpret(_ request: AssistantActionInterpretationRequest) async throws -> AssistantActionInterpretation {
        Issue.record("Typed wiring must not interpret natural language")
        return .routing(AssistantRoutingIntent(branches: []))
    }
}

private actor TypedBuildHistory: AssistantHistoryBackend {
    func loadRecords() -> [AssistantConversationRecord] { [] }
    func save(_ record: AssistantConversationRecord) {}
}
