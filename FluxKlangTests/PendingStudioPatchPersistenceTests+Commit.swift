import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PendingStudioPatchPersistenceTests {
    @Test(arguments: [false, true])
    func preparedCommitAcknowledgementOwnOutcomeAndBoolCompatibility(encodingFailure: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let original = try await fixture.build()
            let bytes = try Data(contentsOf: fixture.file)
            var draft = fixture.draft(1)
            if encodingFailure { draft.fragment.nodes[0].node.position.x = .infinity }
            let outcome: PendingStudioPatchMutationOutcome = encodingFailure ? .encodingFailed : .writeCompleted
            #expect(await fixture.commitResult(draft) == .staged(draft: draft, storageOutcome: outcome))
            #expect(fixture.owner.pendingStudioDraft == draft)
            #expect(await fixture.store.load() == .loaded(encodingFailure ? original : draft))
            if encodingFailure { #expect(try Data(contentsOf: fixture.file) == bytes) }
            #expect(await fixture.commit(draft), "Bool still means staged, even when encoding fails")
            #expect(await fixture.forwarding.snapshots == [original, draft, draft], "one save per delegation")
            #expect(await fixture.owner.commitPreparedRoutingResult(
                original, expectedPending: nil, preparedContext: fixture.context, currentContext: fixture.context
            ) == .notPublished)
            #expect(!(await fixture.owner.commitPreparedRouting(
                original, expectedPending: nil, preparedContext: fixture.context, currentContext: fixture.context)))
            #expect(await fixture.forwarding.snapshots == [original, draft, draft], "rejection does not save")
            let text = AssistantDraftReply.text(for: draft)
            #expect(AssistantDraftReply.acknowledgingSave(text, outcome: outcome) ==
                (encodingFailure ? text + "\n\n" + Self.saveWarning : text))
        }
    }

    @Test(arguments: [false, true])
    func preparedCommitAcknowledgementRealChatKeepsOwnCards(blockedParent: Bool) async throws {
        try await Self.withPreparedCommitChat { fixture, generator, chat, context in
            let parent = fixture.file.deletingLastPathComponent()
            let bytes = Data("owned chat obstruction".utf8)
            if blockedParent { try bytes.write(to: parent) }
            chat.composer = "route First to mains"
            chat.send(context: context)
            await chat.awaitOwnedWorkSnapshot()
            let draft = try #require(fixture.owner.pendingStudioDraft)
            let reply = try #require(chat.selectedConversation?.messages.last)
            #expect(reply.role == .assistant && reply.state == .complete)
            let text = AssistantDraftReply.text(for: draft)
            #expect(reply.text == (blockedParent ? text + "\n\n" + Self.saveWarning : text))
            #expect(reply.text.components(separatedBy: Self.saveWarning).count == (blockedParent ? 2 : 1))
            #expect(reply.cards == Self.preparedCommitCards(draft))
            #expect(generator.calls == 0)
            #expect(await fixture.forwarding.snapshots == [draft])
            if blockedParent {
                guard case .mutation(draft, .some(.directoryPreparationFailed)) =
                    try fixture.attempt().observation else {
                    Issue.record("Expected this draft's real blocked-parent failure")
                    return
                }
                #expect(try Data(contentsOf: parent) == bytes)
                #expect(await fixture.store.load() == .readFailed(.notDirectory))
            } else {
                #expect(await fixture.store.load() == .loaded(draft))
            }
        }
    }

    @Test(arguments: [false, true])
    func preparedCommitAcknowledgementHeldFailedChatCannotBorrowNewerSave(equalValueABA: Bool) async throws {
        try await Self.withPreparedCommitChat { fixture, generator, chat, context in
            let parent = fixture.file.deletingLastPathComponent()
            let bytes = Data("owned held chat obstruction".utf8)
            try bytes.write(to: parent)
            let held = await fixture.forwarding.hold(.afterSave(1))
            chat.composer = "route First to mains"
            chat.send(context: context)
            try #require(await held.waitForEntry())
            let first = try #require(fixture.owner.pendingStudioDraft)
            let attempt = try fixture.attempt()
            let preserved = fixture.root.appendingPathComponent("preserved")
            try FileManager.default.moveItem(at: parent, to: preserved)
            // Same id but different full value: publication must not compare only ids.
            var newer = first
            newer.createdAt = first.createdAt.addingTimeInterval(1)
            try #require(newer.id == first.id && newer != first)
            #expect(await fixture.owner.commitPreparedRoutingResult(
                newer, expectedPending: first, preparedContext: context, currentContext: context
            ) == .staged(draft: newer, storageOutcome: .writeCompleted))
            if equalValueABA {
                #expect(await fixture.owner.commitPreparedRoutingResult(
                    first, expectedPending: newer, preparedContext: context, currentContext: context
                ) == .staged(draft: first, storageOutcome: .writeCompleted))
            }
            let latest = try fixture.attempt()
            await held.release()
            await chat.awaitOwnedWorkSnapshot()
            let reply = try #require(chat.selectedConversation?.messages.last)
            #expect(reply.state == .complete)
            #expect(reply.text == (equalValueABA
                ? AssistantDraftReply.text(for: first) + "\n\n" + Self.saveWarning
                : AssistantRoutingOwnership.clarification))
            #expect(reply.cards == (equalValueABA ? Self.preparedCommitCards(first) : []))
            #expect(fixture.owner.pendingStudioDraft == (equalValueABA ? first : newer))
            #expect(await fixture.store.load() == .loaded(equalValueABA ? first : newer))
            #expect(fixture.owner.latestStorageAttempt === latest)
            guard case .mutation(first, .some(.directoryPreparationFailed)) = attempt.observation else {
                Issue.record("Expected the held invocation's own failure")
                return
            }
            #expect(await fixture.forwarding.snapshots ==
                (equalValueABA ? [first, newer, first] : [first, newer]), "failure stops catch-up")
            #expect(try Data(contentsOf: preserved) == bytes)
            #expect(generator.calls == 0)
        }
    }

    @Test(arguments: [false, true])
    func preparedCommitAcknowledgementDifferentCatchUpCannotAcknowledgeEntry(returnToEntry: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let entry = fixture.draft()
            let held = await fixture.forwarding.hold(.afterSave(1))
            let first = fixture.start { await fixture.commitResult(entry) }
            try #require(await held.waitForEntry())
            var other = fixture.draft(1)
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
            #expect(await first.value == (returnToEntry
                ? .staged(draft: entry, storageOutcome: .writeCompleted) : .notPublished))
            #expect(attempt.observation == .mutation(snapshot: other, outcome: .encodingFailed))
            #expect(await fixture.forwarding.snapshots ==
                (returnToEntry ? [entry, other, other, entry] : [entry, other, other]))
            #expect(fixture.owner.pendingStudioDraft == (returnToEntry ? entry : other))
            #expect(await fixture.store.load() == .loaded(entry))
        }
    }

    @Test func preparedCommitAcknowledgementLatestSameSnapshotOutcomeWins() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let entry = fixture.draft()
            let held = await fixture.forwarding.hold(.afterSave(1))
            let first = fixture.start { await fixture.commitResult(entry) }
            try #require(await held.waitForEntry())
            let other = fixture.draft(1)
            #expect(await fixture.commitResult(other) == .staged(draft: other, storageOutcome: .writeCompleted))
            let catchUp = await fixture.forwarding.hold(.afterSave(3))
            await held.release()
            try #require(await catchUp.waitForEntry())
            #expect(await fixture.commitResult(entry) == .staged(draft: entry, storageOutcome: .writeCompleted))
            let parent = fixture.file.deletingLastPathComponent()
            try FileManager.default.removeItem(at: parent)
            let bytes = Data("owned same-snapshot obstruction".utf8)
            try bytes.write(to: parent)
            await catchUp.release()
            let result = await first.value
            guard case .staged(let draft, let outcome) = result,
                  case .directoryPreparationFailed = outcome else {
                Issue.record("Expected the invocation's later same-snapshot failure, got \(result)")
                return
            }
            #expect(draft == entry)
            #expect(fixture.owner.pendingStudioDraft == entry)
            #expect(await fixture.forwarding.snapshots == [entry, other, other, entry, entry])
            #expect(try Data(contentsOf: parent) == bytes)
            #expect(AssistantDraftReply.acknowledgingSave("Review.", outcome: outcome) ==
                "Review.\n\n" + Self.saveWarning)
        }
    }

    @Test(arguments: [false, true])
    func preparedCommitAcknowledgementCancellationRestorationDoesNotPublish(blockedParent: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let settled = try await fixture.build()
            let parent = fixture.file.deletingLastPathComponent()
            let bytes = Data("owned cancellation obstruction".utf8)
            if blockedParent {
                try FileManager.default.removeItem(at: parent)
                try bytes.write(to: parent)
            }
            let entry = fixture.draft(1)
            let held = await fixture.forwarding.hold(.afterSave(2))
            let commit = fixture.start { await fixture.commitResult(entry) }
            try #require(await held.waitForEntry())
            let attempt = try fixture.attempt()
            commit.cancel()
            await held.release()
            #expect(await commit.value == .notPublished)
            #expect(fixture.owner.pendingStudioDraft == settled)
            let restoration = try fixture.attempt()
            #expect(restoration !== attempt, "restoration is a separate persistence invocation")
            #expect(await fixture.forwarding.snapshots == [settled, entry, settled])
            if blockedParent {
                #expect(try Data(contentsOf: parent) == bytes)
                guard case .mutation(settled, .some(.directoryPreparationFailed)) = restoration.observation else {
                    Issue.record("Expected failed restoration to remain non-publishing")
                    return
                }
            } else {
                #expect(restoration.observation == .mutation(snapshot: settled, outcome: .writeCompleted))
                #expect(await fixture.store.load() == .loaded(settled))
            }
        }
    }
}

