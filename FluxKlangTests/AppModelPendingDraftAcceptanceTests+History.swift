import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AppModelPendingDraftAcceptanceTests {
    @Test(arguments: [false, true])
    func acceptanceHistoricalFailureRespectsPendingButNotNilABA(returnToNil: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare()
            let before = await fixture.forwarding.hold(.beforeSave(3))
            let after = await fixture.forwarding.hold(.afterSave(3))
            let task = fixture.presentation.accept(using: model)
            try #require(await before.waitForEntry())
            try fixture.blockPendingParent()
            let original = try #require(model.assistant.latestStorageAttempt)
            let graph = model.environments.activeStudioGraph
            await before.release()
            try #require(await after.waitForEntry())
            try fixture.unblockPendingParent()
            let newer = try await fixture.buildAgain(model)
            fixture.presentation.pendingDraftChanged(newer)
            if returnToNil {
                #expect(await model.assistant.discardPendingStudioDraftResult() == .deleteCompleted)
                fixture.presentation.pendingDraftChanged(nil)
            }
            let latest = try #require(model.assistant.latestStorageAttempt)
            #expect(latest !== original)
            await after.release()
            await task.value
            #expect(fixture.presentation.warning == (returnToNil ? .removalUnconfirmed : nil))
            #expect(original.observation == .mutation(
                snapshot: nil, outcome: .mutationFailedEffectUnconfirmed(.notDirectory)))
            #expect(model.assistant.latestStorageAttempt === latest, "no diagnostic-based outcome inference")
            #expect(model.assistant.pendingStudioDraft == (returnToNil ? nil : newer))
            #expect(model.environments.activeStudioGraph == graph)
            let saves = await fixture.forwarding.snapshots
            try #require(saves.count == (returnToNil ? 5 : 4))
            #expect(saves[0] == built && saves[1] != nil && saves[2] == nil && saves[3] == newer)
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test(arguments: [false, true])
    func acceptanceDetailedOwnFailureSurvivesNewerDiagnostic(cancelAfterMerge: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, _) = try await fixture.prepare()
            let before = await fixture.forwarding.hold(.beforeSave(3))
            let after = await fixture.forwarding.hold(.afterSave(3))
            let task = try fixture.start { await model.acceptPendingAssistantDraftResult() }
            try #require(await before.waitForEntry())
            let graph = model.environments.activeStudioGraph
            try #require(!graph.nodes.isEmpty)
            if cancelAfterMerge { task.cancel() }
            try fixture.blockPendingParent()
            await before.release()
            try #require(await after.waitForEntry())
            try fixture.unblockPendingParent()
            #expect(await model.assistant.discardPendingStudioDraftResult() == .alreadyAbsent)
            let latest = try #require(model.assistant.latestStorageAttempt)
            await after.release()
            let result = await task.value
            let merge = try #require(result.merge)
            #expect(merge.graph == graph && model.environments.activeStudioGraph == graph)
            #expect(result.removalOutcome == .mutationFailedEffectUnconfirmed(.notDirectory))
            #expect(latest.observation == .mutation(snapshot: nil, outcome: .alreadyAbsent))
            #expect(model.assistant.latestStorageAttempt === latest)
            #expect(model.assistant.pendingStudioDraft == nil)
            #expect(await fixture.forwarding.snapshots.count == 4)
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test func acceptanceDifferentCatchUpDoesNotReplaceOwnOutcome() async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare()
            let held = await fixture.forwarding.hold(.afterSave(3))
            let task = try fixture.start { await model.acceptPendingAssistantDraftResult() }
            try #require(await held.waitForEntry())
            let saves = await fixture.forwarding.snapshots
            try #require(saves.count == 3)
            let refreshed = try #require(saves[1])
            let newer = try await fixture.buildAgain(model)
            var unencodable = newer
            try #require(!unencodable.fragment.nodes.isEmpty)
            unencodable.fragment.nodes[0].node.position.x = .infinity
            let context = model.assistantToolContext()
            #expect(await model.assistant.commitPreparedRoutingResult(
                unencodable, expectedPending: newer, preparedContext: context, currentContext: context)
                == .staged(draft: unencodable, storageOutcome: .encodingFailed))
            await held.release()
            let result = await task.value
            let merge = try #require(result.merge)
            #expect(result.removalOutcome == .deleteCompleted, "different-snapshot catch-up is not removal")
            #expect(model.environments.activeStudioGraph == merge.graph)
            #expect(model.assistant.pendingStudioDraft == unencodable)
            let latest = try #require(model.assistant.latestStorageAttempt)
            #expect(latest.observation == .mutation(snapshot: unencodable, outcome: .encodingFailed))
            #expect(await fixture.forwarding.snapshots == [built, refreshed, nil, newer, unencodable, unencodable])
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test func acceptanceLatestNilCatchUpIsOwnOutcome() async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare()
            let held = await fixture.forwarding.hold(.afterSave(3))
            let task = try fixture.start { await model.acceptPendingAssistantDraftResult() }
            try #require(await held.waitForEntry())
            let saves = await fixture.forwarding.snapshots
            try #require(saves.count == 3)
            let refreshed = try #require(saves[1])
            let original = try #require(model.assistant.latestStorageAttempt)
            let newer = try await fixture.buildAgain(model)
            let catchUp = await fixture.forwarding.hold(.afterSave(5))
            await held.release()
            try #require(await catchUp.waitForEntry())
            #expect(await model.assistant.discardPendingStudioDraftResult() == .deleteCompleted)
            try fixture.blockPendingParent()
            await catchUp.release()
            let result = await task.value
            let merge = try #require(result.merge)
            #expect(result.removalOutcome == .mutationFailedEffectUnconfirmed(.notDirectory))
            #expect(original.observation == .mutation(snapshot: nil, outcome: .deleteCompleted))
            #expect(model.environments.activeStudioGraph == merge.graph)
            #expect(model.assistant.pendingStudioDraft == nil)
            #expect(await fixture.forwarding.snapshots == [built, refreshed, nil, newer, newer, nil, nil])
            #expect(await fixture.forwarding.loads == 0)
        }
    }
}
