import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PendingStudioPatchPersistenceTests {
    @Test(arguments: [false, true], [false, true])
    func validationAcknowledgementFallback(blockedParent: Bool, validationErrors: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await Self.seedValidation(fixture, errors: validationErrors)
            let bytes = try Self.blockValidationParent(fixture, blocked: blockedParent)
            let reply = await Self.collectReply(fixture)
            await fixture.fallbackWork.join()
            let draft = try #require(fixture.owner.pendingStudioDraft)
            #expect(!reply.failed)
            #expect(reply.texts == [try Self.validationText(draft, blocked: blockedParent)])
            #expect(reply.cards == [Self.validationCards(draft)])
            #expect(draft.hasErrors == validationErrors)
            #expect(await fixture.forwarding.snapshots == [built, draft])
            #expect(fixture.owner.openReview(ofDraft: draft.id))
            if blockedParent {
                #expect(try Data(contentsOf: fixture.file.deletingLastPathComponent()) == bytes)
            } else {
                #expect(await fixture.store.load() == .loaded(draft))
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func validationAcknowledgementActualChat(blockedParent: Bool, validationErrors: Bool) async throws {
        try await Self.withValidationChat { fixture, chat in
            let built = try await Self.seedValidation(fixture, errors: validationErrors)
            let bytes = try Self.blockValidationParent(fixture, blocked: blockedParent)
            chat.composer = "Show the pending draft"
            chat.send(context: fixture.context)
            await chat.awaitOwnedWorkSnapshot()
            await fixture.fallbackWork.join()
            let draft = try #require(fixture.owner.pendingStudioDraft)
            let reply = try #require(chat.selectedConversation?.messages.last)
            #expect(reply.role == .assistant && reply.state == .complete)
            #expect(reply.text == (try Self.validationText(draft, blocked: blockedParent)))
            #expect(reply.text.components(separatedBy: Self.validationWarning).count == (blockedParent ? 2 : 1))
            #expect(reply.cards == Self.validationCards(draft))
            #expect(draft.hasErrors == validationErrors)
            #expect(await fixture.forwarding.snapshots == [built, draft])
            #expect(fixture.owner.navigationTarget == nil)
            #expect(fixture.owner.openReview(ofDraft: draft.id))
            if blockedParent {
                #expect(try Data(contentsOf: fixture.file.deletingLastPathComponent()) == bytes)
            } else {
                #expect(await fixture.store.load() == .loaded(draft))
            }
        }
    }
}

extension PendingStudioPatchPersistenceTests {
    @Test(arguments: [false, true])
    func validationAcknowledgementHeldFailureKeepsOwnOutcome(equalValueABA: Bool) async throws {
        try await Self.withValidationChat { fixture, chat in
            let built = try await fixture.build()
            let bytes = try Self.blockValidationParent(fixture)
            let held = await fixture.forwarding.hold(.afterSave(2))
            chat.composer = "Show the pending draft"
            chat.send(context: fixture.context)
            try #require(await held.waitForEntry())
            let entry = try #require(fixture.owner.pendingStudioDraft)
            let attempt = try fixture.attempt()
            let preserved = fixture.root.appendingPathComponent("preserved")
            try FileManager.default.moveItem(at: fixture.file.deletingLastPathComponent(), to: preserved)
            var other = entry
            other.createdAt = entry.createdAt.addingTimeInterval(1)
            try #require(other.id == entry.id && other != entry)
            #expect(await fixture.commitResult(other) == .staged(draft: other, storageOutcome: .writeCompleted))
            if equalValueABA {
                #expect(await fixture.commitResult(entry) == .staged(draft: entry, storageOutcome: .writeCompleted))
            }
            // This unrelated later read replaces diagnostics but must not become A's acknowledgement.
            await fixture.owner.load()
            let latest = try fixture.attempt()
            #expect(latest.observation == .load(.loaded(equalValueABA ? entry : other)))
            await held.release()
            await chat.awaitOwnedWorkSnapshot()
            await fixture.fallbackWork.join()
            let reply = try #require(chat.selectedConversation?.messages.last)
            #expect(reply.role == .assistant && reply.state == .complete)
            #expect(reply.text == (try Self.validationText(equalValueABA ? entry : nil, blocked: equalValueABA)))
            #expect(reply.cards == (equalValueABA ? Self.validationCards(entry) : []))
            #expect(reply.text.components(separatedBy: Self.validationWarning).count == (equalValueABA ? 2 : 1))
            #expect(fixture.owner.latestStorageAttempt === latest)
            #expect(fixture.owner.pendingStudioDraft == (equalValueABA ? entry : other))
            guard case .mutation(entry, .some(.directoryPreparationFailed)) = attempt.observation else {
                Issue.record("Expected A's historical real save failure")
                return
            }
            #expect(await fixture.forwarding.snapshots ==
                (equalValueABA ? [built, entry, other, entry] : [built, entry, other]), "failure stops catch-up")
            #expect(try Data(contentsOf: preserved) == bytes)
            #expect(await fixture.store.load() == .loaded(equalValueABA ? entry : other))
        }
    }

    @Test(arguments: [false, true])
    func validationAcknowledgementFallbackCancellationSuppressesOutput(blockedParent: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let bytes = try Self.blockValidationParent(fixture, blocked: blockedParent)
            let held = await fixture.forwarding.hold(.afterSave(2))
            let consumer = fixture.start { await Self.collectReply(fixture) }
            try #require(await held.waitForEntry())
            let entry = try #require(fixture.owner.pendingStudioDraft)
            let attempt = try fixture.attempt()
            consumer.cancel()
            let reply = await consumer.value
            #expect(reply.texts.isEmpty && reply.cards.isEmpty)
            #expect(attempt.observation == .mutation(snapshot: entry, outcome: nil),
                    "consumer termination is not a producer join")
            await held.release()
            await fixture.fallbackWork.join()
            #expect(fixture.owner.pendingStudioDraft == entry)
            #expect(await fixture.forwarding.snapshots == [built, entry])
            if blockedParent {
                #expect(try Data(contentsOf: fixture.file.deletingLastPathComponent()) == bytes)
                guard case .mutation(entry, .some(.directoryPreparationFailed)) = attempt.observation else {
                    Issue.record("Cancelled output must retain the real failed storage effect")
                    return
                }
            } else {
                #expect(attempt.observation == .mutation(snapshot: entry, outcome: .writeCompleted))
                #expect(await fixture.store.load() == .loaded(entry))
            }
        }
    }

    @Test(arguments: [false, true])
    func validationAcknowledgementChatCancellationSuppressesOutput(blockedParent: Bool) async throws {
        try await Self.withValidationChat { fixture, chat in
            let built = try await fixture.build()
            let bytes = try Self.blockValidationParent(fixture, blocked: blockedParent)
            let held = await fixture.forwarding.hold(.afterSave(2))
            chat.composer = "Show the pending draft"
            chat.send(context: fixture.context)
            try #require(await held.waitForEntry())
            let entry = try #require(fixture.owner.pendingStudioDraft)
            let attempt = try fixture.attempt()
            chat.cancel()
            await chat.awaitOwnedWorkSnapshot()
            let before = try #require(chat.selectedConversation?.messages)
            #expect(attempt.observation == .mutation(snapshot: entry, outcome: nil),
                    "chat's join deliberately excludes the actual fallback producer")
            await held.release()
            await fixture.fallbackWork.join()
            await chat.awaitOwnedWorkSnapshot()
            #expect(chat.selectedConversation?.messages == before, "no later warning, text or cards")
            let reply = try #require(before.last)
            #expect(reply.role == .assistant && reply.text.isEmpty && reply.cards.isEmpty)
            #expect(!chat.isStreaming)
            #expect(fixture.owner.pendingStudioDraft == entry)
            #expect(await fixture.forwarding.snapshots == [built, entry])
            if blockedParent {
                #expect(try Data(contentsOf: fixture.file.deletingLastPathComponent()) == bytes)
                guard case .mutation(entry, .some(.directoryPreparationFailed)) = attempt.observation else {
                    Issue.record("Cancelled chat must retain the real failed storage effect")
                    return
                }
            } else {
                #expect(attempt.observation == .mutation(snapshot: entry, outcome: .writeCompleted))
                #expect(await fixture.store.load() == .loaded(entry))
            }
        }
    }
}

