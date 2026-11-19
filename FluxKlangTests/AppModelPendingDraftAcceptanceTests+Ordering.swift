import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AppModelPendingDraftAcceptanceTests {
    @Test(arguments: [false, true])
    func acceptanceLoadUsesActualEqualWriteOrder(acceptedWritesLast: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare(mode: .replace, seedGraph: true)
            let validationContext = model.assistantToolContext()
            try fixture.blockEnvironmentFile()
            let first = await model.acceptPendingAssistantDraftResult()
            guard case .acceptedLocalWriteUnconfirmed = first else {
                Issue.record("Expected an accepted replacement retained after a failed local write")
                return
            }
            let accepted = try #require(model.assistant.pendingStudioDraft)
            let acceptedID = try #require(model.assistant.pendingPublicationID)
            let held = await fixture.forwarding.hold(acceptedWritesLast ? .beforeSave(3) : .afterSave(3))
            let older = try fixture.start {
                await model.assistant.validatePendingStudioDraftResult(context: validationContext)
            }
            try #require(await held.waitForEntry())
            try #require(model.assistant.pendingStudioDraft == accepted, "require equal snapshots, not just equal ids")
            let olderAttempt = try #require(model.assistant.latestStorageAttempt)
            let context = model.assistantToolContext()
            let prepared = await model.assistant.commitPreparedRoutingResult(
                accepted, expectedPending: accepted, preparedContext: context, currentContext: context)
            try #require(prepared == .staged(draft: accepted, storageOutcome: .writeCompleted))
            let preparedID = try #require(model.assistant.pendingPublicationID)
            try #require(preparedID != acceptedID && !model.assistant.isPendingDraftAccepted)
            let latest = try #require(model.assistant.latestStorageAttempt)
            await held.release()
            #expect(await older.value == .staged(draft: accepted, storageOutcome: .writeCompleted))
            #expect(model.assistant.latestStorageAttempt === latest && latest !== olderAttempt)
            #expect(try fixture.readPendingDraft() == accepted)
            #expect(await fixture.forwarding.snapshots == [built, accepted, accepted, accepted])

            // Same values and same result delivery order in both cases; only actual mutation order differs.
            await model.assistant.load()
            #expect(model.assistant.pendingPublicationID != preparedID)
            #expect(model.assistant.isPendingDraftAccepted == acceptedWritesLast)
            #expect(!model.assistant.isPendingDraftAcceptanceUnknown)
            #expect(model.assistant.canAcceptPendingDraft(hasActiveEnvironment: true) == !acceptedWritesLast)
            if acceptedWritesLast {
                let graph = model.environments.activeStudioGraph
                #expect(await model.acceptPendingAssistantDraftResult() == .notAccepted)
                #expect(model.environments.activeStudioGraph == graph)
                #expect(await fixture.forwarding.snapshots.count == 4)
            } else {
                // Fresh equal prepared save -> load -> accept must not inherit the older acceptance.
                try FileManager.default.removeItem(at: fixture.environmentFile)
                let second = await model.acceptPendingAssistantDraftResult()
                let merge = try #require(second.merge)
                #expect(second == .accepted(merge: merge, removalOutcome: .deleteCompleted))
                #expect(try fixture.readSavedEnvironment().studioGraph == merge.graph)
                #expect(model.assistant.pendingStudioDraft == nil)
                #expect(await fixture.forwarding.snapshots.count == 6)
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func acceptanceReceiptNeverRetiresReplacement(equalValue: Bool, cancelled: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare()
            let id = try #require(model.assistant.pendingPublicationID)
            let task = try fixture.start {
                await model.acceptPendingAssistantDraftResult(beforeAwaitingLocalSave: fixture.receiptGate.enter)
            }
            try #require(await fixture.receiptGate.waitForEntry())
            let accepted = try #require(model.assistant.pendingStudioDraft)
            let graph = model.environments.activeStudioGraph
            try #require(!graph.nodes.isEmpty && model.assistant.isPendingDraftAccepted)
            #expect(try fixture.readPendingDraft() == accepted)
            let replacement: StudioPatchDraft
            if equalValue {
                // A fresh publication from disk, even though its bytes describe the exact accepted snapshot.
                await model.assistant.load()
                replacement = accepted
            } else {
                replacement = try await fixture.buildAgain(model, destination: .space)
                try #require(replacement != accepted)
            }
            try #require(model.assistant.pendingStudioDraft == replacement)
            try #require(model.assistant.pendingPublicationID != id)
            #expect(model.assistant.isPendingDraftAccepted == equalValue)
            if equalValue {
                #expect(await model.acceptPendingAssistantDraftResult() == .notAccepted)
            }
            if cancelled { task.cancel() }
            await fixture.receiptGate.release()
            let result = await task.value
            let merge = try #require(result.merge)
            #expect(result == .acceptedWithoutRetirement(merge: merge))
            #expect(merge.graph == graph && model.environments.activeStudioGraph == graph)
            #expect(try fixture.readSavedEnvironment().studioGraph == graph)
            #expect(model.assistant.pendingStudioDraft == replacement)
            #expect(try fixture.readPendingDraft() == replacement)
            let snapshots: [StudioPatchDraft?] = equalValue ? [built, accepted] : [built, accepted, replacement]
            #expect(await fixture.forwarding.snapshots == snapshots)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func acceptanceCancellationAfterMutationJoinsOwnedSave(blocked: Bool, cancelBeforeSaveStarts: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare()
            if blocked { try fixture.blockEnvironmentFile() }
            let id = try #require(model.assistant.pendingPublicationID)
            let task = try fixture.start {
                await model.acceptPendingAssistantDraftResult {
                    // This actor turn has mutated the graph but has not yielded to the owned save yet.
                    if cancelBeforeSaveStarts { withUnsafeCurrentTask { $0?.cancel() } }
                    await fixture.receiptGate.enter()
                }
            }
            try #require(await fixture.receiptGate.waitForEntry())
            let accepted = try #require(model.assistant.pendingStudioDraft)
            let graph = model.environments.activeStudioGraph
            try #require(!graph.nodes.isEmpty && model.assistant.isPendingDraftAccepted)
            #expect(model.assistant.pendingPublicationID == id)
            #expect(try fixture.readPendingDraft() == accepted)
            #expect(await model.acceptPendingAssistantDraftResult() == .notAccepted)
            #expect(await fixture.forwarding.snapshots == [built, accepted])
            task.cancel()
            await fixture.receiptGate.release()
            let result = await task.value
            let merge = try #require(result.merge)
            #expect(merge.graph == graph && model.environments.activeStudioGraph == graph)
            if blocked {
                #expect(result == .acceptedLocalWriteUnconfirmed(merge: merge, retainedPublicationID: id))
                #expect(model.assistant.pendingStudioDraft == accepted)
                #expect(try fixture.readPendingDraft() == accepted)
                #expect(await fixture.forwarding.snapshots == [built, accepted])
            } else {
                #expect(result == .accepted(merge: merge, removalOutcome: .deleteCompleted))
                #expect(model.assistant.pendingStudioDraft == nil)
                #expect(try fixture.readSavedEnvironment().studioGraph == graph)
                #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
                #expect(await fixture.forwarding.snapshots == [built, accepted, nil])
            }
        }
    }

    @Test func acceptanceDoesNotRetryRetirementAfterPreparedRollback() async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare()
            let id = try #require(model.assistant.pendingPublicationID)
            let acceptance = try fixture.start {
                await model.acceptPendingAssistantDraftResult(beforeAwaitingLocalSave: fixture.receiptGate.enter)
            }
            try #require(await fixture.receiptGate.waitForEntry())
            let accepted = try #require(model.assistant.pendingStudioDraft)
            let context = model.assistantToolContext()
            let gate = await fixture.forwarding.hold(.afterSave(3))
            let replacement = try fixture.start {
                await model.assistant.commitPreparedRouting(
                    accepted, expectedPending: accepted, preparedContext: context, currentContext: context)
            }
            try #require(await gate.waitForEntry())
            try #require(model.assistant.pendingPublicationID != id && !model.assistant.isPendingDraftAccepted)
            await fixture.receiptGate.release()
            let result = await acceptance.value
            let merge = try #require(result.merge)
            try #require(result == .acceptedWithoutRetirement(merge: merge))

            replacement.cancel()
            await gate.release()
            #expect(await replacement.value == false)
            #expect(model.assistant.pendingPublicationID == id)
            #expect(model.assistant.isPendingDraftAccepted && model.assistant.pendingStudioDraft == accepted)
            #expect(await model.acceptPendingAssistantDraftResult() == .notAccepted)
            #expect(try fixture.readPendingDraft() == accepted)
            #expect(try fixture.readSavedEnvironment().studioGraph == merge.graph)
            #expect(await fixture.forwarding.snapshots == [built, accepted, accepted, accepted])
        }
    }

    @Test(arguments: [false, true], [false, true])
    func acceptanceThenOppositeAcceptanceReverseCompletion(replaceFirst: Bool, olderFails: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare(mode: replaceFirst ? .replace : .append, seedGraph: true)
            let initial = try #require(model.environments.active)
            let olderBefore = await fixture.forwarding.hold(.beforeSave(3))
            let olderAfter = await fixture.forwarding.hold(.afterSave(3))
            let older = fixture.presentation.accept(using: model)
            defer { older.cancel() }
            try #require(await olderBefore.waitForEntry())
            let firstSaves = await fixture.forwarding.snapshots
            try #require(firstSaves.count == 3)
            try #require(firstSaves[0] == built && firstSaves[2] == nil)
            let firstValidated = try #require(firstSaves[1])
            try #require(firstValidated.id == built.id && !firstValidated.hasErrors)
            try #require(firstValidated.request == built.request)
            try #require(firstValidated.liveReferences == [] && firstValidated.applicationMode == built.applicationMode)
            try #require(firstValidated.applicationMode == (replaceFirst ? .replace : .append))
            let firstExpected = StudioPatchDraftMerger.merge(
                firstValidated, into: initial.studioGraph, endpoints: initial.studioEndpoints,
                equipment: model.equipment.items, effects: initial.effects)
            let firstAccepted = try #require(model.environments.active)
            // accept(using:) returns Void: require a real, distinguishable graph acceptance at its removal gate.
            try #require(firstExpected.graph != initial.studioGraph && firstExpected.addedEdgeCount > 0)
            try #require(firstAccepted.studioGraph == firstExpected.graph)
            try #require(firstAccepted.studioEndpoints == firstExpected.endpoints)
            try #require(model.assistant.pendingStudioDraft == nil)
            let olderRemoval = try #require(model.assistant.latestStorageAttempt)
            if olderFails { try fixture.blockPendingParent() }
            await olderBefore.release()
            try #require(await olderAfter.waitForEntry()) // Real IO finished; only its completion is held.
            if olderFails { try fixture.unblockPendingParent() }

            let draft = try await fixture.buildAgain(
                model, mode: replaceFirst ? .append : .replace, destination: .space)
            try fixture.requireReady(model, draft)
            try #require(draft.id != built.id && draft.applicationMode != built.applicationMode)
            try #require(draft.request.destination != built.request.destination)
            let newerBefore = await fixture.forwarding.hold(.beforeSave(6))
            let newerAfter = await fixture.forwarding.hold(.afterSave(6))
            let newer = fixture.presentation.accept(using: model)
            defer { newer.cancel() }
            #expect(fixture.presentation.warning == nil)
            try #require(await newerBefore.waitForEntry())
            let saves = await fixture.forwarding.snapshots
            try #require(saves.count == 6)
            try #require(saves[3] == draft && saves[5] == nil)
            let secondValidated = try #require(saves[4])
            try #require(secondValidated.id == draft.id && !secondValidated.hasErrors)
            try #require(secondValidated.request == draft.request)
            try #require(secondValidated.liveReferences == []
                         && secondValidated.applicationMode == draft.applicationMode)
            try #require(secondValidated.applicationMode == (replaceFirst ? .append : .replace))
            let secondExpected = StudioPatchDraftMerger.merge(
                secondValidated, into: firstAccepted.studioGraph, endpoints: firstAccepted.studioEndpoints,
                equipment: model.equipment.items, effects: firstAccepted.effects)
            try #require(secondExpected.graph != firstExpected.graph && secondExpected.addedEdgeCount > 0)
            try #require(secondExpected.endpoints != firstExpected.endpoints)
            try #require(model.environments.activeStudioGraph == secondExpected.graph)
            try #require(model.environments.activeStudioEndpoints == secondExpected.endpoints)
            try #require(model.assistant.pendingStudioDraft == nil)
            let newerRemoval = try #require(model.assistant.latestStorageAttempt)
            try #require(newerRemoval !== olderRemoval)
            if !olderFails { try fixture.blockPendingParent() }
            await newerBefore.release()
            try #require(await newerAfter.waitForEntry())
            await newerAfter.release()
            await newer.value // Newer presentation completes while older remains held after IO.
            let expected: StudioDraftDiscardPresentation.Warning? = olderFails ? nil : .removalUnconfirmed
            #expect(fixture.presentation.warning == expected)
            #expect(newerRemoval.observation == .mutation(
                snapshot: nil, outcome: Self.acceptanceRemoval(olderFails ? "saved" : "blocked")))
            #expect(model.environments.activeStudioGraph == secondExpected.graph)
            #expect(model.environments.activeStudioEndpoints == secondExpected.endpoints)
            await olderAfter.release()
            await older.value
            await fixture.presentation.awaitOwnedWorkSnapshot()
            await model.awaitDomainScheduledSaveSnapshots() // Joined work, not durable environment-save proof.
            #expect(fixture.presentation.warning == expected, "older acceptance cannot show OR clear newer acceptance")
            #expect(olderRemoval.observation == .mutation(
                snapshot: nil, outcome: Self.acceptanceRemoval(olderFails ? "blocked" : "saved")))
            #expect(model.assistant.latestStorageAttempt === newerRemoval)
            #expect(model.environments.active?.id == initial.id && model.environments.activeID == initial.id)
            #expect(model.environments.activeStudioGraph == secondExpected.graph)
            #expect(model.environments.activeStudioEndpoints == secondExpected.endpoints)
            #expect(model.assistant.pendingStudioDraft == nil && model.assistant.navigationTarget == nil)
            #expect(await fixture.forwarding.snapshots == [built, firstValidated, nil, draft, secondValidated, nil],
                    "exactly two builds, two validations and two removals; no retry or catch-up writes")
            #expect(await fixture.forwarding.loads == 0)
            #expect(model.wing === fixture.wing && model.wing.connection == .disconnected)
            #expect(model.wing.sessionID == nil && model.wing.transportWriteCount == 0 && !model.isDemo)
            try AppModelPendingDraftAcceptanceFixture.requireNoProductionEntries()
            // run() releases gates and joins all owned work even if any fatal assertion throws.
        }
    }

    @Test(arguments: [false, true])
    func acceptanceThenDiscardReverseCompletion(olderFails: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare()
            let before = await fixture.forwarding.hold(.beforeSave(3))
            let after = await fixture.forwarding.hold(.afterSave(3))
            let older = fixture.presentation.accept(using: model)
            try #require(await before.waitForEntry())
            let graph = model.environments.activeStudioGraph
            if olderFails { try fixture.blockPendingParent() }
            await before.release()
            try #require(await after.waitForEntry())
            if olderFails {
                try fixture.unblockPendingParent()
            } else {
                try fixture.blockPendingParent()
            }
            let newer = fixture.presentation.discard(using: model.assistant)
            #expect(fixture.presentation.warning == nil)
            await newer.value
            let expected: StudioDraftDiscardPresentation.Warning? = olderFails ? nil : .removalUnconfirmed
            #expect(fixture.presentation.warning == expected)
            await after.release()
            await older.value
            #expect(fixture.presentation.warning == expected, "older acceptance cannot show OR clear newer discard")
            #expect(model.environments.activeStudioGraph == graph)
            let saves = await fixture.forwarding.snapshots
            try #require(saves.count == 4)
            #expect(saves[0] == built && saves[1] != nil && saves[2] == nil && saves[3] == nil)
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test(arguments: [false, true])
    func discardThenAcceptanceReverseCompletion(olderFails: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare()
            if olderFails { try fixture.blockPendingParent() }
            let held = await fixture.forwarding.hold(.afterSave(2))
            let older = fixture.presentation.discard(using: model.assistant)
            try #require(await held.waitForEntry())
            if olderFails { try fixture.unblockPendingParent() }
            let draft = try await fixture.buildAgain(model)
            let removal = await fixture.forwarding.hold(.beforeSave(5))
            let newer = fixture.presentation.accept(using: model)
            #expect(fixture.presentation.warning == nil)
            try #require(await removal.waitForEntry())
            if !olderFails { try fixture.blockPendingParent() }
            await removal.release()
            await newer.value
            let expected: StudioDraftDiscardPresentation.Warning? = olderFails ? nil : .removalUnconfirmed
            #expect(fixture.presentation.warning == expected)
            await held.release()
            await older.value
            #expect(fixture.presentation.warning == expected, "older discard cannot show OR clear newer acceptance")
            #expect(!model.environments.activeStudioGraph.nodes.isEmpty)
            #expect(model.assistant.pendingStudioDraft == nil)
            let saves = await fixture.forwarding.snapshots
            try #require(saves.count == 5)
            #expect(saves[0] == built && saves[1] == nil && saves[2] == draft && saves[3] != nil && saves[4] == nil)
            #expect(await fixture.forwarding.loads == 0)
        }
    }

    @Test(arguments: [false, true])
    func acceptanceMixedAdmissionClearsWarningImmediately(acceptFirst: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, _) = try await fixture.prepare()
            let removalIndex = acceptFirst ? 3 : 2
            let firstGate = await fixture.forwarding.hold(.beforeSave(removalIndex))
            let first = acceptFirst
                ? fixture.presentation.accept(using: model)
                : fixture.presentation.discard(using: model.assistant)
            try #require(await firstGate.waitForEntry())
            try fixture.blockPendingParent()
            await firstGate.release()
            await first.value
            try #require(fixture.presentation.warning == .removalUnconfirmed)
            try fixture.unblockPendingParent()
            // No onChange delivery: admission itself must clear the warning synchronously.
            if !acceptFirst { _ = try await fixture.buildAgain(model) }
            let secondGate = await fixture.forwarding.hold(.beforeSave(4))
            let second = acceptFirst
                ? fixture.presentation.discard(using: model.assistant)
                : fixture.presentation.accept(using: model)
            #expect(fixture.presentation.warning == nil)
            try #require(await secondGate.waitForEntry())
            #expect(fixture.presentation.warning == nil)
            await secondGate.release()
            await second.value
            #expect(fixture.presentation.warning == nil)
            #expect(await fixture.forwarding.snapshots.count == (acceptFirst ? 4 : 5))
            #expect(await fixture.forwarding.loads == 0)
        }
    }
}
