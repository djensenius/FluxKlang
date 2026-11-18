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

// A build or validate reports its draft only if no other mutation replaced it during the save.
extension PendingStudioPatchPersistenceTests {
    @Test func buildOvertakenByDiscardReportsNoDraft() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let gate = await fixture.forwarding.hold(.beforeSave(1))
            let build = fixture.start { await fixture.owner.perform(Self.buildTool(fixture), context: fixture.context) }
            try #require(await gate.waitForEntry())
            let built = try #require(fixture.owner.pendingStudioDraft)
            await fixture.owner.discardPendingStudioDraft()
            await gate.release()
            let result = await build.value
            #expect(Self.reportedDraft(result) == .some(nil), "an overtaken build never reports its draft")
            #expect(fixture.owner.pendingStudioDraft == nil)
            #expect(await fixture.store.load() == .absent)
            #expect(await fixture.forwarding.snapshots == [built, nil, nil])
        }
    }

    @Test func validateOvertakenByCommitReportsNoDraft() async throws {
        try await PendingPersistenceFixture.run { fixture in
            _ = try await fixture.build()
            let gate = await fixture.forwarding.hold(.beforeSave(2))
            let validate = fixture.start {
                await fixture.owner.perform(.validatePendingStudioDraft, context: fixture.context)
            }
            try #require(await gate.waitForEntry())
            let refreshed = try #require(fixture.owner.pendingStudioDraft)
            // Same id, different content: only full equality can tell the commit apart.
            var edited = refreshed
            try #require(!edited.fragment.nodes.isEmpty)
            edited.fragment.nodes[0].node.position.x += 40
            try #require(edited.id == refreshed.id && edited != refreshed)
            #expect(await fixture.commit(edited))
            await gate.release()
            let result = await validate.value
            #expect(Self.reportedDraft(result) == .some(nil), "an overtaken validate never reports refreshed")
            #expect(fixture.owner.pendingStudioDraft == edited)
            #expect(await fixture.store.load() == .loaded(edited))
            #expect(await fixture.forwarding.snapshots.dropFirst() == [refreshed, edited, edited])
        }
    }

    @Test func buildOvertakenByNewerBuildReportsNoDraft() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let gate = await fixture.forwarding.hold(.beforeSave(1))
            let first = fixture.start { await fixture.owner.perform(Self.buildTool(fixture), context: fixture.context) }
            try #require(await gate.waitForEntry())
            let older = try #require(fixture.owner.pendingStudioDraft)
            let second = await fixture.owner.perform(Self.buildTool(fixture, source: 1), context: fixture.context)
            let newer = try #require(fixture.owner.pendingStudioDraft)
            try #require(newer != older)
            #expect(Self.reportedDraft(second) == .some(newer), "the newer build reports its own draft")
            await gate.release()
            let result = await first.value
            #expect(Self.reportedDraft(result) == .some(nil), "the older build never reports another draft")
            #expect(fixture.owner.pendingStudioDraft == newer)
            #expect(await fixture.store.load() == .loaded(newer))
            #expect(await fixture.forwarding.snapshots == [older, newer, newer])
        }
    }

    @Test func unovertakenBuildAndValidateReportTheirDraft() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let build = await fixture.owner.perform(Self.buildTool(fixture), context: fixture.context)
            let built = try #require(fixture.owner.pendingStudioDraft)
            #expect(Self.reportedDraft(build) == .some(built))
            let validate = await fixture.owner.perform(.validatePendingStudioDraft, context: fixture.context)
            let refreshed = try #require(fixture.owner.pendingStudioDraft)
            #expect(Self.reportedDraft(validate) == .some(refreshed))
            #expect(await fixture.store.load() == .loaded(refreshed))
            #expect(await fixture.forwarding.snapshots == [built, refreshed])
        }
    }

    private static func buildTool(_ fixture: PendingPersistenceFixture, source: Int = 0) -> AssistantTool {
        .buildStudioDraft(.init(sourceInstrumentIDs: [fixture.context.equipment[source].id]))
    }

    // `.some(nil)` is an explicit "no draft"; plain `nil` means the result was not a pending-draft result.
    private static func reportedDraft(_ result: AssistantToolResult) -> StudioPatchDraft?? {
        guard case .pendingDraft(let draft) = result else { return nil }
        return .some(draft)
    }
}

