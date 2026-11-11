import Foundation
import Testing
@testable import FluxKlang

@Suite(.productionAccessAudit)
@MainActor
struct CloudKitHistoryIsolationTests {
    @Test func deniedConstructionAcquiresNoCapabilities() throws {
        try requireIsolation()
        let audit = ProductionAccessAudit()

        _ = CloudKitAssistantHistoryBackend(mirroring: audit)

        expectDeniedAudit(audit, attempts: 1)
    }

    @Test func repeatedDirectLoadsThrowInsteadOfReturningEmptyHistory() async throws {
        try requireIsolation()
        let audit = ProductionAccessAudit()
        let backend = CloudKitAssistantHistoryBackend(mirroring: audit)
        expectDeniedAudit(audit, attempts: 1)

        for attempt in 1...2 {
            do {
                _ = try await backend.loadRecords()
                Issue.record("Expected history load isolation denial, not successful history")
            } catch CloudKitAssistantHistoryError.isolatedAccessDenied {
                // Refusal must retain this exact error, not an empty successful load.
            } catch {
                Issue.record("Expected CloudKitAssistantHistoryError.isolatedAccessDenied")
            }
            expectDeniedAudit(audit, attempts: UInt64(attempt + 1))
        }
    }

    @Test func repeatedDirectSavesThrowInsteadOfAcceptingRecords() async throws {
        try requireIsolation()
        let audit = ProductionAccessAudit()
        let backend = CloudKitAssistantHistoryBackend(mirroring: audit)
        let record = AssistantConversationRecord(conversation: AssistantConversation(title: "Synthetic history"))
        expectDeniedAudit(audit, attempts: 1)

        for attempt in 1...2 {
            do {
                try await backend.save(record)
                Issue.record("Expected history save isolation denial, not an accepted save")
            } catch CloudKitAssistantHistoryError.isolatedAccessDenied {
                // Only an application record is supplied; no CloudKit fixtures are constructed.
            } catch {
                Issue.record("Expected CloudKitAssistantHistoryError.isolatedAccessDenied")
            }
            expectDeniedAudit(audit, attempts: UInt64(attempt + 1))
        }
    }

    @Test func diagnosticsRetainNewestInitialEntriesAtCountBoundary() async throws {
        for count in [0, 1, 127, 128, 129, 300] {
            // Repeated entries must remain repeated, and long text must remain intact.
            let initial = (0..<count).map { "initial \($0 / 2)\n\(historyDiagnosticDetail)" }
            let store = AssistantConversationStore(
                local: DiagnosticsHistoryBackend(label: "local"), initialDiagnostics: initial)

            let diagnostics = await store.diagnostics
            try #require(diagnostics.count == min(count, 128))
            #expect(diagnostics == Array(initial.suffix(128)))
        }
    }

    @Test func diagnosticsBoundRepeatedLocalAndCloudLoadFailures() async throws {
        let conversation = AssistantConversation(title: "Recovered load")
        let record = AssistantConversationRecord(conversation: conversation)
        let local = DiagnosticsHistoryBackend(label: "local", records: [record], loadFailures: 70)
        let cloud = DiagnosticsHistoryBackend(label: "cloud", records: [record], loadFailures: 70)
        let store = AssistantConversationStore(local: local, cloud: cloud, initialDiagnostics: ["initial"])
        var expected = ["initial"]

        for attempt in 1...70 {
            #expect(await store.load().isEmpty)
            expected += failureDiagnostics(operation: "load", attempt: attempt)
        }

        let diagnostics = await store.diagnostics
        try #require(diagnostics.count == 128)
        #expect(diagnostics == Array(expected.suffix(128)))
        #expect(await local.loadAttempts == 70)
        #expect(await cloud.loadAttempts == 70)
        #expect(await store.load() == [conversation])
        #expect(await local.loadAttempts == 71)
        #expect(await cloud.loadAttempts == 71)
        #expect(await local.saveAttempts.isEmpty)
        #expect(await cloud.saveAttempts.isEmpty)
        #expect(await store.diagnostics == diagnostics)
    }

