import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AppModelPendingDraftAcceptanceTests {
    @Test(arguments: ["saved", "absent", "blocked"], [false, true])
    func acceptanceDetailedOwnRemoval(storage: String, replace: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare(mode: replace ? .replace : .append, seedGraph: true)
            let before = try #require(model.environments.active)
            let expected = StudioPatchDraftMerger.merge(
                built, into: before.studioGraph, endpoints: before.studioEndpoints,
                equipment: model.equipment.items, effects: before.effects)
            let gate = await fixture.forwarding.hold(.beforeSave(3))
            let task = try fixture.start { await model.acceptPendingAssistantDraftResult() }
            try #require(await gate.waitForEntry())
            let snapshots = await fixture.forwarding.snapshots
            try #require(snapshots.count == 3)
            let refreshed = try #require(snapshots[1])
            #expect(!refreshed.hasErrors && refreshed.liveReferences == [])
            #expect(model.environments.activeStudioGraph == expected.graph)
            #expect(model.assistant.pendingStudioDraft == nil && model.assistant.navigationTarget == nil)
            if storage == "absent" { try FileManager.default.removeItem(at: fixture.file) }
            if storage == "blocked" { try fixture.blockPendingParent() }
            await gate.release()
            let result = await task.value
            #expect(result == .accepted(merge: expected, removalOutcome: Self.acceptanceRemoval(storage)))
            #expect(result.merge == expected)
            #expect(result.removalOutcome == Self.acceptanceRemoval(storage))
            #expect(model.environments.active?.id == before.id)
            #expect(model.environments.activeStudioGraph == expected.graph)
            #expect(model.environments.activeStudioEndpoints == expected.endpoints)
            #expect(await fixture.forwarding.snapshots == [built, refreshed, nil])
            #expect(await fixture.forwarding.loads == 0)
            #expect(model.wing.transportWriteCount == 0)
            try AppModelPendingDraftAcceptanceFixture.requireNoProductionEntries()
        }
    }

    @Test(arguments: [false, true])
    func acceptanceLegacyDelegatesOnce(replace: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare(mode: replace ? .replace : .append, seedGraph: true)
            let before = try #require(model.environments.active)
            let expected = StudioPatchDraftMerger.merge(
                built, into: before.studioGraph, endpoints: before.studioEndpoints,
                equipment: model.equipment.items, effects: before.effects)
            let merged = try #require(await model.acceptPendingAssistantDraft())
            #expect(merged == expected)
            #expect(model.environments.activeStudioGraph == expected.graph)
            let saves = await fixture.forwarding.snapshots
            try #require(saves.count == 3)
            #expect(saves[0] == built)
            #expect(saves[1] != nil && saves[2] == nil, "one validation and one removal, not double delegation")
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test(arguments: ["missing", "invalid", "cancelled"], [false, true])
    func acceptanceRefusalHasNoRemoval(reason: String, legacy: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, _) = try await fixture.prepare()
            if reason == "missing" { await model.assistant.discardPendingStudioDraft() }
            if reason == "invalid" { model.environments.addEnvironment(named: "Different environment") }
            let before = model.environments.activeStudioGraph
            let prior = await fixture.forwarding.snapshots
            let task = try fixture.start {
                if legacy { return await model.acceptPendingAssistantDraft() == nil }
                let result = await model.acceptPendingAssistantDraftResult()
                #expect(result.merge == nil && result.removalOutcome == nil)
                return result == .notAccepted
            }
            if reason == "cancelled" { task.cancel() } // Before the MainActor task can begin.
            #expect(await task.value)
            #expect(model.environments.activeStudioGraph == before)
            let saves = await fixture.forwarding.snapshots
            #expect(saves.count == prior.count + (reason == "invalid" ? 1 : 0))
            #expect(saves.compactMap { $0 }.count == prior.compactMap { $0 }.count + (reason == "invalid" ? 1 : 0))
            #expect(fixture.presentation.warning == nil)
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test(arguments: ["cancel", "environment", "equipment", "effects", "graph", "endpoints", "home"])
    func acceptanceRefusesChangedValidationContext(change: String) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare(seedGraph: change == "endpoints")
            let gate = await fixture.forwarding.hold(.afterSave(2))
            let task = try fixture.start { await model.acceptPendingAssistantDraftResult() }
            try #require(await gate.waitForEntry())
            let refreshed = try #require(model.assistant.pendingStudioDraft)
            switch change {
            case "cancel": task.cancel()
            case "environment": model.environments.addEnvironment(named: "New context")
            case "equipment": model.equipment.add(Equipment(name: "New source", outputs: ["Out"]))
            case "effects": model.environments.add(Effect(name: "New effect"))
            case "graph":
                let instrument = try #require(model.equipment.items.first)
                model.environments.addStudioNode(StudioNode(kind: .instrument(instrument.id), title: "Changed"))
            case "endpoints":
                let graphBefore = model.environments.activeStudioGraph
                let endpointsBefore = model.environments.activeStudioEndpoints
                let endpoint = try #require(endpointsBefore.first)
                model.environments.setStudioEndpointPlacement(endpoint.id, to: VoicePlacement(width: 1))
                try #require(model.environments.activeStudioGraph == graphBefore)
                try #require(model.environments.activeStudioEndpoints != endpointsBefore)
            default:
                try await model.studioConnections.replaceHome(
                    StudioHomeConnections(), equipment: model.equipment.items)
            }
            let graph = model.environments.activeStudioGraph
            await gate.release()
            #expect(await task.value == .notAccepted)
            #expect(model.environments.activeStudioGraph == graph)
            #expect(model.assistant.pendingStudioDraft == refreshed)
            #expect(await fixture.forwarding.snapshots == [built, refreshed], "no acceptance nil-save")
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test func acceptanceValidationSaveFailureIsNotRemovalFailure() async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare()
            try fixture.blockPendingParent()
            let gate = await fixture.forwarding.hold(.afterSave(2))
            let task = try fixture.start { await model.acceptPendingAssistantDraftResult() }
            try #require(await gate.waitForEntry())
            let refreshed = try #require(model.assistant.pendingStudioDraft)
            let validation = try #require(model.assistant.latestStorageAttempt)
            try fixture.unblockPendingParent()
            await gate.release()
            let result = await task.value
            let merge = try #require(result.merge)
            guard case .mutation(let saved, .directoryPreparationFailed(_)?) = validation.observation else {
                Issue.record("Expected validation's own directory preparation failure")
                return
            }
            #expect(saved == refreshed)
            #expect(result.removalOutcome == .alreadyAbsent)
            #expect(model.environments.activeStudioGraph == merge.graph)
            #expect(await fixture.forwarding.snapshots == [built, refreshed, nil])
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test(arguments: [false, true])
    func acceptancePreservesNoActiveEnvironmentPolicy(legacy: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, _) = try await fixture.prepare()
            model.environments.removeActive()
            await model.awaitDomainScheduledSaveSnapshots()
            let built = try await fixture.buildAgain(model)
            try #require(model.environments.active == nil && built.request.environmentID == nil)
            // The legacy merger can return a graph although replaceStudio has no environment to mutate.
            let merge: StudioPatchMergeResult?
            if legacy {
                merge = await model.acceptPendingAssistantDraft()
            } else {
                let result = await model.acceptPendingAssistantDraftResult()
                #expect(result.removalOutcome == .deleteCompleted)
                merge = result.merge
            }
            let accepted = try #require(merge)
            #expect(!accepted.graph.nodes.isEmpty)
            #expect(model.environments.active == nil && model.environments.activeID == nil)
            #expect(model.assistant.pendingStudioDraft == nil)
            #expect(await fixture.forwarding.snapshots.count == 4)
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    static func acceptanceRemoval(_ storage: String) -> PendingStudioPatchMutationOutcome {
        switch storage {
        case "saved": .deleteCompleted
        case "absent": .alreadyAbsent
        default: .mutationFailedEffectUnconfirmed(.notDirectory)
        }
    }
}