extension PendingStudioPatchPersistenceTests {
    private static let saveWarning = "The draft is ready to review, but its save was not confirmed. "
        + "It may be unavailable after restarting."

    private static func preparedCommitCards(_ draft: StudioPatchDraft) -> [AssistantCard] {
        var cards: [AssistantCard] = [
            .wiring(summary: draft.logicalRoutingSummary.map(\.value),
                    cableInstructions: draft.cableInstructions.map(\.instruction.value)),
            .pendingDraft(id: draft.id, summary: draft.logicalRoutingSummary.map(\.value).joined(separator: "\n"),
                          hasErrors: draft.hasErrors)
        ]
        if !draft.validation.isEmpty { cards.append(.conflicts(draft.validation.map(\.message))) }
        return cards
    }

    private static func withPreparedCommitChat(
        _ body: @MainActor (
            PendingPersistenceFixture, AssistantFixtureReplyGenerator, AssistantChatController, AssistantToolContext
        ) async throws -> Void
    ) async throws {
        try await PendingPersistenceFixture.run { fixture in
            try await withAssistantFixtureResources { resources in
                // Natural-language routing needs an actual saved destination, unlike the typed build fixture.
                var context = fixture.context
                context.globalConnections.home.outputs = [
                    .init(connector: 3, destinationName: "Main Speakers L"),
                    .init(connector: 4, destinationName: "Main Speakers R")
                ]
                context.homeConnections = context.globalConnections.home
                context.effectiveConnections = context.globalConnections.effectiveHome
                let generator = AssistantFixtureReplyGenerator()
                let chat = AssistantChatController(
                    coordinator: fixture.owner,
                    store: AssistantConversationStore(local: PreparedCommitHistory(), cloud: nil),
                    generator: generator, actionInterpreter: PreparedCommitInterpreter(),
                    spokenRepliesDefaults: try resources.defaults("prepared-commit-chat"))
                resources.onFinish {
                    // Release the real store gates before joining chat, including on a throwing assertion.
                    generator.close()
                    chat.cancel()
                    await fixture.forwarding.finish()
                    await generator.join()
                    await chat.awaitOwnedWorkSnapshot()
                }
                try await body(fixture, generator, chat, context)
            }
        }
    }
}

// Only interpretation/history are faked; preparation, commit, file IO and chat publication are real.
private struct PreparedCommitInterpreter: AssistantActionInterpreting {
    func availability() async -> AssistantActionInterpreterAvailability { .available }
    func interpret(_ request: AssistantActionInterpretationRequest) async throws -> AssistantActionInterpretation {
        .routing(AssistantRoutingIntent(branches: [
            .init(source: "First", destination: "mains", destinationEvidence: "First to mains")
        ]))
    }
}

private actor PreparedCommitHistory: AssistantHistoryBackend {
    func loadRecords() -> [AssistantConversationRecord] { [] }
    func save(_ record: AssistantConversationRecord) {}
}