    @Test func diagnosticsBoundDirectSaveAndDeleteFailuresWithoutStoppingPersistence() async throws {
        let local = DiagnosticsHistoryBackend(label: "local", saveFailures: 131)
        let cloud = DiagnosticsHistoryBackend(label: "cloud", saveFailures: 130)
        let store = AssistantConversationStore(local: local, cloud: cloud)
        let conversation = AssistantConversation(title: "Direct writes")
        let record = AssistantConversationRecord(conversation: conversation)
        let deletedAt = conversation.modifiedAt.addingTimeInterval(1)
        let tombstone = AssistantConversationRecord(tombstone: conversation.id, deletedAt: deletedAt)
        var expected: [String] = []
        var attempted: [AssistantConversationRecord] = []

        for attempt in 1...130 {
            if attempt.isMultiple(of: 2) {
                await store.delete(id: conversation.id, at: deletedAt)
                attempted.append(tombstone)
            } else {
                await store.save(conversation)
                attempted.append(record)
            }
            expected += failureDiagnostics(operation: "save", attempt: attempt)
        }

        let diagnostics = await store.diagnostics
        try #require(diagnostics.count == 128)
        #expect(diagnostics == Array(expected.suffix(128)))
        #expect(await local.saveAttempts == attempted)
        #expect(await cloud.saveAttempts == attempted)
        #expect(await local.records.isEmpty)
        #expect(await cloud.records.isEmpty)

        // Even after overflow, a failed local write must not prevent a successful cloud write.
        await store.save(conversation)
        attempted.append(record)
        expected.append("Local assistant history: local save 131\n\(historyDiagnosticDetail)")
        #expect(await local.records.isEmpty)
        #expect(await cloud.records == [record])
        await store.save(conversation)
        attempted.append(record)
        #expect(await local.records == [record])
        #expect(await cloud.records == [record])
        await store.delete(id: conversation.id, at: deletedAt)
        attempted.append(tombstone)
        #expect(await local.records == [tombstone])
        #expect(await cloud.records == [tombstone])
        #expect(await local.saveAttempts == attempted)
        #expect(await cloud.saveAttempts == attempted)
        #expect(await store.load().isEmpty)
        #expect(await store.diagnostics == Array(expected.suffix(128)))
    }

    @Test func diagnosticsBoundLocalMergeBackfillFailuresAndPreserveNewestRecords() async throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let older = AssistantConversation(title: "Older", modifiedAt: date)
        var newer = older
        newer.title = "Newer"
        newer.modifiedAt = date.addingTimeInterval(1)
        let localOnly = AssistantConversation(title: "Local only", modifiedAt: date.addingTimeInterval(2))
        let winningRecord = AssistantConversationRecord(conversation: newer)
        let localOnlyRecord = AssistantConversationRecord(conversation: localOnly)
        let local = DiagnosticsHistoryBackend(
            label: "local", records: [AssistantConversationRecord(conversation: older), localOnlyRecord],
            saveFailures: 130)
        let cloud = DiagnosticsHistoryBackend(label: "cloud", records: [winningRecord])
        let initial = (0..<128).map { "initial \($0)" }
        let store = AssistantConversationStore(local: local, cloud: cloud, initialDiagnostics: initial)
        var expected = initial

        for attempt in 1...130 {
            #expect(await store.load() == [localOnly, newer])
            expected.append("Local assistant history: local save \(attempt)\n\(historyDiagnosticDetail)")
        }

