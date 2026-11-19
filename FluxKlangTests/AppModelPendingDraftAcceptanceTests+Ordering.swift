import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AppModelPendingDraftAcceptanceTests {
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
