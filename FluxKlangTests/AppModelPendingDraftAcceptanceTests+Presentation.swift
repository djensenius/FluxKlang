import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AppModelPendingDraftAcceptanceTests {
    @Test func acceptanceLocalWriteWarningStaysWithRetainedPublication() async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare()
            try fixture.blockEnvironmentFile()
            model.assistant.navigationTarget = .reviewPendingDraft
            let gate = await fixture.forwarding.hold(.afterSave(2))
            let acceptance = fixture.presentation.accept(using: model)
            try #require(await gate.waitForEntry())
            let duplicate = fixture.presentation.accept(using: model)
            await gate.release()
            await acceptance.value
            await duplicate.value
            let retained = try #require(model.assistant.pendingStudioDraft)
            #expect(model.assistant.navigationTarget == .reviewPendingDraft)
            #expect(fixture.presentation.warning == .localWriteUnconfirmed)
            #expect(try fixture.readPendingDraft() == retained)
            #expect(await fixture.forwarding.snapshots == [built, retained])
            await fixture.presentation.accept(using: model).value
            #expect(fixture.presentation.warning == .localWriteUnconfirmed)
            #expect(await fixture.forwarding.snapshots == [built, retained])

            let context = model.assistantToolContext()
            let replaced = await model.assistant.commitPreparedRouting(
                retained, expectedPending: retained, preparedContext: context, currentContext: context)
            try #require(replaced)
            try #require(model.assistant.pendingStudioDraft == retained, "equal value, different publication")
            #expect(fixture.presentation.warning == nil, "even before Studio receives onChange")
            #expect(await fixture.forwarding.snapshots == [built, retained, retained])
        }
    }

    @Test(arguments: ["saved", "absent", "blocked"], [false, true])
    func acceptanceActualPresentation(storage: String, replace: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare(mode: replace ? .replace : .append, seedGraph: true)
            let before = try #require(model.environments.active)
            let gate = await fixture.forwarding.hold(.beforeSave(3))
            let task = fixture.presentation.accept(using: model)
            try #require(await gate.waitForEntry())
            let graph = model.environments.activeStudioGraph
            #expect(graph != before.studioGraph)
            #expect(model.assistant.pendingStudioDraft == nil && model.assistant.navigationTarget == nil)
            #expect(fixture.presentation.warning == nil)
            if storage == "absent" { try FileManager.default.removeItem(at: fixture.file) }
            if storage == "blocked" { try fixture.blockPendingParent() }
            await gate.release()
            await task.value
            await fixture.presentation.awaitOwnedWorkSnapshot()
            #expect(fixture.presentation.warning == (storage == "blocked" ? .removalUnconfirmed : nil))
            if let warning = fixture.presentation.warning {
                #expect(warning.message ==
                    "Removing the saved draft was not confirmed. It may reappear after restarting.")
            }
            #expect(model.environments.activeStudioGraph == graph)
            let attempt = try #require(model.assistant.latestStorageAttempt)
            #expect(attempt.observation == .mutation(snapshot: nil, outcome: Self.acceptanceRemoval(storage)))
            let saves = await fixture.forwarding.snapshots
            try #require(saves.count == 3)
            #expect(saves[0] == built && saves[1] != nil && saves[2] == nil)
            #expect(await fixture.forwarding.loads == 0)
            #expect(model.wing.transportWriteCount == 0)
            try AppModelPendingDraftAcceptanceFixture.requireNoProductionEntries()
        }
    }

    @Test(arguments: ["missing", "invalid", "cancel"])
    func acceptancePresentationRefusalClearsOldWarning(reason: String) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, _) = try await fixture.prepare()
            try fixture.blockPendingParent()
            await fixture.presentation.discard(using: model.assistant).value
            try #require(fixture.presentation.warning == .removalUnconfirmed)
            if reason != "missing" {
                // A real in-memory build still publishes when its validation save is obstructed.
                _ = try await fixture.buildAgain(model)
                if reason == "invalid" { model.environments.addEnvironment(named: "Different") }
            }
            let prior = await fixture.forwarding.snapshots
            let task = fixture.presentation.accept(using: model)
            #expect(fixture.presentation.warning == nil, "admission clears before the task can execute")
            if reason == "cancel" { task.cancel() }
            await task.value
            #expect(fixture.presentation.warning == nil, "refusal is not unconfirmed acceptance removal")
            #expect(model.environments.activeStudioGraph.nodes.isEmpty)
            let saves = await fixture.forwarding.snapshots
            #expect(saves.count == prior.count + (reason == "invalid" ? 1 : 0))
            #expect(saves.filter { $0 == nil }.count == 1, "only the original explicit Discard removed")
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test(arguments: ["cancel", "disappear"], [false, true])
    func acceptanceAfterMutationKeepsStorageAndGraph(event: String, blocked: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, _) = try await fixture.prepare()
            let gate = await fixture.forwarding.hold(.beforeSave(3))
            let task = fixture.presentation.accept(using: model)
            try #require(await gate.waitForEntry())
            let graph = model.environments.activeStudioGraph
            try #require(!graph.nodes.isEmpty && model.assistant.pendingStudioDraft == nil)
            if blocked { try fixture.blockPendingParent() }
            if event == "cancel" {
                task.cancel()
            } else {
                fixture.presentation.disappear()
                fixture.presentation.pendingDraftChanged(nil)
            }
            await gate.release()
            await task.value
            #expect(fixture.presentation.warning == (blocked && event == "cancel" ? .removalUnconfirmed : nil))
            #expect(model.environments.activeStudioGraph == graph)
            #expect(model.assistant.pendingStudioDraft == nil)
            let attempt = try #require(model.assistant.latestStorageAttempt)
            #expect(attempt.observation == .mutation(
                snapshot: nil, outcome: Self.acceptanceRemoval(blocked ? "blocked" : "saved")))
            #expect(await fixture.forwarding.snapshots.count == 3)
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test func acceptanceValidationFailureDoesNotWarnAfterSuccessfulRemoval() async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, _) = try await fixture.prepare()
            try fixture.blockPendingParent()
            let gate = await fixture.forwarding.hold(.afterSave(2))
            let task = fixture.presentation.accept(using: model)
            try #require(await gate.waitForEntry())
            try fixture.unblockPendingParent()
            await gate.release()
            await task.value
            #expect(!model.environments.activeStudioGraph.nodes.isEmpty)
            #expect(fixture.presentation.warning == nil)
            #expect(await fixture.forwarding.snapshots.count == 3)
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test func acceptanceNewPendingDuringValidationIsNotRemoved() async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare()
            let gate = await fixture.forwarding.hold(.afterSave(2))
            let task = fixture.presentation.accept(using: model)
            try #require(await gate.waitForEntry())
            let refreshed = try #require(model.assistant.pendingStudioDraft)
            _ = await model.assistant.perform(
                .buildStudioDraft(.init(sourceInstrumentIDs: built.request.sourceInstrumentIDs, destination: .space)),
                context: model.assistantToolContext())
            let newer = try #require(model.assistant.pendingStudioDraft)
            try #require(newer != refreshed && !newer.hasErrors && newer.liveReferences == [])
            fixture.presentation.pendingDraftChanged(newer)
            await gate.release()
            await task.value
            #expect(model.environments.activeStudioGraph.nodes.isEmpty)
            #expect(model.assistant.pendingStudioDraft == newer)
            #expect(fixture.presentation.warning == nil)
            #expect(await fixture.forwarding.snapshots == [built, refreshed, newer, newer])
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test func acceptanceNewPendingObservationAndDismissArePresentationOnly() async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, _) = try await fixture.prepare()
            let gate = await fixture.forwarding.hold(.beforeSave(3))
            let task = fixture.presentation.accept(using: model)
            try #require(await gate.waitForEntry())
            try fixture.blockPendingParent()
            await gate.release()
            await task.value
            try #require(fixture.presentation.warning == .removalUnconfirmed)
            let graph = model.environments.activeStudioGraph
            fixture.presentation.pendingDraftChanged(nil)
            #expect(fixture.presentation.warning == .removalUnconfirmed)
            try fixture.unblockPendingParent()
            let newer = try await fixture.buildAgain(model)
            fixture.presentation.pendingDraftChanged(newer)
            #expect(fixture.presentation.warning == nil)
            fixture.presentation.dismiss()
            fixture.presentation.disappear()
            #expect(model.assistant.pendingStudioDraft == newer)
            #expect(model.environments.activeStudioGraph == graph)
            #expect(await fixture.forwarding.snapshots.count == 4)
            #expect(await fixture.forwarding.loads == 0)
        }
    }
}
