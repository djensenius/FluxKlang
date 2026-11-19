import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AppModelPendingDraftAcceptanceTests {
    @Test(arguments: [false, true], [false, true])
    func acceptanceThenOppositeAcceptanceReverseCompletion(replaceFirst: Bool, olderFails: Bool) async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare(mode: replaceFirst ? .replace : .append, seedGraph: true)
            let initial = try #require(model.environments.active)
            let olderBefore = await fixture.forwarding.hold(.beforeSave(3))
            let olderAfter = await fixture.forwarding.hold(.afterSave(3))
            let older = fixture.presentation.accept(using: model)
            try #require(await olderBefore.waitForEntry())
            let firstSaves = await fixture.forwarding.snapshots
            try #require(firstSaves.count == 3)
            try #require(firstSaves[0] == built && firstSaves[2] == nil)
            let firstValidated = try #require(firstSaves[1])
            try #require(firstValidated.id == built.id && !firstValidated.hasErrors)
            try #require(firstValidated.request == built.request)
            try #require(firstValidated.liveReferences == [] && firstValidated.applicationMode == built.applicationMode)
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