// A fallback validate reply shows cards only for the draft its own validate reported.
extension PendingStudioPatchPersistenceTests {
    @Test func overtakenFallbackValidateShowsNoOtherDraftCards() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let gate = await fixture.forwarding.hold(.beforeSave(2))
            let reply = fixture.start { await Self.collectReply(fixture) }
            try #require(await gate.waitForEntry())
            let refreshed = try #require(fixture.owner.pendingStudioDraft)
            let newer = try await fixture.build(1)
            try #require(newer != refreshed)
            await gate.release()
            let collected = await reply.value
            #expect(!collected.failed)
            #expect(collected.texts == ["There is no pending Studio draft."])
            #expect(collected.cards.isEmpty, "an overtaken validate shows no other request's draft cards")
            #expect(fixture.owner.pendingStudioDraft == newer)
            #expect(await fixture.store.load() == .loaded(newer))
            #expect(await fixture.forwarding.snapshots == [built, refreshed, newer, newer])
        }
    }

    @Test func unovertakenFallbackValidateShowsItsDraftCards() async throws {
        try await PendingPersistenceFixture.run { fixture in
            _ = try await fixture.build()
            let collected = await Self.collectReply(fixture)
            let refreshed = try #require(fixture.owner.pendingStudioDraft)
            #expect(!collected.failed)
            #expect(collected.texts.count == 1)
            #expect(collected.cards.count == 1)
            let summary = refreshed.logicalRoutingSummary.map(\.value).joined(separator: "\n")
            let own = AssistantCard.pendingDraft(id: refreshed.id, summary: summary, hasErrors: refreshed.hasErrors)
            #expect(collected.cards.first?.contains(own) == true, "an unovertaken validate shows its own draft card")
        }
    }

    private struct CollectedReply: Sendable {
        var texts: [String] = []
        var cards: [[AssistantCard]] = []
        var failed = false
    }

    // Drains the whole stream before returning; stream events are not Equatable, so match them by pattern.
    private static func collectReply(
        _ fixture: PendingPersistenceFixture, from generator: (any AssistantGenerating)? = nil,
        question: String = "Show the pending draft"
    ) async -> CollectedReply {
        let request = AssistantGenerationRequest(
            question: question, recentMessages: [], summary: "", context: fixture.context)
        var reply = CollectedReply()
        let generator = generator ?? AssistantFallbackGenerator(coordinator: fixture.owner)
        do {
            for try await event in generator.stream(request) {
                switch event {
                case .text(let text): reply.texts.append(text)
                case .cards(let cards): reply.cards.append(cards)
                }
            }
        } catch {
            reply.failed = true
        }
        return reply
    }
}

// A Copilot reply is only the model's own text, whatever another request did to the pending draft meanwhile.
extension PendingStudioPatchPersistenceTests {
    // Without a draft at the start, the newer build is the only draft the reply could claim.
    @Test(arguments: [true, false])
    func copilotReplyOvertakenByNewerBuildShowsOnlyItsText(startsWithDraft: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            var built: StudioPatchDraft?
            if startsWithDraft { built = try await fixture.build() }
            let http = OvertakingCopilotHTTP { _ = try? await fixture.build(1) }
            let reply = await Self.copilotReply(fixture, http)
            let newer = try #require(fixture.owner.pendingStudioDraft)
            try #require(newer.id != built?.id, "the newer build has its own id")
            let saved: [StudioPatchDraft?] = startsWithDraft ? [built, newer] : [newer]
            #expect(!reply.failed)
            #expect(reply.texts == [OvertakingCopilotHTTP.answer])
            #expect(reply.cards.isEmpty, "an overtaken Copilot reply shows no other request's draft cards")
            #expect(await fixture.store.load() == .loaded(newer))
            #expect(await fixture.forwarding.snapshots == saved)
            #expect(await http.requests == 1)
        }
    }

    @Test func copilotReplyOvertakenBySameIDCommitShowsOnlyItsText() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            // Same id, different content: a check by id alone would miss this commit.
            var edited = built
            try #require(!edited.fragment.nodes.isEmpty)
            edited.fragment.nodes[0].node.position.x += 40
            try #require(edited.id == built.id && edited != built)
            let http = OvertakingCopilotHTTP { [edited] in #expect(await fixture.commit(edited)) }
            let reply = await Self.copilotReply(fixture, http)
            #expect(!reply.failed)
            #expect(reply.texts == [OvertakingCopilotHTTP.answer])
            #expect(reply.cards.isEmpty, "a Copilot reply overtaken by a commit shows no draft cards")
            #expect(fixture.owner.pendingStudioDraft == edited)
            #expect(await fixture.store.load() == .loaded(edited))
            #expect(await fixture.forwarding.snapshots == [built, edited])
        }
    }

    // Characterisation: without a newer draft, the reply was already only the model's text.
    @Test(arguments: [false, true])
    func copilotReplyWithoutNewerDraftShowsOnlyItsText(discards: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let http = OvertakingCopilotHTTP { if discards { await fixture.owner.discardPendingStudioDraft() } }
            let reply = await Self.copilotReply(fixture, http)
            let saved: [StudioPatchDraft?] = discards ? [built, nil] : [built]
            #expect(!reply.failed)
            #expect(reply.texts == [OvertakingCopilotHTTP.answer])
            #expect(reply.cards.isEmpty)
            #expect(fixture.owner.pendingStudioDraft == (discards ? nil : built))
            #expect(await fixture.store.load() == (discards ? .absent : .loaded(built)))
            #expect(await fixture.forwarding.snapshots == saved)
        }
    }

    // "Is the WING connected?" is read-only, so routing ownership passes it to the model.
    private static func copilotReply(
        _ fixture: PendingPersistenceFixture, _ http: OvertakingCopilotHTTP
    ) async -> CollectedReply {
        let generator = CopilotAssistantGenerator(
            configuration: CopilotAssistantConfiguration(token: "token", model: "gpt-4o"),
            coordinator: fixture.owner, httpClient: http)
        return await collectReply(fixture, from: generator, question: "Is the WING connected?")
    }
}
