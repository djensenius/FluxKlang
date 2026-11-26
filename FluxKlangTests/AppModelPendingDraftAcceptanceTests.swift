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

// #943 review regressions, kept here so the Mac isolated observation executes them.
extension AppModelPendingDraftAcceptanceTests {
    @Test(.timeLimit(.minutes(1))) func queuedSaveRechecksReadinessWhenItStarts() async throws {
        let gate = HeldLoadGate()
        let probe = SuspendedRead()
        let writes = TestWriteGate()
        defer { probe.release() }
        defer { Task { await writes.open() } }
        try await probe.complete { await gate.load(probe.read) }
        let saves = OrderedLocalSaves()
        let first = saves.enqueue(admitting: { gate.admitsSaves }, write: {
            await writes.wait()
            return true
        })
        let queued = saves.enqueue(admitting: { gate.admitsSaves }, write: { await writes.record("queued") })
        try await boundedWait { await writes.isWaiting }
        let reload = Task { await gate.reload(probe.read) }
        try await probe.waitUntilReading()
        #expect(gate.hold == nil && gate.phase == .loading)
        await writes.open()
        #expect(await first.value)
        #expect(await queued.value == false, "A save queued before the reload never writes around its read")
        probe.release()
        await reload.value
        #expect(await writes.entries.isEmpty)
        #expect(saves.lastSaveFailed)
    }

    /// Reloads requested during a read coalesce into exactly one follow-up read, which sees newer data.
    @Test(.timeLimit(.minutes(1))) func overlappingReloadsCoalesceIntoOneFollowUpRead() async throws {
        let gate = HeldLoadGate()
        let probe = SuspendedRead()
        defer { probe.release() }
        try await probe.complete { await gate.load(probe.read) }
        let reload = Task { await gate.reload(probe.read) }
        try await probe.waitUntilReading()
        probe.source = 1 // e.g. an iCloud change lands after the in-flight read captured its data.
        let overlapping = Task { await gate.reload(probe.read) }
        let another = Task { await gate.reload(probe.read) }
        let clearing = Task { await gate.reloadClearingHold(probe.read) { probe.beforeStarts += 1 } }
        for _ in 0..<3 { await Task.yield() } // MainActor FIFO: all three reach the gate during the read.
        #expect(probe.reads == 2, "Overlapping callers never start a concurrent read")
        probe.release()
        try await probe.waitUntilReading()
        #expect(probe.reads == 3, "Exactly one follow-up read for every overlapping request")
        #expect(probe.observed == 0)
        probe.release()
        await reload.value
        await overlapping.value
        await another.value
        #expect(await clearing.value)
        #expect(probe.reads == 3)
        #expect(probe.observed == 1, "The follow-up read sees the newer data")
        #expect(probe.beforeStarts == 0, "Joining an in-flight read never invalidates queued saves")
    }

    @Test(.timeLimit(.minutes(1))) func olderWriteFinishingAfterNewerRefusalKeepsWarning() async throws {
        let saves = OrderedLocalSaves()
        let writes = TestWriteGate()
        defer { Task { await writes.open() } }
        let older = saves.enqueue(admitting: { true }, write: {
            await writes.wait()
            return true
        })
        try await boundedWait { await writes.isWaiting }
        _ = await saves.refuse().value
        await writes.open()
        #expect(await older.value)
        #expect(saves.lastSaveFailed, "The older snapshot lacks the refused edit")
        saves.settleAfterLoad()
        #expect(saves.lastSaveFailed)
        #expect(await saves.enqueue(admitting: { true }, write: { true }).value)
        #expect(!saves.lastSaveFailed, "A write requested after the refusal includes the edit")
    }

    @Test(.timeLimit(.minutes(1))) func reloadHoldAfterStartupBlocksLoadedHomeUntilRecovery() async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, _) = try await fixture.prepare()
            await model.studioConnections.load(equipment: model.equipment.items,
                environments: model.environments.environments, activeID: model.environments.activeID)
            await model.awaitDomainScheduledSaveSnapshots()
            let homeFile = fixture.environmentFile.deletingLastPathComponent()
                .appendingPathComponent("studio-connections.json")
            let saved = try Data(contentsOf: fixture.environmentFile)
            let homeBytes = try Data(contentsOf: homeFile)
            let connections = model.studioConnections.connections
            try Data("{ damaged environments".utf8).write(to: fixture.environmentFile)

            await model.reloadStores()
            #expect(model.environments.hold?.failure == .malformedLocal)
            #expect(model.studioConnections.isHeldForEnvironments)
            await #expect(throws: StudioConnectionAssignmentError.environmentsUnavailable) {
                try await model.studioConnections.replaceHome(connections.home, equipment: model.equipment.items)
            }
            await model.studioConnections.removeTemporaryMove(UUID())
            #expect(model.studioConnections.connections == connections)
            #expect(try Data(contentsOf: homeFile) == homeBytes)

            try saved.write(to: fixture.environmentFile)
            await model.reloadHeldEnvironments()
            #expect(model.environments.hold == nil)
            #expect(!model.studioConnections.isHeldForEnvironments)
            try await model.studioConnections.replaceHome(connections.home, equipment: model.equipment.items)
        }
    }

    @Test(.timeLimit(.minutes(1))) func holdWhileAwaitingAcceptanceReceiptKeepsDraft() async throws {
        try await AppModelPendingDraftAcceptanceFixture.run { fixture in
            let (model, _) = try await fixture.prepare()
            let result = await model.acceptPendingAssistantDraftResult(beforeAwaitingLocalSave: {
                await model.environments.awaitScheduledSavesSnapshot() // The receipt's own write completes.
                try? Data("{ damaged environments".utf8).write(to: fixture.environmentFile)
                await model.environments.reload()
            })
            guard case .acceptedWithoutRetirement = result else {
                Issue.record("Expected acceptance without retirement, got \(result)")
                return
            }
            #expect(model.environments.hold?.failure == .malformedLocal)
            #expect(model.assistant.pendingStudioDraft != nil)
            #expect(FileManager.default.fileExists(atPath: fixture.file.path))
        }
    }
}

/// Bounded spin (#943 tests): fails the test instead of hanging when suspended work never arrives.
@MainActor
func boundedWait(upTo timeout: Duration = .seconds(10), _ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
    try #require(await condition(), "Timed out waiting for suspended work")
}

@MainActor
private final class SuspendedRead {
    private(set) var reads = 0
    private(set) var observed: Int?
    var beforeStarts = 0
    var source = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    /// Captures `source` when the read starts, publishes it once released.
    func read() async throws(EnvironmentLoadHold) {
        reads += 1
        let snapshot = source
        await withCheckedContinuation { continuations.append($0) }
        observed = snapshot
    }

    func waitUntilReading() async throws {
        try await boundedWait { !self.continuations.isEmpty }
    }

    /// Resumes every suspended read; also used as teardown so nothing stays suspended.
    func release() {
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }

    /// Runs `operation`, releasing its read so the gate reaches `.ready`.
    func complete(_ operation: @escaping @MainActor () async -> Void) async throws {
        let task = Task { await operation() }
        defer { release() }
        try await waitUntilReading()
        release()
        await task.value
    }
}

private actor TestWriteGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var entries: [String] = []
    var isWaiting: Bool { !continuations.isEmpty }

    func wait() async { await withCheckedContinuation { continuations.append($0) } }

    func open() {
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }

    func record(_ entry: String) -> Bool {
        entries.append(entry)
        return true
    }
}
