import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.serialized, .productionAccessAudit)
@MainActor
struct AppModelPendingDraftAcceptanceTests {
    // Old-API characterization, not a detailed-result or Studio banner assertion.
    @Test func acceptanceKeepsGraphWhenPendingRemovalIsUnconfirmed() async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare()
            let environmentID = try #require(built.request.environmentID)
            let before = try #require(model.environments.active)
            try #require(before.id == environmentID)
            try #require(model.environments.activeID == environmentID)
            try #require(before.studioGraph.nodes.isEmpty)
            try #require(!built.hasErrors)
            try #require(built.liveReferences == [])
            try #require(model.studioConnections.connections.temporaryMoves.isEmpty)
            try #require(fixture.setupSavesJoined)
            try #require(model.wing === fixture.wing)
            try #require(model.wing.connection == .disconnected)
            try #require(model.wing.sessionID == nil)
            try #require(!model.isDemo)
            try AppModelPendingDraftAcceptanceFixture.requireNoProductionEntries()
            let buildAttempt = try #require(model.assistant.latestStorageAttempt)
            try #require(buildAttempt.observation == .mutation(snapshot: built, outcome: .writeCompleted))
            _ = await model.assistant.perform(.openReview, context: model.assistantToolContext())
            try #require(model.assistant.navigationTarget == .reviewPendingDraft)

            // Observe validation's own real save, then intercept discard before the real unlink.
            let validationGate = await fixture.forwarding.hold(.afterSave(2))
            let removalGate = await fixture.forwarding.hold(.beforeSave(3))
            let acceptance = try fixture.startAcceptance()
            try #require(await validationGate.waitForEntry())
            let refreshed = try #require(model.assistant.pendingStudioDraft)
            let validationAttempt = try #require(model.assistant.latestStorageAttempt)
            try #require(!refreshed.hasErrors)
            try #require(refreshed.liveReferences == [])
            try #require(await fixture.forwarding.snapshots == [built, refreshed])
            await validationGate.release()
            try #require(await removalGate.waitForEntry())
            try #require(validationAttempt.observation == .mutation(
                snapshot: refreshed, outcome: .writeCompleted))
            let removalAttempt = try #require(model.assistant.latestStorageAttempt)
            try #require(removalAttempt !== validationAttempt)
            try #require(removalAttempt.observation == .mutation(snapshot: nil, outcome: nil))
            #expect(model.assistant.pendingStudioDraft == nil)
            #expect(model.assistant.navigationTarget == nil)
            let whileHeld = try #require(model.environments.active)
            #expect(whileHeld.id == environmentID)
            #expect(whileHeld.studioGraph != before.studioGraph)

            // This ancestor is exclusively owned by this fixture. ENOTDIR is real, not stubbed.
            let blocker = fixture.file.deletingLastPathComponent()
            try FileManager.default.removeItem(at: blocker)
            let bytes = Data("owned acceptance removal blocker".utf8)
            try bytes.write(to: blocker)
            await removalGate.release()
            let merged = try #require(await acceptance.value)
            let accepted = try #require(model.environments.active)
            #expect(model.environments.activeID == environmentID)
            #expect(accepted.id == environmentID)
            #expect(accepted.studioGraph != before.studioGraph)
            #expect(accepted.studioGraph == merged.graph)
            #expect(accepted.studioEndpoints == merged.endpoints)
            #expect(merged.addedNodeCount > 0)
            #expect(merged.addedEdgeCount > 0)
            #expect(model.assistant.pendingStudioDraft == nil)
            #expect(model.assistant.navigationTarget == nil)
            #expect(model.assistant.latestStorageAttempt === removalAttempt)
            #expect(removalAttempt.observation == .mutation(
                snapshot: nil, outcome: .mutationFailedEffectUnconfirmed(.notDirectory)))
            #expect(await fixture.forwarding.snapshots == [built, refreshed, nil])
            #expect(await fixture.forwarding.loads == 0)
            #expect(try Data(contentsOf: blocker) == bytes)
            #expect(model.wing.connection == .disconnected)
            #expect(model.wing.transportWriteCount == 0)
            try AppModelPendingDraftAcceptanceFixture.requireNoProductionEntries()
            // run() joins owned work before resources are removed, also on every throwing path.
        }
    }

    /// #943: damaged environments.json holds the store; Home, acceptance and later edits write nothing.
    @Test func heldEnvironmentsRefuseHomeAcceptanceAndWrites() async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, built) = try await fixture.prepare()
            let domain = fixture.environmentFile.deletingLastPathComponent()
            let homeFile = domain.appendingPathComponent("studio-connections.json")
            let damaged = Data("{ damaged environments".utf8)
            try damaged.write(to: fixture.environmentFile)
            let homeBytes = try Data(contentsOf: homeFile)
            let draftBytes = try Data(contentsOf: fixture.file)
            let before = model.environments.environments
            let home = model.studioConnections.connections.home

            await model.environments.reload() // prepare() already loaded; this re-reads the damaged file.
            await model.loadEnvironmentDependents()
            #expect(model.environments.hold?.failure == .malformedLocal)
            #expect(model.environments.environments == before)
            #expect(model.studioConnections.isHeldForEnvironments)
            #expect(await model.acceptPendingAssistantDraftResult() == .notAccepted)
            await #expect(throws: StudioConnectionAssignmentError.environmentsUnavailable) {
                try await model.studioConnections.replaceHome(home, equipment: model.equipment.items)
            }
            model.environments.renameActive(to: "Edited while held")
            await model.environments.reload()
            await model.awaitDomainScheduledSaveSnapshots()

            #expect(model.environments.hold?.failure == .malformedLocal)
            #expect(model.assistant.pendingStudioDraft == built)
            #expect(try Data(contentsOf: fixture.environmentFile) == damaged)
            #expect(try Data(contentsOf: homeFile) == homeBytes)
            #expect(try Data(contentsOf: fixture.file) == draftBytes)
        }
    }
}
