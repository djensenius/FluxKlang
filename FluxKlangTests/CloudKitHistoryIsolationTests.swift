import Foundation
import Testing
@testable import FluxKlang

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