extension PendingStudioPatchPersistenceTests {
    static let validationWarning = "The draft is ready to review, but its save was not confirmed. "
        + "It may be unavailable after restarting."

    static func seedValidation(
        _ fixture: PendingPersistenceFixture, errors: Bool = false
    ) async throws -> StudioPatchDraft {
        if errors {
            _ = await fixture.buildResult(.init(sourceInstrumentIDs: []))
            return try #require(fixture.owner.pendingStudioDraft)
        }
        return try await fixture.build()
    }

    static func blockValidationParent(_ fixture: PendingPersistenceFixture, blocked: Bool = true) throws -> Data {
        let bytes = Data("owned revalidation obstruction".utf8)
        if blocked {
            let parent = fixture.file.deletingLastPathComponent()
            try FileManager.default.removeItem(at: parent)
            try bytes.write(to: parent)
        }
        return bytes
    }

    static func validationText(_ draft: StudioPatchDraft?, blocked: Bool = false) throws -> String {
        let text = try AssistantFallbackResponder.response(
            to: .live("Show the pending draft", requires: [.pendingDraft]), groundedBy: [.pendingDraft(draft)])
        return blocked ? text + "\n\n" + validationWarning : text
    }

    static func validationCards(_ draft: StudioPatchDraft) -> [AssistantCard] {
        var cards: [AssistantCard] = [
            .wiring(summary: draft.logicalRoutingSummary.map(\.value),
                    cableInstructions: draft.cableInstructions.map(\.instruction.value)),
            .pendingDraft(id: draft.id, summary: draft.logicalRoutingSummary.map(\.value).joined(separator: "\n"),
                          hasErrors: draft.hasErrors)
        ]
        if !draft.validation.isEmpty { cards.append(.conflicts(draft.validation.map(\.message))) }
        return cards
    }