        let diagnostics = await store.diagnostics
        try #require(diagnostics.count == 128)
        #expect(diagnostics == Array(expected.suffix(128)))
        #expect(await local.saveAttempts == Array(repeating: winningRecord, count: 130))
        // This backfill succeeds after the very first local failure overflows the diagnostics.
        #expect(await cloud.saveAttempts == [localOnlyRecord])
        #expect(await cloud.records == [winningRecord, localOnlyRecord])
        #expect(await store.load() == [localOnly, newer])
        #expect(await local.records.contains(winningRecord) == true)
        #expect(await local.saveAttempts == Array(repeating: winningRecord, count: 131))
        #expect(await local.loadAttempts == 131)
        #expect(await cloud.loadAttempts == 131)
        #expect(await store.load() == [localOnly, newer])
        #expect(await local.saveAttempts.count == 131)
        #expect(await cloud.saveAttempts == [localOnlyRecord])
        #expect(await store.diagnostics == diagnostics)
    }

    @Test func diagnosticsBoundCloudMergeBackfillFailuresAndPreserveTombstones() async throws {
        let date = Date(timeIntervalSince1970: 2_000)
        let conversation = AssistantConversation(title: "Deleted at same timestamp", modifiedAt: date)
        let tombstone = AssistantConversationRecord(tombstone: conversation.id, deletedAt: date)
        let local = DiagnosticsHistoryBackend(label: "local", records: [tombstone])
        let cloud = DiagnosticsHistoryBackend(
            label: "cloud", records: [AssistantConversationRecord(conversation: conversation)], saveFailures: 130)
        let store = AssistantConversationStore(local: local, cloud: cloud)
        var expected: [String] = []

        for attempt in 1...130 {
            #expect(await store.load().isEmpty)
            expected.append("Private iCloud assistant history: cloud save \(attempt)\n\(historyDiagnosticDetail)")
        }

        let diagnostics = await store.diagnostics
        try #require(diagnostics.count == 128)
        #expect(diagnostics == Array(expected.suffix(128)))
        #expect(await cloud.saveAttempts == Array(repeating: tombstone, count: 130))
        #expect(await local.saveAttempts.isEmpty)
        #expect(await store.load().isEmpty)
        #expect(await local.records == [tombstone])
        #expect(await cloud.records == [tombstone])
        #expect(await cloud.saveAttempts == Array(repeating: tombstone, count: 131))
        #expect(await local.loadAttempts == 131)
        #expect(await cloud.loadAttempts == 131)
        #expect(await store.load().isEmpty)
        #expect(await cloud.saveAttempts.count == 131)
        #expect(await store.diagnostics == diagnostics)
    }

    private func failureDiagnostics(operation: String, attempt: Int) -> [String] {
        [
            "Local assistant history: local \(operation) \(attempt)\n\(historyDiagnosticDetail)",
            "Private iCloud assistant history: cloud \(operation) \(attempt)\n\(historyDiagnosticDetail)"
        ]
    }

    private func requireIsolation() throws {
        let isTesting = AppPersistence.isTesting
        let modelFlagDisabled = ProcessInfo.processInfo.environment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] != "1"
        let routingFlagDisabled = ProcessInfo.processInfo.environment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] != "1"
        try #require(isTesting, "Cloud boundary tests require process-selected isolation")
        try #require(modelFlagDisabled, "Model qualification must be disabled")
        try #require(routingFlagDisabled, "Routing qualification must be disabled")
    }

    // Fresh mirrors cover only these denied paths, not allowed private work or global activity.
    private func expectDeniedAudit(_ audit: ProductionAccessAudit, attempts: UInt64) {
        let snapshot = audit.snapshot()
        let attempted = snapshot.count(.attempted, for: .cloudKitHistory)
        let denied = snapshot.count(.denied, for: .cloudKitHistory)
        let apiEntries = snapshot.count(.apiEntered, for: .cloudKitHistory)
        let passive = snapshot.count(.passiveConstruction, for: .cloudKitHistory)
        let factories = snapshot.count(.factoryEvaluated, for: .cloudKitHistory)
        #expect(attempted == attempts)
        #expect(denied == attempts)
        #expect(apiEntries == 0)
        #expect(passive == 0)
        #expect(factories == 0)
    }
}

private let historyDiagnosticDetail = "Full detail: café 🧪 " + String(repeating: "unabridged ", count: 100)

private struct HistoryDiagnosticsFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private actor DiagnosticsHistoryBackend: AssistantHistoryBackend {
    private let label: String
    private let loadFailures: Int
    private let saveFailures: Int
    private(set) var records: [AssistantConversationRecord]
    private(set) var loadAttempts = 0
    private(set) var saveAttempts: [AssistantConversationRecord] = []

    init(
        label: String, records: [AssistantConversationRecord] = [], loadFailures: Int = 0, saveFailures: Int = 0
    ) {
        self.label = label
        self.records = records
        self.loadFailures = loadFailures
        self.saveFailures = saveFailures
    }

    func loadRecords() async throws -> [AssistantConversationRecord] {
        loadAttempts += 1
        if loadAttempts <= loadFailures {
            throw HistoryDiagnosticsFailure(message: "\(label) load \(loadAttempts)\n\(historyDiagnosticDetail)")
        }
        return records
    }

    func save(_ record: AssistantConversationRecord) async throws {
        saveAttempts.append(record)
        if saveAttempts.count <= saveFailures {
            throw HistoryDiagnosticsFailure(message: "\(label) save \(saveAttempts.count)\n\(historyDiagnosticDetail)")
        }
        records.removeAll { $0.id == record.id }
        records.append(record)
    }
}
