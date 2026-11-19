import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AppModelPendingDraftAcceptanceTests {
    @Test(arguments: [false, true], [false, true])
    func recoveredDraftRetirementKeepsAdmittedIdentity(legacyStore: Bool, reload: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run(legacyStore: legacyStore) { fixture in
            let (model, recovered) = try await fixture.prepare(
                mode: .replace, seedGraph: true, recoverSavedDraft: true)
            let id = try #require(model.assistant.pendingPublicationID)
            try #require(model.assistant.isPendingDraftAcceptanceUnknown)
            try #require(model.assistant.canAcceptPendingDraft(hasActiveEnvironment: true))
            #expect(await fixture.forwarding.snapshots.isEmpty, "receiver only loaded the independent writer's draft")
            // A coordinator/store constructed after the file exists must also admit ordinary recovery.
            let relaunched = AssistantCoordinator(draftStore: PendingStudioPatchStore(fileURL: fixture.file))
            await relaunched.load()
            #expect(relaunched.pendingStudioDraft == recovered && relaunched.isPendingDraftAcceptanceUnknown)
            #expect(relaunched.canAcceptPendingDraft(hasActiveEnvironment: true))
            let before = model.environments.activeStudioGraph
            let task = try fixture.start {
                await model.acceptPendingAssistantDraftResult(beforeAwaitingLocalSave: fixture.receiptGate.enter)
            }
            try #require(await fixture.receiptGate.waitForEntry())
            let accepted = try #require(model.assistant.pendingStudioDraft)
            let graph = model.environments.activeStudioGraph
            try #require(graph != before && model.assistant.isPendingDraftAccepted)
            #expect(model.assistant.pendingPublicationID == id, "validation must not replace the admitted identity")
            #expect(await fixture.forwarding.snapshots == [accepted])
            if reload {
                await model.assistant.load()
                try #require(model.assistant.pendingPublicationID != id)
                #expect(model.assistant.isPendingDraftAcceptanceUnknown == legacyStore)
                #expect(model.assistant.isPendingDraftAccepted == !legacyStore)
                #expect(!model.assistant.canAcceptPendingDraft(hasActiveEnvironment: true))
                #expect(await model.acceptPendingAssistantDraftResult() == .notAccepted)
            }
            await fixture.receiptGate.release()
            let result = await task.value
            let merge = try #require(result.merge)
            #expect(merge.graph == graph && model.environments.activeStudioGraph == graph)
            #expect(try fixture.readSavedEnvironment().studioGraph == graph)
            if reload {
                #expect(result == .acceptedWithoutRetirement(merge: merge))
                #expect(model.assistant.pendingStudioDraft == accepted)
                #expect(try fixture.readPendingDraft() == accepted)
                #expect(await fixture.forwarding.snapshots == [accepted])
            } else {
                #expect(result == .accepted(merge: merge, removalOutcome: .deleteCompleted))
                #expect(model.assistant.pendingStudioDraft == nil)
                #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
                #expect(await fixture.forwarding.snapshots == [accepted, nil])
            }
        }
    }

    @Test(arguments: [false, true])
    func recoveredDraftFailedWriteBlocksSameSessionReload(legacyStore: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run(legacyStore: legacyStore) { fixture in
            let (model, _) = try await fixture.prepare(mode: .replace, seedGraph: true, recoverSavedDraft: true)
            let id = try #require(model.assistant.pendingPublicationID)
            try #require(model.assistant.canAcceptPendingDraft(hasActiveEnvironment: true))
            try fixture.blockEnvironmentFile()
            let result = await model.acceptPendingAssistantDraftResult()
            let merge = try #require(result.merge)
            #expect(result == .acceptedLocalWriteUnconfirmed(merge: merge, retainedPublicationID: id))
            let accepted = try #require(model.assistant.pendingStudioDraft)
            #expect(model.environments.activeStudioGraph == merge.graph)
            #expect(try fixture.readPendingDraft() == accepted)
            await model.assistant.load()
            #expect(model.assistant.pendingPublicationID != id)
            #expect(model.assistant.isPendingDraftAcceptanceUnknown == legacyStore)
            #expect(!model.assistant.canAcceptPendingDraft(hasActiveEnvironment: true))
            try FileManager.default.removeItem(at: fixture.environmentFile)
            model.environments.addStudioEndpointNode(
                StudioEndpoint(name: "Edit after recovered acceptance", destination: .space), position: .zero)
            await model.awaitDomainScheduledSaveSnapshots()
            let edited = model.environments.activeStudioGraph
            let editedBytes = try Data(contentsOf: fixture.environmentFile)
            #expect(await model.acceptPendingAssistantDraftResult() == .notAccepted)
            #expect(model.environments.activeStudioGraph == edited)
            #expect(try Data(contentsOf: fixture.environmentFile) == editedBytes)
            #expect(await fixture.forwarding.snapshots == [accepted], "no duplicate acceptance or automatic retry")
        }
    }

    @Test func unknownRecoveryGuardDoesNotBlockAnotherEnvironment() async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, _) = try await fixture.prepare(mode: .replace)
            let firstEnvironment = try #require(model.environments.activeID)
            try fixture.blockEnvironmentFile()
            let first = await model.acceptPendingAssistantDraftResult()
            guard case .acceptedLocalWriteUnconfirmed = first else {
                Issue.record("Expected an in-session graph application in the first environment")
                return
            }
            let secondEnvironment = model.environments.addEnvironment(named: "Recovery in another environment")
            try #require(secondEnvironment != firstEnvironment)
            let draft = try await fixture.buildAgain(model)
            try #require(draft.request.environmentID == secondEnvironment)
            #expect(await fixture.forwarding.store.save(draft) == .writeCompleted)
            await model.assistant.load()
            try #require(model.assistant.isPendingDraftAcceptanceUnknown)
            #expect(model.assistant.canAcceptPendingDraft(hasActiveEnvironment: true))
            await model.awaitDomainScheduledSaveSnapshots()
            try FileManager.default.removeItem(at: fixture.environmentFile)
            let result = await model.acceptPendingAssistantDraftResult()
            let merge = try #require(result.merge)
            #expect(result == .accepted(merge: merge, removalOutcome: .deleteCompleted))
            #expect(try fixture.readSavedEnvironment().id == secondEnvironment)
            #expect(try fixture.readSavedEnvironment().studioGraph == merge.graph)
        }
    }

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
            let saved = try fixture.readSavedEnvironment()
            #expect(saved.id == before.id && saved.studioGraph == expected.graph)
            #expect(saved.studioEndpoints == expected.endpoints)
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
    func acceptanceRetainsPendingWhenLocalStudioWriteFails(replace: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare(mode: replace ? .replace : .append, seedGraph: true)
            let priorBytes = try Data(contentsOf: fixture.environmentFile)
            let before = try fixture.readSavedEnvironment()
            let expected = StudioPatchDraftMerger.merge(
                built, into: before.studioGraph, endpoints: before.studioEndpoints,
                equipment: model.equipment.items, effects: before.effects)
            let blocker = try fixture.blockEnvironmentFile()
            let id = try #require(model.assistant.pendingPublicationID)
            let result = await model.acceptPendingAssistantDraftResult()
            #expect(result == .acceptedLocalWriteUnconfirmed(merge: expected, retainedPublicationID: id))
            #expect(result.merge == expected && result.removalOutcome == nil)
            #expect(model.environments.activeStudioGraph == expected.graph)
            #expect(model.environments.activeStudioEndpoints == expected.endpoints)
            let retained = try #require(model.assistant.pendingStudioDraft)
            #expect(try fixture.readPendingDraft() == retained)
            #expect(try Data(contentsOf: blocker) == Data("owned environment blocker".utf8))
            #expect(await fixture.forwarding.snapshots == [built, retained])

            try FileManager.default.removeItem(at: fixture.environmentFile)
            try priorBytes.write(to: fixture.environmentFile)
            #expect(await model.acceptPendingAssistantDraft() == nil)
            await model.awaitDomainScheduledSaveSnapshots()
            #expect(try Data(contentsOf: fixture.environmentFile) == priorBytes)
            #expect(try fixture.readPendingDraft() == retained)
            #expect(await fixture.forwarding.snapshots == [built, retained])
            #expect(await fixture.forwarding.loads == 0 && model.wing.transportWriteCount == 0)
        }
    }

    @Test(arguments: [false, true])
    func acceptanceLoadAfterFailedReplaceDoesNotOverwriteInterveningEdit(revalidate: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, _) = try await fixture.prepare(mode: .replace, seedGraph: true)
            try fixture.blockEnvironmentFile()
            let result = await model.acceptPendingAssistantDraftResult()
            guard case .acceptedLocalWriteUnconfirmed = result else {
                Issue.record("Expected an in-memory replacement with an unconfirmed local write")
                return
            }
            let accepted = try #require(model.assistant.pendingStudioDraft)
            let id = try #require(model.assistant.pendingPublicationID)
            if revalidate {
                var context = model.assistantToolContext()
                context.activeEnvironmentID = nil
                _ = await model.assistant.validatePendingStudioDraftResult(context: context)
                try #require(model.assistant.pendingStudioDraft != accepted)
                try #require(model.assistant.pendingPublicationID == id)
            }
            let saved = try fixture.readPendingDraft()
            // This load observes the actual tagged write, not accepted-value history.
            await model.assistant.load()
            try #require(model.assistant.pendingPublicationID != id)
            try #require(model.assistant.isPendingDraftAccepted)
            #expect(await model.acceptPendingAssistantDraftResult() == .notAccepted)
            let pendingBytes = try Data(contentsOf: fixture.file)
            try FileManager.default.removeItem(at: fixture.file)
            await model.assistant.load()
            try #require(model.assistant.pendingStudioDraft == nil && !model.assistant.isPendingDraftAccepted)
            var different = saved
            different.createdAt = different.createdAt.addingTimeInterval(1)
            try JSONEncoder().encode(different).write(to: fixture.file)
            await model.assistant.load()
            try #require(model.assistant.pendingStudioDraft == different && !model.assistant.isPendingDraftAccepted)
            #expect(model.assistant.isPendingDraftAcceptanceUnknown)
            try pendingBytes.write(to: fixture.file)
            await model.assistant.load()
            try #require(model.assistant.pendingStudioDraft == saved)
            #expect(model.assistant.pendingPublicationID != id)
            // Absence/different bytes invalidated the store slot. Equal bytes cannot recover authority.
            #expect(!model.assistant.isPendingDraftAccepted && model.assistant.isPendingDraftAcceptanceUnknown)

            try FileManager.default.removeItem(at: fixture.environmentFile)
            model.environments.addStudioEndpointNode(StudioEndpoint(name: "Intervening edit", destination: .space),
                                                     position: .zero)
            await model.awaitDomainScheduledSaveSnapshots()
            let edited = model.environments.activeStudioGraph
            try #require(edited != result.merge?.graph)
            let editedBytes = try Data(contentsOf: fixture.environmentFile)
            let pendingSaves = await fixture.forwarding.snapshots
            let repeated = await model.acceptPendingAssistantDraftResult {
                Issue.record("Load admitted an accepted or unknown replacement and scheduled a second write")
            }
            #expect(repeated == .notAccepted)
            await model.awaitDomainScheduledSaveSnapshots()
            #expect(model.environments.activeStudioGraph == edited)
            #expect(try Data(contentsOf: fixture.environmentFile) == editedBytes)
            #expect(try Data(contentsOf: fixture.file) == pendingBytes)
            #expect(await fixture.forwarding.snapshots == pendingSaves)
        }
    }

    @Test(arguments: [false, true])
    func acceptanceUnknownProvenanceIsNotLaunderedByValidation(foreignToken: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, _) = try await fixture.prepare(mode: .replace)
            try fixture.blockEnvironmentFile()
            let result = await model.acceptPendingAssistantDraftResult()
            guard case .acceptedLocalWriteUnconfirmed = result else {
                Issue.record("Expected a prior in-session graph application")
                return
            }
            let accepted = try #require(model.assistant.pendingStudioDraft)
            // Neither an untagged write nor another caller's token identifies our logical acceptance.
            if foreignToken {
                #expect(await fixture.forwarding.store.save(accepted, provenance: UUID()) == .writeCompleted)
            } else {
                #expect(await fixture.forwarding.store.save(accepted) == .writeCompleted)
            }
            await model.assistant.load()
            try #require(model.assistant.isPendingDraftAcceptanceUnknown)
            #expect(!model.assistant.isPendingDraftAccepted)
            let context = model.assistantToolContext()
            let validation = await model.assistant.validatePendingStudioDraftResult(context: context)
            let refreshed = try #require(validation.draft)
            await model.assistant.load()
            #expect(model.assistant.isPendingDraftAcceptanceUnknown)
            let graph = model.environments.activeStudioGraph
            let saves = await fixture.forwarding.snapshots
            #expect(await model.acceptPendingAssistantDraftResult() == .notAccepted)
            #expect(model.environments.activeStudioGraph == graph)
            #expect(await fixture.forwarding.snapshots == saves)
            #expect(try fixture.readPendingDraft() == refreshed)
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

    @Test(arguments: [false, true], [false, true])
    func acceptancePreservesNoActiveEnvironmentPolicy(legacy: Bool, unknown: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run(legacyStore: unknown) { fixture in
            let (model, _) = try await fixture.prepare()
            model.environments.removeActive()
            await model.awaitDomainScheduledSaveSnapshots()
            let built = try await fixture.buildAgain(model)
            try #require(model.environments.active == nil && built.request.environmentID == nil)
            if unknown {
                #expect(await fixture.forwarding.store.save(built) == .writeCompleted)
                await model.assistant.load()
                try #require(model.assistant.isPendingDraftAcceptanceUnknown)
            }
            // The legacy merger can return a graph although replaceStudio has no environment to mutate.
            let merge: StudioPatchMergeResult?
            if legacy {
                merge = await model.acceptPendingAssistantDraft()
            } else {
                let result = await model.acceptPendingAssistantDraftResult {
                    Issue.record("No-active-environment acceptance must not await a receipt observer")
                }
                #expect(result.removalOutcome == .deleteCompleted)
                merge = result.merge
            }
            let accepted = try #require(merge)
            #expect(!accepted.graph.nodes.isEmpty)
            #expect(model.environments.active == nil && model.environments.activeID == nil)
            #expect(model.assistant.pendingStudioDraft == nil)
            #expect(await fixture.forwarding.snapshots.count == 4)
            #expect(await fixture.forwarding.loads == (unknown ? 1 : 0))
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