    static func withValidationChat(
        _ body: @MainActor (PendingPersistenceFixture, AssistantChatController) async throws -> Void
    ) async throws {
        try await PendingPersistenceFixture.run { fixture in
            try await withAssistantFixtureResources { resources in
                let chat = AssistantChatController(
                    coordinator: fixture.owner,
                    store: AssistantConversationStore(local: ValidationHistory(), cloud: nil),
                    generator: fixture.fallbackGenerator(), actionInterpreter: ValidationInterpreter(),
                    spokenRepliesDefaults: try resources.defaults("validation-chat"))
                resources.onFinish {
                    chat.cancel()
                    await fixture.forwarding.finish()
                    await chat.awaitOwnedWorkSnapshot()
                    fixture.fallbackWork.cancel()
                    await fixture.fallbackWork.join()
                }
                try await body(fixture, chat)
            }
        }
    }
}

// Inert history/interpretation boundaries only; fallback, revalidation, persistence and chat are real.
private struct ValidationInterpreter: AssistantActionInterpreting {
    func availability() async -> AssistantActionInterpreterAvailability { .available }
    func interpret(_ request: AssistantActionInterpretationRequest) async throws -> AssistantActionInterpretation {
        Issue.record("A pending-draft query must not interpret an action")
        return .routing(AssistantRoutingIntent(branches: []))
    }
}

private actor ValidationHistory: AssistantHistoryBackend {
    func loadRecords() -> [AssistantConversationRecord] { [] }
    func save(_ record: AssistantConversationRecord) {}
}
